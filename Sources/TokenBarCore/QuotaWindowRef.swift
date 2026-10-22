import Foundation

/// One quota window of one account: the identity every quota surface stores
/// windows under, looks them up by, and lists them as.
///
/// A value, not a string. `key` exists because the heatmap picker persists it
/// and SwiftUI lists use it as an `Identifiable.id`, but it is only ever BUILT
/// from a `QuotaWindowRef` and never parsed back into one. An extra account's key
/// carries a `CLAUDE_CONFIG_DIR` path in its middle segment, and every
/// hand-written split of it read the first `|` as the end of the client and
/// everything after as the card — which names no card at all. The lookup then
/// found nothing and reported nothing: the extra account's equivalence estimate
/// lost its model scope that way, with no surface showing the miss.
public struct QuotaWindowRef: Hashable, Sendable {
    public let account: AccountIdentity
    public let cardId: String

    public init(account: AccountIdentity, cardId: String) {
        self.account = account
        self.cardId = cardId
    }

    public init(clientId: String, accountKey: String?, cardId: String) {
        self.init(
            account: AccountIdentity(clientId: clientId, accountKey: accountKey),
            cardId: cardId)
    }

    public var clientId: String { account.clientId }
    public var accountKey: String? { account.accountKey }

    /// The string form, for the places that must hold a string.
    ///
    /// The primary keeps the exact two-part shape callers have always stored
    /// (`"<clientId>|<cardId>"`), which is also `QuotaResolver`'s canonical
    /// persisted selection — so nothing a plain client has already written to
    /// disk changes. Only an extra account's key grows a third segment.
    public var key: String {
        guard let accountKey else { return "\(clientId)|\(cardId)" }
        return "\(clientId)|\(accountKey)|\(cardId)"
    }

    /// The snapshot this window belongs to, matched on client AND account.
    /// Client alone returns whichever account the payload lists first, which
    /// for an extra account is the primary — a different subscription that
    /// can offer an identically-carded window.
    public func snapshot(in payload: AgentUsagePayload) -> AgentUsageSnapshot? {
        payload.agents.first { $0.accountIdentity == account }
    }

    public func window(in payload: AgentUsagePayload) -> UsageWindow? {
        snapshot(in: payload)?.uniqueCardWindows.first { $0.cardId == cardId }
    }
}

extension AgentUsageSnapshot {
    /// The reference to one of this snapshot's own windows.
    public func ref(for window: UsageWindow) -> QuotaWindowRef {
        QuotaWindowRef(account: accountIdentity, cardId: window.cardId)
    }
}
