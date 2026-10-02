import Foundation
import KanbanCodeRemoteKit

/// Delivers attention requests: a notification on the Mac, a silent copy on
/// the phone, and a phone alert when the request waits too long or the Mac
/// is away. Applies `AttentionPolicy` on every change and on a timer.
public actor AttentionCenter: AttentionDelivering {
    private var open: [String: AttentionRequest] = [:]
    private var delivered: [String: AttentionDeliveryState] = [:]
    private var reportedPresence: MacPresence?
    private var settings: AttentionPolicySettings
    private let mac: (any MacAttentionNotifier)?
    private var phone: (any PhonePushSender)?
    private let localPresence: (@Sendable () async -> MacPresence?)?
    private let cardName: @Sendable (String?) async -> String?
    private let localMachineId: @Sendable () async -> String?
    private let now: @Sendable () -> Date
    private var loop: Task<Void, Never>?

    /// Steps taken, newest last, for the log and for tests.
    public private(set) var history: [(id: String, step: AttentionDeliveryStep)] = []

    public init(
        settings: AttentionPolicySettings = .init(),
        mac: (any MacAttentionNotifier)? = nil,
        phone: (any PhonePushSender)? = nil,
        localPresence: (@Sendable () async -> MacPresence?)? = nil,
        cardName: @escaping @Sendable (String?) async -> String? = { _ in nil },
        localMachineId: @escaping @Sendable () async -> String? = { nil },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = settings
        self.mac = mac
        self.phone = phone
        self.localPresence = localPresence
        self.cardName = cardName
        self.localMachineId = localMachineId
        self.now = now
    }

    public func configure(settings: AttentionPolicySettings, phone: (any PhonePushSender)?) {
        self.settings = settings
        self.phone = phone
    }

    /// Presence a peer Mac reported, used when this master has no screen.
    public func reportPresence(_ presence: MacPresence) async {
        reportedPresence = presence
        await evaluateAll()
    }

    public func currentPresence() async -> MacPresence? {
        if let localPresence { return await localPresence() }
        return reportedPresence
    }

    /// Re-checks every open request every `interval` until cancelled.
    public func start(interval: Duration = .seconds(5)) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.evaluateAll()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: AttentionDelivering

    public func deliver(_ request: AttentionRequest) async {
        open[request.id] = request
        if delivered[request.id] == nil { delivered[request.id] = AttentionDeliveryState() }
        await evaluate(request.id)
    }

    public func update(_ request: AttentionRequest) async {
        open[request.id] = request
        await evaluate(request.id)
    }

    public func withdraw(_ request: AttentionRequest) async {
        open.removeValue(forKey: request.id)
        let state = delivered.removeValue(forKey: request.id) ?? AttentionDeliveryState()
        if state.macPosted {
            await mac?.remove(id: request.id)
            history.append((request.id, .removeMac))
        }
        if state.phoneSilentSent || state.phoneAlertSent {
            await phone?.withdraw(request)
        }
        KanbanCodeLog.info("attention", "Withdrew \(request.id) (\(request.resolution ?? "no answer") by \(request.resolvedBy ?? "?"))")
    }

    // MARK: Policy

    public func evaluateAll() async {
        for id in open.keys.sorted() {
            await evaluate(id)
        }
    }

    private func evaluate(_ id: String) async {
        guard let request = open[id] else { return }
        let presence = await currentPresence()
        let ownsPhone: Bool
        if let owner = request.machineId, let local = await localMachineId() {
            ownsPhone = owner == local
        } else {
            ownsPhone = true
        }
        var policy = settings
        if !ownsPhone || phone == nil { policy.phoneEnabled = false }
        let at = now()
        let steps = AttentionPolicy.steps(
            for: request, delivered: delivered[id] ?? .init(), presence: presence,
            now: at, settings: policy, macAvailable: mac != nil)
        guard !steps.isEmpty else { return }
        let name = await cardName(request.cardId)
        for step in steps {
            // A request resolved while an earlier step awaited is left alone.
            guard open[id] != nil else { return }
            var state = delivered[id] ?? .init()
            switch step {
            case .postMac:
                await mac?.post(request, cardName: name)
                state.macPosted = true
            case .removeMac:
                await mac?.remove(id: id)
                state.macPosted = false
            case .phoneSilent:
                state.phoneSilentSent = true
                delivered[id] = state
                await sendPhone(request, name: name, level: .passive)
            case .phoneAlert:
                state.phoneAlertSent = true
                delivered[id] = state
                await sendPhone(request, name: name, level: .timeSensitive)
            }
            if open[id] != nil { delivered[id] = state }
            history.append((id, step))
            KanbanCodeLog.info("attention", "\(id): \(step)")
        }
    }

    private func sendPhone(_ request: AttentionRequest, name: String?, level: PhonePushLevel) async {
        do {
            try await phone?.send(request, cardName: name, level: level)
        } catch {
            KanbanCodeLog.warn("attention", "Phone push of \(request.id) failed: \(error)")
        }
    }

    public func deliveryState(_ id: String) -> AttentionDeliveryState? { delivered[id] }
}
