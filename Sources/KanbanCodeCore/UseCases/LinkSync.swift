import Foundation

/// Card sync between masters: which fields each master may write, how two
/// versions of a card merge, and how local edits get stamped.
///
/// A card has one owner, the master that runs its heavy state. Its fields
/// fall in two groups:
/// - owner fields (session, terminals, worktree, launch state, queued
///   prompts, machine): only the owner writes them, versioned by `ownerRev`,
///   and a merge takes them only from a version the owner stamped;
/// - shared fields (name, column, order, pin, archive, prompt, parent...):
///   any master edits them, versioned by `rev`, last writer wins.
/// A deletion is a shared edit: the tombstone carries a `rev` and wins over
/// older edits, loses to newer ones.
///
/// The merge picks each group from the version with the higher stamp, so
/// applying the same versions in any order, any number of times, lands on
/// the same card.
public enum LinkSync {
    /// Tombstones older than this are dropped, and ignored when a peer sends one.
    public static let tombstoneLifetime: TimeInterval = 30 * 24 * 3600

    // MARK: - Field groups

    /// Copies the shared fields (and the deletion mark) of `src` into `dst`.
    public static func copyShared(from src: Link, to dst: inout Link) {
        dst.name = src.name
        dst.column = src.column
        dst.manualOverrides = src.manualOverrides
        dst.manuallyArchived = src.manuallyArchived
        dst.promptBody = src.promptBody
        dst.promptImagePaths = src.promptImagePaths
        dst.parentCardId = src.parentCardId
        dst.modelOverride = src.modelOverride
        dst.selfCompactContextThresholdTokens = src.selfCompactContextThresholdTokens
        dst.prLinks = src.prLinks
        dst.issueLink = src.issueLink
        dst.sortOrder = src.sortOrder
        dst.pinnedAt = src.pinnedAt
        dst.pinnedSortOrder = src.pinnedSortOrder
        dst.assistant = src.assistant
        dst.deletedAt = src.deletedAt
    }

    /// Copies the owner fields of `src` into `dst`.
    public static func copyOwned(from src: Link, to dst: inout Link) {
        dst.projectPath = src.projectPath
        dst.source = src.source
        dst.createdAt = src.createdAt
        dst.lastActivity = src.lastActivity
        dst.sessionLink = src.sessionLink
        dst.tmuxLink = src.tmuxLink
        dst.worktreeLink = src.worktreeLink
        dst.queuedPrompts = src.queuedPrompts
        dst.discoveredBranches = src.discoveredBranches
        dst.discoveredRepos = src.discoveredRepos
        dst.isRemote = src.isRemote
        dst.remote = src.remote
        dst.apiServiceId = src.apiServiceId
        dst.isLaunching = src.isLaunching
        dst.launchedAt = src.launchedAt
        dst.headless = src.headless
        dst.ownerMachine = src.ownerMachine
        dst.migrating = src.migrating
    }

    public static func sharedEqual(_ a: Link, _ b: Link) -> Bool {
        a.name == b.name
            && a.column == b.column
            && a.manualOverrides == b.manualOverrides
            && a.manuallyArchived == b.manuallyArchived
            && a.promptBody == b.promptBody
            && a.promptImagePaths == b.promptImagePaths
            && a.parentCardId == b.parentCardId
            && a.modelOverride == b.modelOverride
            && a.selfCompactContextThresholdTokens == b.selfCompactContextThresholdTokens
            && a.prLinks == b.prLinks
            && a.issueLink == b.issueLink
            && a.sortOrder == b.sortOrder
            && a.pinnedAt == b.pinnedAt
            && a.pinnedSortOrder == b.pinnedSortOrder
            && a.assistant == b.assistant
            && a.deletedAt == b.deletedAt
    }

    public static func ownedEqual(_ a: Link, _ b: Link) -> Bool {
        a.projectPath == b.projectPath
            && a.source == b.source
            && a.createdAt == b.createdAt
            && a.lastActivity == b.lastActivity
            && a.sessionLink == b.sessionLink
            && a.tmuxLink == b.tmuxLink
            && a.worktreeLink == b.worktreeLink
            && a.queuedPrompts == b.queuedPrompts
            && a.discoveredBranches == b.discoveredBranches
            && a.discoveredRepos == b.discoveredRepos
            && a.isRemote == b.isRemote
            && a.remote == b.remote
            && a.apiServiceId == b.apiServiceId
            && a.isLaunching == b.isLaunching
            && a.launchedAt == b.launchedAt
            && a.headless == b.headless
            && a.ownerMachine == b.ownerMachine
            && a.migrating == b.migrating
    }

