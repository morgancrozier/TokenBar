---
status: active
id: kb-glossary
kind: canonical
scope: repository
read_when: naming a quota concept, a module that owns one, or a key that identifies a window
last_verified: 2026-10-22
sources: ["Sources/TokenBarCore/QuotaWindowRef.swift", "Sources/TokenBarCore/AccountIdentity.swift", "Sources/TokenBarCore/QuotaResolver.swift", "Sources/TokenBar/QuotaLens.swift", "Sources/TokenBar/WindowCardLoader.swift", "Sources/TokenBar/WindowCardLoading.swift", "crates/tb_core_ffi/src/agent_quota_history.rs"]
---

# Domain glossary

## 文件目的

這份文件定義 TokenBar quota 相關的領域名詞，讓 code、review 與文件用同一個字指同一件事。名詞只在它真的被 code 使用、且容易與另一個名詞混淆時才收錄；定義以 code 的實際行為為準。

## Quota windows

| Term | Meaning | Not to be confused with |
|---|---|---|
| Quota window | One provider allowance: used and remaining percent, `resetsAt`, `durationSeconds`, an optional model scope. `UsageWindow` on the Swift side. | A usage-trace or chart window |
| Card id | A window's stable identity within one account's snapshot, such as `session.v1` or `weekly_scoped.fable.v1`. Its `label` is what the provider calls it and is display-only. | Window key |
| Window key | `paceStatus.windowKey`: the identity of the window's durable pace series and persisted quota curve. Can differ from the card id (Grok's `billing.weekly.v1` card reads the `billing.weekly.v2` series). | `QuotaWindowRef.key` |
| Account | Which subscription of a client a window belongs to. `AccountIdentity` is the pair (client id, account key); a nil account key is the primary, otherwise it is an extra Claude `CLAUDE_CONFIG_DIR` path. | `AccountScope` / `HistoryScope`, the Rust identities for cache and durable history |
| Window reference | `QuotaWindowRef`: one window of one account, the value every quota surface stores, looks up and lists windows by. Its string `key` is built from it and never parsed back — an extra account's key has a path in its middle segment. | A selection |
| Selection | A persisted choice of which window a surface shows: `auto`, or `<clientId>|<cardId>` for a primary account. Parsed only by `QuotaResolver.parseExplicitSelection`. An extra account's selection lives under its own storage key. | A window reference |
| Model scope | The model a scoped window's allowance counts. Narrows what is displayed and estimated, never where the window is placed. | Attribution |

## Cycles and estimates

| Term | Meaning |
|---|---|
| Cycle | One completed reset group of a window's curve, with its consumption, peak and observed fraction. The engine decides cycle membership (`isActiveGroup`); Swift must not re-derive it. |
| Considered / admitted cycles | The newest cycles kept (capped at 32), then those with enough movement and observed coverage to support an estimate. |
| Equivalence | Tokens and cost per tenth of a percent of a window's allowance, joined from admitted cycles and attributed usage. Needs at least three admitted cycles. |
| Pace | Expected versus actual burn of a window, on a historical or linear basis. |

## The Quota lens

| Term | Meaning |
|---|---|
| Quota lens | The dashboard view of quota windows: the detail card, strips, heatmap and estimates. `QuotaLens` owns what it shows and the rules for replacing each part when a refresh cannot answer. |
| Quota half / usage half | Stage 1, from the payload and persisted curves alone and instant; stage 2, from one message scan. |
| Union scan | The one cached message scan every card filters from, served as fresh for 30 seconds. |
