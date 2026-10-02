import Foundation
import KanbanCodeRemoteKit

/// How attention requests reach Rogerio, from Settings > Notifications.
public struct AttentionPolicySettings: Sendable, Equatable {
    /// Post a notification on the Mac.
    public var macNotifications: Bool
    /// Send to the phone at all.
    public var phoneEnabled: Bool
    /// An open request alerts the phone after this long.
    public var phoneAlertDelay: TimeInterval
    /// The Mac counts as away after this long without input.
    public var idleThreshold: TimeInterval
    /// A presence report older than this is not trusted: the Mac counts as away.
    public var presenceMaxAge: TimeInterval

    public init(
        macNotifications: Bool = true, phoneEnabled: Bool = true,
        phoneAlertDelay: TimeInterval = 180, idleThreshold: TimeInterval = 120,
        presenceMaxAge: TimeInterval = 90
    ) {
        self.macNotifications = macNotifications
        self.phoneEnabled = phoneEnabled
        self.phoneAlertDelay = phoneAlertDelay
        self.idleThreshold = idleThreshold
        self.presenceMaxAge = presenceMaxAge
    }
}

/// What was already done for one request.
public struct AttentionDeliveryState: Sendable, Equatable {
    public var macPosted = false
    public var phoneSilentSent = false
    public var phoneAlertSent = false

    public init(macPosted: Bool = false, phoneSilentSent: Bool = false, phoneAlertSent: Bool = false) {
        self.macPosted = macPosted
        self.phoneSilentSent = phoneSilentSent
        self.phoneAlertSent = phoneAlertSent
    }
}

public enum AttentionDeliveryStep: Sendable, Equatable {
    case postMac
    case removeMac
    /// A copy on the phone that makes no sound (passive).
    case phoneSilent
    /// A time-sensitive push with sound.
    case phoneAlert
}

/// Who gets told about an open request, and when. Pure.
public enum AttentionPolicy {
    /// The Mac is away: locked, screensaver, lid closed, display asleep, idle
    /// past the threshold, or no fresh presence report at all.
    public static func macIsAway(_ presence: MacPresence?, now: Date, settings: AttentionPolicySettings) -> Bool {
        guard let presence, now.timeIntervalSince(presence.reportedAt) <= settings.presenceMaxAge else { return true }
        return presence.screenLocked || presence.screensaverActive || presence.lidClosed || presence.displayAsleep
            || presence.idleSeconds >= settings.idleThreshold
    }

    /// Rogerio is looking at the request's card right now: Kanban in front
    /// with that card's terminal or chat open, and the Mac in use.
    public static func isLookingAt(_ request: AttentionRequest, _ presence: MacPresence?, now: Date, settings: AttentionPolicySettings) -> Bool {
        guard let presence, let cardId = request.cardId, !macIsAway(presence, now: now, settings: settings) else { return false }
        guard presence.isKanbanFrontmost, presence.visibleCardId == cardId else { return false }
        return presence.visibleTab == nil || presence.visibleTab == "terminal" || presence.visibleTab == "chat"
    }

    /// What to do now for an open request, given what was already done.
    public static func steps(
        for request: AttentionRequest, delivered: AttentionDeliveryState, presence: MacPresence?,
        now: Date, settings: AttentionPolicySettings, macAvailable: Bool = true
    ) -> [AttentionDeliveryStep] {
        guard request.isOpen else {
            return delivered.macPosted ? [.removeMac] : []
        }
        if isLookingAt(request, presence, now: now, settings: settings) {
            return delivered.macPosted ? [.removeMac] : []
        }
        var steps: [AttentionDeliveryStep] = []
        if macAvailable, settings.macNotifications, !delivered.macPosted {
            steps.append(.postMac)
        }
        guard settings.phoneEnabled else { return steps }
        let waited = now.timeIntervalSince(request.createdAt) >= settings.phoneAlertDelay
        let away = macIsAway(presence, now: now, settings: settings)
        if !delivered.phoneAlertSent, waited || away {
            steps.append(.phoneAlert)
        } else if !delivered.phoneSilentSent, !delivered.phoneAlertSent {
            steps.append(.phoneSilent)
        }
        return steps
    }

    /// When the request next needs a look, for a timer: the phone alert
    /// deadline, or nil when nothing is left to escalate.
    public static func nextCheck(for request: AttentionRequest, delivered: AttentionDeliveryState, settings: AttentionPolicySettings) -> Date? {
        guard request.isOpen, settings.phoneEnabled, !delivered.phoneAlertSent else { return nil }
        return request.createdAt.addingTimeInterval(settings.phoneAlertDelay)
    }
}