    /// Property names per group; a test checks every `Link` property sits in
    /// exactly one of them, so a new field cannot silently skip sync.
    static let sharedFieldNames: Set<String> = [
        "name", "column", "manualOverrides", "manuallyArchived", "promptBody", "promptImagePaths",
        "parentCardId", "modelOverride", "selfCompactContextThresholdTokens", "prLinks", "issueLink",
        "sortOrder", "pinnedAt", "pinnedSortOrder", "assistant", "deletedAt",
    ]
    static let ownedFieldNames: Set<String> = [
        "projectPath", "source", "createdAt", "lastActivity", "sessionLink", "tmuxLink", "worktreeLink",
        "queuedPrompts", "discoveredBranches", "discoveredRepos", "isRemote", "remote", "apiServiceId",
        "isLaunching", "launchedAt", "headless", "ownerMachine", "migrating",
    ]
    /// Per-machine fields that never travel, plus the sync metadata.
    static let localFieldNames: Set<String> = [
        "id", "updatedAt", "lastOpenedAt", "browserTabs", "rev", "ownerRev",
    ]

    // MARK: - Ownership

    /// The machine that owns `link`; nil `ownerMachine` means this machine.
    public static func owner(of link: Link, localMachine: String) -> String {
        link.ownerMachine ?? localMachine
    }

    public static func isOwnedLocally(_ link: Link, localMachine: String) -> Bool {
        guard let owner = link.ownerMachine else { return true }
        return owner == localMachine
    }

    // MARK: - Tombstones

    /// The tombstone a deletion leaves: the owner fields stay (a resurrecting
    /// edit may be older on that group), the shared fields are dropped (a
    /// resurrecting edit always brings its own).
    public static func tombstone(of link: Link, deletedAt: Date, rev: SyncStamp?) -> Link {
        var t = link
        var blank = Link(id: link.id)
        blank.deletedAt = deletedAt
        copyShared(from: blank, to: &t)
        t.rev = rev
        t.browserTabs = nil
        t.lastOpenedAt = nil
        return t
    }

    public static func isExpired(_ link: Link, now: Date) -> Bool {
        guard let deletedAt = link.deletedAt else { return false }
        return now.timeIntervalSince(deletedAt) > tombstoneLifetime
    }

    // MARK: - Merge

    /// Merges a version of a card sent by `peer` into the local record
    /// (a live card, a tombstone, or nil when this machine never saw it).
    /// Returns the new local record.
    ///
    /// - A card this machine owns and is launching is left alone.
    /// - Shared fields come from the version with the higher `rev`.
    /// - Owner fields come from the incoming version only when its `ownerRev`
    ///   is newer and was stamped by the card's current owner as this
    ///   machine knows it. An ownership release is written by the old owner,
    ///   so it passes; the adopting machine's writes pass once the release
    ///   landed here.
    public static func merge(
        local: Link?,
        incoming raw: Link,
        from peer: String,
        localMachine: String,
        now: Date
    ) -> Link? {
        var incoming = raw
        if incoming.ownerMachine == nil { incoming.ownerMachine = peer }
        incoming.browserTabs = nil
        incoming.lastOpenedAt = nil

        if isExpired(incoming, now: now) { return local }
        guard let local else {
            incoming.updatedAt = now
            return incoming
        }
        if local.isLaunching == true, !local.isTombstone,
           isOwnedLocally(local, localMachine: localMachine) {
            return local
        }

        var result = local
        if Optional.isNewer(incoming.rev, than: local.rev) {
            copyShared(from: incoming, to: &result)
            result.rev = incoming.rev
        }
        let currentOwner = owner(of: local, localMachine: localMachine)
        if Optional.isNewer(incoming.ownerRev, than: local.ownerRev),
           incoming.ownerRev?.machine == currentOwner {
            copyOwned(from: incoming, to: &result)
            result.ownerRev = incoming.ownerRev
        }
        if result.isTombstone, !local.isTombstone || result.rev != local.rev {
            result = tombstone(of: result, deletedAt: result.deletedAt!, rev: result.rev)
        }
        if result != local { result.updatedAt = max(now, local.updatedAt) }
        return result
    }

    public struct MergeOutcome: Sendable {
        public var links: [String: Link]
        public var tombstones: [String: Link]
        /// Ids whose local record changed.
        public var changedIds: Set<String>
        /// Live cards this machine owned that an incoming tombstone deleted.
        public var deletedOwned: [Link]
        /// The Lamport clock after seeing every incoming stamp.
        public var clock: Int
    }

