import Foundation
import TokenBarCore

/// Everything the Quota lens shows, and the rules for replacing it when a
/// refresh brings new readings.
///
/// The rules are what this module is for. Keep a drawn card when a curve read
/// throws; never replace a complete set of summaries with a partial one; tell a
/// user hiding their last client apart from graph data that has not arrived
/// yet; never keep one window's history under another window's card. Each was
/// learned from a fix, and each used to be an `if` inside `DashboardModel`,
/// where only a whole model over a fake data source could reach it. Here they
/// are one value and three transitions: a test hands in readings and reads the
/// state back.
///
/// No I/O of its own. Curves are read through the `readCurve` the caller
/// passes, and the scan, the attribution declarations and the clock arrive in
/// `Inputs`. What still reaches out is `WindowCardLoader`'s read of the card's
/// persisted window selection.
struct QuotaLens {
    /// `(clientId, accountKey, windowKey, generation)` to that window's
    /// persisted curve. Throws on a transient generation expiry, which is not
    /// the same answer as a nil (no history) and must not be flattened into one.
    typealias CurveRead = (String, String?, String, UInt64) throws -> QuotaCurve?

    /// What one refresh is about, captured from the model when it runs.
    struct Inputs {
        var payload: AgentUsagePayload?
        /// Whether a quota fetch has settled at least once — what turns an
        /// absence from a wait into an answer.
        var attempted: Bool
        /// Clients with a row on screen. Drives the curve reads.
        var cardClients: [String]
        /// The client whose tab is open, or nil on the all-agent overview.
        /// Drives the history and the scan; see `DashboardModel.windowUsageClient`.
        var usageClient: String?
        /// Graph data has arrived, so an empty `cardClients` is the user's
        /// answer rather than a view that has not loaded yet.
        var graphArrived: Bool
        var scan: UnionScan?
        /// `scan` is still inside the window in which it is served as fresh.
        var scanIsFresh: Bool
        var scanFailedClients: Set<String>
        var confirmed: [UsageAttribution.Record]
        var nowMs: Int64
    }

    /// Card state per client. Never absent while an agent tab is open — the
    /// loading case is a state, not a nil.
    private(set) var windowCards: [String: WindowCardState] = [:]

    /// Quota readings for EVERY window each client offers, per account.
    ///
    /// `windowCards` above holds only the selected window, which is all the
    /// detail card needs. The Agent-limits sparkline draws one line per row, so
    /// it needs the others too. Each entry is a ~2ms read of an already
    /// persisted file, so filling all of them stays inside the "instant" half.
    private(set) var windowCurves: [QuotaWindowRef: [QuotaSample]] = [:]

    /// Recorded reset cycles of the open tab's selected window, newest first.
    /// Derived from the persisted curve alone, so it lands with stage 1.
    private(set) var quotaCycles: [QuotaCycle] = []
    /// Those cycles joined to what was spent in them. Empty until the scan
    /// lands; the card shows the cycles with a loading row in the meantime,
    /// because the quota half is honest on its own and waiting for the usage
    /// half would hide it for seconds.
    private(set) var quotaHistory: [QuotaHistoryRow] = []
    /// Which window's cycles `quotaCycles` currently holds — client AND card,
    /// not client alone. Two window selections share a client, so a client-only
    /// comparison could keep the previous window's history beneath the newly
    /// selected card. Nil when empty.
    private(set) var quotaCyclesWindow: QuotaWindowRef?

    /// Whether the persisted curve could not be READ, as distinct from having
    /// no history in it.
    ///
    /// `QuotaHistoryCard` decides on `cycles.isEmpty` and `attempted`, and an
    /// unreadable curve is empty-and-attempted exactly like a window that has
    /// simply not accumulated anything — so it stated "No earlier windows
    /// recorded yet" about a curve it had failed to open, and kept stating it
    /// until some later refresh happened to retry. The same distinction the
    /// usage half already draws with `windowScanFailedClients`; the quota half
    /// had no way to say it.
    private(set) var quotaCurveUnreadable = false

