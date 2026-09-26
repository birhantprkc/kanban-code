import Foundation

/// `kanbancode://pair?url=<base url>&token=<token>&name=<host name>`, the
/// link the pairing QR code holds. Every value is fully percent-encoded, so a
/// base URL with its own path or query survives.
public enum RemotePairLink {
    public static func make(url: String, token: String, name: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        return "kanbancode://pair?url=\(encode(url))&token=\(encode(token))&name=\(encode(name))"
    }
}