    /// Merges a page of versions from `peer` into the local cards and
    /// tombstones, dropping expired tombstones on the way.
    public static func mergePage(
        _ incoming: [Link],
        from peer: String,
        links: [String: Link],
        tombstones: [String: Link],
        localMachine: String,
        clock: Int,
        now: Date
    ) -> MergeOutcome {
        var out = MergeOutcome(links: links, tombstones: tombstones, changedIds: [], deletedOwned: [], clock: clock)
        for version in incoming {
            out.clock = max(out.clock, version.rev?.counter ?? 0, version.ownerRev?.counter ?? 0)
            let id = version.id
            let local = out.links[id] ?? out.tombstones[id]
            guard let merged = merge(local: local, incoming: version, from: peer, localMachine: localMachine, now: now),
                  merged != local
            else { continue }
            out.changedIds.insert(id)
            if merged.isTombstone {
                if let live = out.links.removeValue(forKey: id),
                   isOwnedLocally(live, localMachine: localMachine) {
                    out.deletedOwned.append(live)
                }
                out.tombstones[id] = merged
            } else {
                out.tombstones.removeValue(forKey: id)
                out.links[id] = merged
            }
        }
        for (id, t) in out.tombstones where isExpired(t, now: now) {
            out.tombstones.removeValue(forKey: id)
        }
        return out
    }

    // MARK: - Local edits

    /// Actions a user takes on a card's shared fields. On a card another
    /// master owns, only these may change it (and never its owner fields);
    /// every other action (reconcile, liveness scans, launches...) leaves
    /// foreign cards exactly as their owner sent them.
    public static func allowsForeignEdits(_ action: Action) -> Bool {
        switch action {
        case .moveCard, .renameCard, .setCardPinned, .setSelfCompactContextThreshold, .setCardModel,
             .archiveCard, .deleteCard, .reorderCard, .reorderPinnedCard, .updatePrompt,
             .addIssueLinkToCard, .addPRToCard, .markPRMerged, .unlinkFromCard, .createManualTask:
            return true
        default:
            return false
        }
    }

    /// Whether a served card is worth sending to peers: tombstones and every
    /// card someone placed on the board, not the thousands of discovered
    /// transcripts that live in All Sessions only.
    public static func isServed(_ link: Link) -> Bool {
        link.isTombstone || link.isClaimed || link.column != .allSessions
    }
}

// MARK: - AppState sync bookkeeping

extension AppState {
    /// Next Lamport stamp of this machine.
    func nextSyncStamp() -> SyncStamp {
        syncClock += 1
        return SyncStamp(counter: syncClock, machine: localMachineId)
    }

    /// Records that `id` changed, for the delta a peer pulls next.
    func markSyncChanged(_ id: String) {
        syncSeq += 1
        linkSeqs[id] = syncSeq
    }

    public func isOwnedLocally(_ link: Link) -> Bool {
        LinkSync.isOwnedLocally(link, localMachine: localMachineId)
    }

    /// Takes the tombstones and clock from what links.json held at startup.
    public func loadSyncState(tombstones stored: [Link], now: Date = .now) {
        var kept: [String: Link] = [:]
        for t in stored where t.isTombstone && !LinkSync.isExpired(t, now: now) && links[t.id] == nil {
            kept[t.id] = t
        }
        tombstones = kept
        var clock = syncClock
        for link in links.values {
            clock = max(clock, link.rev?.counter ?? 0, link.ownerRev?.counter ?? 0)
        }
        for t in kept.values {
            clock = max(clock, t.rev?.counter ?? 0, t.ownerRev?.counter ?? 0)
        }
        syncClock = clock
    }

    /// The page a peer gets from `GET /v1/links?since=&epoch=`: every served
    /// card and tombstone when the epoch differs (or none was sent), else
    /// those changed after `since`. Cards this machine owns go out with its
    /// id as `ownerMachine`.
    public func linksPage(machine: MachineIdentity, since: Int?, epoch: String?) -> LinksPage {
        let full = since == nil || epoch != syncEpoch
        let threshold = full ? Int.min : since!
        var out: [Link] = []
        func add(_ link: Link) {
            guard LinkSync.isServed(link) else { return }
            if !full, (linkSeqs[link.id] ?? 0) <= threshold { return }
            var copy = link
            if copy.ownerMachine == nil { copy.ownerMachine = machine.id }
            copy.browserTabs = nil
            copy.lastOpenedAt = nil
            out.append(copy)
        }
        for link in links.values { add(link) }
        for t in tombstones.values { add(t) }
        out.sort { $0.id < $1.id }
        return LinksPage(machine: machine, epoch: syncEpoch, seq: syncSeq, full: full, links: out)
    }
}

// MARK: - Reducer hooks