    /// Recorded-cycle summaries for EVERY displayed client's windows, for the
    /// all-agent lens. Curve reads only, so unlike `quotaHistory` this needs no
    /// message scan and is safe on the landing view.
    private(set) var quotaWindowSummaries: [QuotaWindowSummary] = []
    /// One weekday-by-hour grid per window, keyed as `QuotaWindowSummary.ref`.
    /// Written in the same guarded block as the summaries, so it cannot be
    /// blanked by a refresh that saw no clients either.
    private(set) var quotaHeatmaps: [QuotaWindowRef: QuotaHeatmap] = [:]
    /// Every window that has a grid, heaviest first. Separate from the
    /// summaries because a window can have movement in its running cycle and no
    /// completed history at all.
    private(set) var quotaHeatmapWindows: [QuotaHeatmapWindow] = []
    /// Per-window quota equivalence, per account. Only windows
    /// with enough admitted cycles appear. Empty until the scan lands — the
    /// strips above it are free and must not wait for this.
    private(set) var quotaEquivalences: [QuotaWindowRef: WindowEquivalence.Row] = [:]
    /// Cycles per qualifying window, kept from stage 1 so the scan can be
    /// scoped to exactly what an estimate needs and no further.
    private(set) var qualifyingCycles: [QuotaWindowRef: [QuotaCycle]] = [:]

