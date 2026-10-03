#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import KanbanCodeRemoteKit

/// What the scrubber knows of one vault value: enough to find it in a file,
/// not enough to read it. `prefix` is a keyed 32-bit fingerprint of its first
/// eight bytes, `mac` a keyed HMAC of all of them.
public struct ScrubFingerprint: Codable, Sendable, Equatable, Hashable {
    /// The vault name a reference to it uses.
    public var name: String
    /// Bytes of the value in the form it was fingerprinted in.
    public var length: Int
    public var prefix: UInt32
    /// Hex of the first 16 bytes of the HMAC.
    public var mac: String
    /// The secret's listing fingerprint (`kv ls`), for the short reference.
    public var tag: String

    public init(name: String, length: Int, prefix: UInt32, mac: String, tag: String) {
        self.name = name
        self.length = length
        self.prefix = prefix
        self.mac = mac
        self.tag = tag
    }
}

/// The keys the fingerprints are made with, derived from the vault key. A
/// machine without the vault key cannot build or use the index.
public struct ScrubKey: Sendable {
    let mac: SymmetricKey
    /// Keys the listing fingerprint, the same one `kv ls` shows.
    let tag: SymmetricKey
    let k0: UInt64
    let k1: UInt64

    public init(identity: Age.Identity) {
        self.init(
            mac: Age.hkdf(ikm: identity.rawKey, salt: Data("kanban-code-vault".utf8), info: "scrub-index"),
            tag: VaultSeal.authKey(identity))
    }

    init(mac: SymmetricKey, tag: SymmetricKey) {
        self.mac = mac
        self.tag = tag
        let seed = Data(HMAC<SHA256>.authenticationCode(for: Data("prefix".utf8), using: mac))
        k0 = seed.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        k1 = seed.dropFirst(8).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// The fingerprint of an eight byte window, big-endian in `window`.
    @inline(__always)
    func prefix(_ window: UInt64) -> UInt32 {
        var x = window ^ k0
        x = x &* 0xff51_afd7_ed55_8ccd
        x ^= x >> 33
        x ^= k1
        x = x &* 0xc4ce_b9fe_1a85_ec53
        x ^= x >> 33
        return UInt32(truncatingIfNeeded: x >> 32)
    }

    func macHex(_ bytes: UnsafeRawBufferPointer) -> String {
        var h = HMAC<SHA256>(key: mac)
        h.update(data: bytes)
        return Data(h.finalize()).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func macHex(_ bytes: [UInt8]) -> String {
        bytes.withUnsafeBytes { macHex($0) }
    }

    /// The listing fingerprint of a whole value.
    func tagHex(_ value: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(("fingerprint:" + value).utf8), using: tag)
        return Data(code).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func fingerprint(name: String, tag: String, bytes: [UInt8]) -> ScrubFingerprint? {
        guard bytes.count >= ScrubIndex.minimumLength else { return nil }
        let window = bytes.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return ScrubFingerprint(name: name, length: bytes.count, prefix: prefix(window), mac: macHex(bytes), tag: tag)
    }
}

public enum ScrubIndex {
    /// Shorter values are never fingerprinted: too likely to be a word.
    public static let minimumLength = 16
    static let maximumLength = 16_384

    /// The fingerprints of one secret: the value as stored and as it reads
    /// inside JSON (escaped once, twice, and with `\/`), plus the long
    /// members of a JSON value and the credential parts of a URL.
    public static func fingerprints(name: String, value: String, key: ScrubKey) -> [ScrubFingerprint] {
        let tag = key.tagHex(value)
        var seen = Set<String>()
        var out: [ScrubFingerprint] = []
        for part in parts(of: value) {
            for form in forms(of: part) where form.count <= maximumLength {
                guard let f = key.fingerprint(name: name, tag: tag, bytes: form), seen.insert(f.mac).inserted else { continue }
                out.append(f)
            }
        }
        return out
    }

    /// The strings of a value worth finding on their own.
    static func parts(of value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [String] = []
        if let leaves = jsonLeaves(trimmed) {
            out = leaves.filter { looksSecret($0) || $0.contains("PRIVATE KEY") }
            if trimmed.utf8.count <= 4096 { out.append(trimmed) }
        } else if let decoded = Data(base64Encoded: trimmed), decoded.count >= 32,
                  let leaves = jsonLeaves(String(decoding: decoded, as: UTF8.self)) {
            out = leaves.filter { looksSecret($0) || $0.contains("PRIVATE KEY") } + [trimmed]
        } else if trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil {
            let pieces = trimmed.split(whereSeparator: { "/:@?&=#".contains($0) }).map(String.init)
            out = pieces.filter(looksSecret)
            // A URL that carries a credential is found whole as well.
            if !out.isEmpty { out.append(trimmed) }
        } else if looksSecret(trimmed) || trimmed.contains("PRIVATE KEY") {
            out = [trimmed]
        }
        return out
    }

    private static func jsonLeaves(_ text: String) -> [String]? {
        guard text.hasPrefix("{") || text.hasPrefix("["),
              let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        var out: [String] = []
        func walk(_ node: Any) {
            if let s = node as? String { out.append(s) }
            if let d = node as? [String: Any] { d.values.forEach(walk) }
            if let a = node as? [Any] { a.forEach(walk) }
        }
        walk(root)
        return out
    }

    /// A string that reads like minted key material: long enough, mixed
    /// letters and digits, and random enough. Words, paths, hosts and
    /// addresses fail it, so a vault entry that holds one is never replaced
    /// across the transcripts.
    static func looksSecret(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= minimumLength else { return false }
        if value.hasPrefix("/") || value.hasPrefix("~/") || value.hasPrefix("./") || value.contains("{{vault:") { return false }
        var digits = 0, letters = 0
        for b in bytes {
            if b >= 48 && b <= 57 { digits += 1 } else if (b >= 65 && b <= 90) || (b >= 97 && b <= 122) { letters += 1 }
        }
        guard digits >= 2, letters >= 2 else { return false }
        return entropyBits(bytes) >= 3.0
    }

    static func entropyBits(_ bytes: [UInt8]) -> Double {
        guard !bytes.isEmpty else { return 0 }
        var counts = [Int](repeating: 0, count: 256)
        let sample = bytes.prefix(256)
        for b in sample { counts[Int(b)] += 1 }
        var entropy = 0.0
        for c in counts where c > 0 {
            let p = Double(c) / Double(sample.count)
            entropy -= p * log2(p)
        }
        return entropy
    }

    /// The bytes a string has in a plain file and inside JSON text.
    static func forms(of value: String) -> [[UInt8]] {
        let raw = Array(value.utf8)
        let once = jsonEscaped(raw, slashes: false)
        var out = [raw]
        if once != raw {
            out.append(once)
            out.append(jsonEscaped(once, slashes: false))
        }
        let slashed = jsonEscaped(raw, slashes: true)
        if slashed != once { out.append(slashed) }
        return out
    }

    /// The body of the JSON string for `bytes` (no quotes), as
    /// `JSON.stringify` writes it; `slashes` also escapes `/`, as Foundation does.
    static func jsonEscaped(_ bytes: [UInt8], slashes: Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 8)
        let hex = Array("0123456789abcdef".utf8)
        for b in bytes {
            switch b {
            case 0x22: out += [0x5C, 0x22]
            case 0x5C: out += [0x5C, 0x5C]
            case 0x0A: out += [0x5C, 0x6E]
            case 0x0D: out += [0x5C, 0x72]
            case 0x09: out += [0x5C, 0x74]
            case 0x08: out += [0x5C, 0x62]
            case 0x0C: out += [0x5C, 0x66]
            case 0x2F where slashes: out += [0x5C, 0x2F]
            case 0..<0x20: out += [0x5C, 0x75, 0x30, 0x30, hex[Int(b >> 4)], hex[Int(b & 15)]]
            default: out.append(b)
            }
        }
        return out
    }

    /// The text that takes the place of a value `length` bytes long, never
    /// longer than it: the reference by name, or by the start of the
    /// secret's listing fingerprint when the name does not fit.
    public static func reference(name: String, tag: String, length: Int) -> [UInt8]? {
        let full = Array("{{vault:\(name)}}".utf8)
        if full.count <= length { return full }
        let room = min(length - 11, tag.utf8.count)
        guard room >= 5 else { return nil }
        return Array("{{vault:#\(tag.prefix(room))}}".utf8)
    }
}

extension VaultStore {
    /// Fingerprints of every live secret. The one place the scrubber's
    /// index is built from values; a scan reads the index only.
    func scrubFingerprints() throws -> [ScrubFingerprint]? {
        guard let identity = currentIdentity() else { return nil }
        let key = ScrubKey(identity: identity)
        return try load().live.flatMap { ScrubIndex.fingerprints(name: $0.name, value: $0.value, key: key) }
    }

