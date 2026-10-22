import Foundation

/// Identifies one quota-bearing account within a client. `accountKey` is nil
/// for the primary account — every account until an extra Claude config
/// directory is configured — and the `CLAUDE_CONFIG_DIR` absolute path for an
/// extra Claude account.
///
/// A pair, never an encoded string. `ClientRegistry.parseIdSet`,
/// `ClientRegistry.style(_:)`, `quotaExcludedClients()` and `QuotaResolver`
/// all compare `clientId` alone for equality; folding the account into that
/// string would silently stop matching in every one of them, and none of them
/// would report an error — the client would just look absent.
public struct AccountIdentity: Hashable, Sendable {
    public let clientId: String
    public let accountKey: String?

    public init(clientId: String, accountKey: String?) {
        self.clientId = clientId
        self.accountKey = accountKey
    }

    /// True for the primary account of `clientId` — every account today,
    /// except an extra Claude config directory.
    public var isPrimary: Bool { accountKey == nil }

    /// One window of this account. See `QuotaWindowRef` for why windows are keyed
    /// by that value rather than by a string built here.
    public func window(_ cardId: String) -> QuotaWindowRef {
        QuotaWindowRef(account: self, cardId: cardId)
    }

    /// The client's display name, qualified by `accountLabel` when this is not
    /// the primary — what every quota surface that names a subscription shows.
    ///
    /// One composition for all of them. Four views each joined the name and
    /// the label themselves, and adding the account to them took a commit that
    /// had to find every copy.
    public var displayName: String {
        [ClientRegistry.style(clientId).displayName, accountLabel]
            .compactMap(\.self).joined(separator: " ")
    }

    /// A short label naming which account this is, for any surface that shows
    /// the client's display name and would otherwise render two accounts
    /// identically. Nil for the primary, which needs no qualifier.
    ///
    /// The basename, not the path. The value is a directory under the user's
    /// home, and the surfaces that use this are the ones that end up in
    /// screenshots; the full path stays reachable through a tooltip for the
    /// case where two directories share a last component.
    ///
    /// It lives here rather than beside one of its callers because the label
    /// two views derive separately is the label they eventually derive
    /// differently, and the reader has no way to tell that the "work" in the
    /// limits card and the "work" in the overview line mean the same account.
    public var accountLabel: String? {
        guard let accountKey else { return nil }
        let name = (accountKey as NSString).lastPathComponent
        return name.isEmpty ? accountKey : name
    }
}

extension AgentUsageSnapshot {
    public var accountIdentity: AccountIdentity {
        AccountIdentity(clientId: clientId, accountKey: accountKey)
    }
}