    /// Stage 1. Synchronous and local: reads the payload already in memory and
    /// the persisted quota curves, and never waits on the network or the scan.
    mutating func refreshQuotaHalves(_ inputs: Inputs, readCurve: CurveRead) {
        let now = inputs.nowMs
        if let payload = inputs.payload {
            for agent in payload.agents where inputs.cardClients.contains(agent.clientId) {
                for window in agent.uniqueCardWindows {
                    // A failed read keeps whatever the row already had. Blanking
                    // it would drop a drawn sparkline to a bar for one refresh
                    // and put it back on the next — a flicker that says nothing.
                    guard let samples = WindowCardLoader.curveSamples(
                        payload: payload, clientId: agent.clientId, accountKey: agent.accountKey,
                        window: window, curve: readCurve, nowMs: now)
                    else { continue }
                    windowCurves[agent.ref(for: window)] = samples
                }
            }
        }
        for clientId in inputs.cardClients {
            let state = WindowCardLoader.quotaHalf(
                payload: inputs.payload, clientId: clientId,
                attempted: inputs.attempted,
                curve: readCurve, nowMs: now)
            // Fold in a usage half we already hold, so a stage-1 refresh does
            // not throw away a completed scan and blink back to loading.
            // The scan's AGE, not just its existence. A covering scan that has
            // aged past `unionScanMaxAge` and whose replacement then threw left
            // this branch winning over the failure branch below, so the card
            // returned to `.ready` with arbitrarily stale totals instead of
            // saying the refresh failed. Freshness is what `.ready` claims.
            if case let .quotaOnly(q, _) = state, let scan = inputs.scan,
               inputs.scanIsFresh
                   || !inputs.scanFailedClients.contains(clientId),
               let (settled, usage) = WindowCardLoader.usageHalf(
                   quota: q, scan: scan, confirmed: inputs.confirmed) {
                windowCards[clientId] = .ready(settled, usage)
            } else if case let .quotaOnly(q, _) = state,
                      inputs.scanFailedClients.contains(clientId) {
                // The loader cannot know this — it never runs the scan. Carried
                // in here so the card can say the scan failed instead of
                // spinning under a chart that is already drawn.
                windowCards[clientId] = .quotaOnly(q, scanFailed: true)
            } else if case .loading = state,
                      let held = windowCards[clientId]?.cardId,
                      held == WindowCardLoader.selectedWindow(
                          payload: inputs.payload, clientId: clientId)?.key {
                // A curve read that throws is a transient generation expiry —
                // `quotaHalf` answers `.loading`, which is right as an answer
                // and wrong as a replacement. Overwriting sent a drawn card
                // back to "Waiting for quota…" until a later refresh, which is
                // the flicker the summaries block a few lines down already
                // refuses to produce. Keep what the row had; the next refresh
                // publishes the new state.
                //
                // Only when the held card is about the window now selected:
                // two selections share a client, so retaining by client alone
                // left the chart and totals on the window the user had just
                // navigated away from while the picker highlighted the new one.
                continue
            } else {
                windowCards[clientId] = state
            }
        }

        // Strip summaries cover every displayed client. They read curves only,
        // so the cost is `windowCardClients.count` file reads, not a scan.
        //
        // Skipped entirely when no client is on screen, for the same reason the
        // curve loop above keeps what a failed read already had: `collected`
        // would be empty because there was nothing to collect FROM, and
        // publishing that empty as the answer makes the strip card state "no
        // completed windows recorded yet". `windowCardClients` is assigned from
        // `displayClients`, which arrives with graph data, so it is briefly
        // empty whenever the top-level view changes — which is exactly when the
        // card was seen blanking and coming back.
        // An empty client set has two causes. `displayClients` arrives with
        // graph data, so before that it is empty transiently — publishing then
        // overwrote a populated strip with nothing on every top-level view
        // change. But the user hiding their last visible client is ALSO an
        // empty set, and a permanent one: skipping publication there left the
        // strip and the grid showing a client that is no longer on screen.
        // `graphArrived` — the model's `stats` — is the graph's own arrival
        // signal, so it separates the two.
        if inputs.cardClients.isEmpty, inputs.graphArrived {
            quotaWindowSummaries = []
            quotaHeatmaps = [:]
            quotaHeatmapWindows = []
            qualifyingCycles = [:]
        }
        if let payload = inputs.payload, !inputs.cardClients.isEmpty {
            var collected: [(clientId: String, accountKey: String?, cardId: String, label: String,
                             cycles: [QuotaCycle])] = []
            var heatmaps: [QuotaWindowRef: QuotaHeatmap] = [:]
            var heatmapWindows: [QuotaHeatmapWindow] = []
            // A THROWN read is a transient generation expiry, which happens
            // when another publication lands while these synchronous reads run.
            // Skipping that window and publishing the rest would drop it from
            // the strip and the heatmap until some later refresh — the same
            // "absent because we could not ask" mistake, arriving through a
            // partial result rather than an empty one. A successful nil is
            // still genuinely no history and still skips.
            var readFailed = false
            for agent in payload.agents where inputs.cardClients.contains(agent.clientId) {
                for window in agent.uniqueCardWindows {
                    guard let key = window.paceStatus.windowKey,
                          let generation = payload.publicationGeneration
                    else { continue }
                    let attempt: QuotaCurve?
                    do { attempt = try readCurve(agent.clientId, agent.accountKey, key, generation) }
                    catch { readFailed = true; continue }
                    guard let curve = attempt else { continue }
                    let points = curve.points
                    let grid = QuotaHeatmapFold.build(points: points)
                    // Per account: two accounts of the same client can offer
                    // identically-carded windows, and a client-only key would
                    // let one overwrite the other's grid.
                    heatmaps[agent.ref(for: window)] = grid
                    // Unplaced-only windows stay in the picker. `total` is
                    // zero when every reading pair straddles more than six
                    // hours, but the allowance still moved; dropping the window
                    // made the card report "nothing recorded yet" and put the
                    // line that explains it out of reach.
                    if grid.hasMovement {
                        heatmapWindows.append(QuotaHeatmapWindow(
                            clientId: agent.clientId, accountKey: agent.accountKey,
                            cardId: window.cardId,
                            windowLabel: window.label, total: grid.total))
                    }
                    collected.append((
                        clientId: agent.clientId, accountKey: agent.accountKey,
                        cardId: window.cardId,
                        label: window.label,
                        cycles: QuotaHistoryFold.cycles(
                            points: points)))
                }
            }
            // Skip this publication rather than replace a complete set with a
            // partial one. Deliberately not an early `return`: the per-client
            // cycles below are read through a different path and have their own
            // error handling, and suppressing them here would trade one stale
            // surface for another.
            if !readFailed {
                quotaWindowSummaries = QuotaOverviewFold.summaries(windows: collected)
                quotaHeatmaps = heatmaps
                quotaHeatmapWindows = heatmapWindows.sorted { $0.total > $1.total }
                qualifyingCycles = Dictionary(
                    uniqueKeysWithValues: collected.compactMap {
                        window -> (QuotaWindowRef, [QuotaCycle])? in
                        // Capped BEFORE admitting, which is what the probe
                        // sweep measured and what actually bounds the scan:
                        // capping the admitted count instead would let 32
                        // admitted cycles span a hundred recorded ones.
                        // `collected` keeps the full list for the lifetime
                        // summaries below.
                        let admitted = QuotaHistoryFold.considered(window.cycles).filter {
                            $0.usedPercent >= WindowEquivalence.minimumDelta
                                && $0.observedFraction >= WindowEquivalence.minimumObservedFraction
                        }
                        guard admitted.count >= WindowEquivalence.minimumCycles else { return nil }
                        // Per account, like the grids. Two accounts of one
                        // client offering the same window would otherwise
                        // collide here, and `uniqueKeysWithValues` traps on a
                        // duplicate key rather than reporting it.
                        return (
                            QuotaWindowRef(
                                clientId: window.clientId, accountKey: window.accountKey,
                                cardId: window.cardId),
                            admitted
                        )
                    })
            }
        }

        // Cycles follow the scan's client, not every displayed one: the history
        // is a per-subscription list and only the open tab shows it.
        //
        // The client the published cycles belong to is tracked, because "keep
        // what we had" is only safe while the question has not changed. A
        // transient read failure on B used to leave A's cycles published, and
        // `QuotaView` then drew them under B's name — one subscription's
        // history labelled as another's, which is worse than an empty card and
        // indistinguishable from a correct one.
        if let client = inputs.usageClient {
            let selected = WindowCardLoader.selectedWindow(
                payload: inputs.payload, clientId: client)
            if let cycles = WindowCardLoader.cycles(
                payload: inputs.payload, clientId: client, curve: readCurve)
            {
                quotaCycles = cycles
                quotaCyclesWindow = selected
                quotaCurveUnreadable = false
                rebuildQuotaHistory(inputs)
            } else {
                // The read failed. Whether this branch clears or retains is
                // only about a window we already had — on a FIRST failure there
                // is nothing to clear, and the two are indistinguishable in
                // state. What the card needs is the fact that the read failed,
                // which no amount of rearranging here provides: it decides on
                // `cycles.isEmpty` and `attempted`, and an unread curve is
                // empty-and-attempted exactly like a window with no history.
                quotaCurveUnreadable = true
                if quotaCyclesWindow != selected || selected == nil {
                    // Could not read, and what we hold is about a different
                    // window — another client's, or another window of this one.
                    quotaCycles = []
                    quotaHistory = []
                    quotaCyclesWindow = nil
                }
            }
        } else {
            quotaCycles = []
            quotaHistory = []
            quotaCyclesWindow = nil
            quotaCurveUnreadable = false
        }
    }