    /// The size and time of `vault.age`, to tell when the index is behind.
    func vaultStamp() -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: vaultPath) else { return "none" }
        let time = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(attrs[.size] as? Int ?? 0):\(time)"
    }

    func scrubKey() -> ScrubKey? {
        currentIdentity().map(ScrubKey.init(identity:))
    }
}

/// `vault/scrub-index.json`: the fingerprints of the vault's values, built
/// whenever `vault.age` changes. It holds no value and no key.
public actor ScrubIndexStore {
    private struct File: Codable {
        var version = 1
        var vaultStamp: String
        var entries: [ScrubFingerprint]
    }

    public let store: VaultStore
    let path: String
    private var cached: File?

    public init(store: VaultStore) {
        self.store = store
        path = store.directory + "/scrub-index.json"
    }

    /// The index, rebuilt first when the vault changed since it was written.
    /// Nil on a machine without the vault key.
    public func current() async -> (entries: [ScrubFingerprint], key: ScrubKey)? {
        guard let key = await store.scrubKey() else { return nil }
        let stamp = await store.vaultStamp()
        if cached == nil {
            cached = FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder().decode(File.self, from: $0) }
        }
        if let cached, cached.vaultStamp == stamp { return (cached.entries, key) }
        guard let entries = try? await store.scrubFingerprints() else { return nil }
        let file = File(vaultStamp: stamp, entries: entries)
        cached = file
        if let data = try? JSONEncoder().encode(file) {
            try? VaultFiles.writeAtomically(data, to: path, mode: 0o600)
        }
        return (entries, key)
    }

    /// Adds the fingerprints of a value saved during a run.
    public func record(name: String, value: String) async {
        guard let key = await store.scrubKey(), var file = cached else { return }
        file.entries += ScrubIndex.fingerprints(name: name, value: value, key: key)
        file.vaultStamp = await store.vaultStamp()
        cached = file
        if let data = try? JSONEncoder().encode(file) {
            try? VaultFiles.writeAtomically(data, to: path, mode: 0o600)
        }
    }
}