extension Reducer {
    /// Stamps what `action` changed in the cards, and holds foreign cards to
    /// what their owner sent. Runs after every action that persists cards.
    ///
    /// For each changed card: a card another master owns is put back as it
    /// was unless the action is a user edit of shared fields, and even then
    /// its owner fields are put back. Then `rev` is stamped when a shared
    /// field changed and `ownerRev` when an owner field of a card this
    /// machine owns changed. A card that disappeared leaves a tombstone.
    static func stampLocalChanges(state: AppState, before: [String: Link], action: Action, effects: [Effect]) -> [Effect] {
        var fullScan = false
        var upserted: Set<String> = []
        for effect in effects {
            switch effect {
            case .persistLinks, .removeLink: fullScan = true
            case .upsertLink(let link): upserted.insert(link.id)
            default: break
            }
        }
        guard fullScan || !upserted.isEmpty else { return effects }

        let allowsForeign = LinkSync.allowsForeignEdits(action)
        var linksRewritten = false
        var tombstonesChanged = false
        var restoredRemovals: Set<String> = []

        func stamp(_ id: String, _ after: Link) {
            let old = before[id]
            if let old, old == after { return }
            var link = after
            let owned = state.isOwnedLocally(old ?? after)
            if !owned, let old {
                guard allowsForeign else {
                    state.links[id] = old
                    linksRewritten = true
                    return
                }
                LinkSync.copyOwned(from: old, to: &link)
            }
            if old == nil, state.tombstones.removeValue(forKey: id) != nil {
                tombstonesChanged = true
            }
            let sharedChanged = old.map { !LinkSync.sharedEqual($0, link) } ?? true
            let ownedChanged = owned && (old.map { !LinkSync.ownedEqual($0, link) } ?? true)
            if sharedChanged { link.rev = state.nextSyncStamp() }
            if ownedChanged { link.ownerRev = state.nextSyncStamp() }
            if sharedChanged || ownedChanged { state.markSyncChanged(id) }
            if link != after {
                state.links[id] = link
                linksRewritten = true
            }
        }

        if fullScan {
            for (id, after) in state.links { stamp(id, after) }
            let now = Date()
            for (id, old) in before where state.links[id] == nil {
                if !state.isOwnedLocally(old), !allowsForeign {
                    state.links[id] = old
                    restoredRemovals.insert(id)
                    linksRewritten = true
                    continue
                }
                state.tombstones[id] = LinkSync.tombstone(of: old, deletedAt: now, rev: state.nextSyncStamp())
                state.markSyncChanged(id)
                tombstonesChanged = true
            }
        } else {
            for id in upserted {
                if let after = state.links[id] { stamp(id, after) }
            }
        }

        guard linksRewritten || tombstonesChanged else { return effects }
        var out: [Effect] = effects.compactMap { effect in
            switch effect {
            case .upsertLink(let link):
                return .upsertLink(state.links[link.id] ?? link)
            case .persistLinks:
                return .persistLinks(Array(state.links.values))
            case .removeLink(let id):
                return restoredRemovals.contains(id) ? nil : effect
            default:
                return effect
            }
        }
        if tombstonesChanged {
            out.append(.persistTombstones(Array(state.tombstones.values)))
        }
        return out
    }

    /// `.peerLinksMerged`: merges a peer's page into the board. A tombstone
    /// that deletes a card this machine runs also stops its terminals and
    /// keeps the reconciler from bringing it back.
    static func reducePeerLinksMerged(state: AppState, peer: String, incoming: [Link]) -> [Effect] {
        let outcome = LinkSync.mergePage(
            incoming, from: peer,
            links: state.links, tombstones: state.tombstones,
            localMachine: state.localMachineId, clock: state.syncClock, now: Date())
        state.syncClock = outcome.clock
        let tombstonesPruned = outcome.tombstones.count != state.tombstones.count
        guard !outcome.changedIds.isEmpty || tombstonesPruned else { return [] }

        state.links = outcome.links
        state.tombstones = outcome.tombstones
        for id in outcome.changedIds.sorted() { state.markSyncChanged(id) }

        var effects: [Effect] = []
        for link in outcome.deletedOwned {
            state.deletedCardIds.insert(link.id)
            if let sessionId = link.sessionLink?.sessionId { state.deletedSessionIds.insert(sessionId) }
            if let tmux = link.tmuxLink {
                effects.append(.killTmuxSessions(tmux.allSessionNames))
                effects.append(.cleanupTerminalCache(sessionNames: tmux.allSessionNames))
            }
        }
        if let selected = state.selectedCardId, state.links[selected] == nil {
            state.selectedCardId = nil
        }
        effects.append(.persistLinks(Array(state.links.values)))
        effects.append(.persistTombstones(Array(state.tombstones.values)))
        return effects
    }
}