    /// Joins the cycles to the scan, whenever either changes. Cheap enough to
    /// redo rather than track: the fold is one sorted pass over the scan.
    /// Joins each qualifying window's admitted cycles to the scan.
    ///
    /// Numerators come from each cycle's OBSERVED span, not its whole window:
    /// the delta only describes the interval between two readings, and counting
    /// usage from a stretch nobody sampled against movement nobody saw is the
    /// misalignment that cost 8 points of spread on live data.
    mutating func rebuildQuotaEquivalences(_ inputs: Inputs) {
        guard let scan = inputs.scan else { return }
        var built: [QuotaWindowRef: WindowEquivalence.Row] = [:]
        let confirmed = inputs.confirmed
        for (window, cycles) in qualifyingCycles {
            guard let oldest = cycles.last, scan.covers(start: oldest.evidenceStartMs)
            else { continue }
            // `declared` carries the empty-declaration case into the fold,
            // which is where the difference between "nothing recorded" and
            // "nothing classified" is defined.
            // The span rule and its numerators come from the same fold the
            // history card uses, sorted once and sliced per cycle. The filter
            // that used to live here re-walked the whole scan per cycle on the
            // main actor.
            let spans = QuotaHistoryFold.spans(
                cycles: cycles, messages: scan.messages, subscription: window.clientId,
                // Each estimate is narrowed to its own window's scope — that
                // account's window, not the primary's identically-carded one —
                // rather than to whichever window the card happens to show.
                modelScope: WindowCardLoader.modelScope(
                    payload: inputs.payload, window: window),
                confirmed: confirmed)
            built[window] = WindowEquivalence.aggregate(
                declared: !confirmed.isEmpty,
                cycles: zip(cycles, spans).map { cycle, span in
                    WindowEquivalence.Cycle(
                        deltaPercent: cycle.usedPercent, spanTokens: span.tokens,
                        spanCost: span.cost, observedFraction: cycle.observedFraction)
                })
        }
        quotaEquivalences = built
    }

    mutating func rebuildQuotaHistory(_ inputs: Inputs) {
        guard let client = inputs.usageClient, let scan = inputs.scan,
              let oldest = quotaCycles.last, scan.covers(start: oldest.evidenceStartMs)
        else {
            quotaHistory = []
            return
        }
        quotaHistory = QuotaHistoryFold.rows(
            cycles: quotaCycles, messages: scan.messages,
            // The attribution target for a subscription's own quota is that
            // subscription's client id: the window came from the provider that
            // bills it. A row whose usage was declared elsewhere is exactly
            // what the "other" column exists to show.
            subscription: client,
            // The window these cycles belong to, not the client's default: the
            // user can select a scoped window, and its history has to answer
            // for the same allowance the chart above it draws.
            modelScope: WindowCardLoader.modelScope(
                payload: inputs.payload, window: quotaCyclesWindow),
            confirmed: inputs.confirmed)
    }
}
