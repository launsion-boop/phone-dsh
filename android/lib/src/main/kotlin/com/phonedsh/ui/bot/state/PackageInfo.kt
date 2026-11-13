// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

/**
 * # P09 Bot UI-state seam — API summary
 *
 * This package is the whole view-side seam of a Bot page. It is pure JVM Kotlin
 * (no Compose, no `android.*`) and owns only values and derivations; the pages
 * in lane K5 render it. Every rule is a pure function whose clock input is an
 * explicit `now` in epoch milliseconds. The authority is
 * `spec/ui/v1/bot/ui-state.md` (round 2 includes the UI-1 and UI-2 decisions);
 * the shared vectors are under `spec/ui/v1/bot/golden/`.
 *
 * ## Values (decode/encode; :bot types are reused)
 *
 * - [BotActivity], [BotActivityStatus], [BotActivityCategory], [BotWorkStyle],
 *   [BotFishReaction], [BotFishReactionKind], [BotRuntimePresentation],
 *   [BotFishOneShot]/[com.phonedsh.bot.fish.BotFishLifecycle] (from `:bot`).
 * - [BotRuntimeState] (`idle|preparing|connecting|ready|recovering|failed(msg)|stopped`).
 * - [BotRosterRuntimeState], [BotRosterEntry] (uses
 *   [com.phonedsh.bot.profile.BotFishAppearance]), [BotRosterOrdering].
 * - [BotInfoSnapshot] plus [BotMemoryDocumentInfo], [BotRoutineInfo],
 *   [BotApprovalRecord], [BotGrantInfo], [BotReconciliationInfo],
 *   [RoutinePresence], [ProactiveSettings], [BotMaintenanceBatchInfo]; the
 *   three load states via [BotInfoLoadState] and [BotInfoModelState].
 * - [BotDrawerIntent], [BotInfoIntent], [BotAppearanceIntent],
 *   [BotDeepLink]/[BotDeepLinkDestination], [BotDeepLinkOutcome],
 *   [BotNameValidation], [BotAppearanceSelection].
 * - Rows are `:bot`'s `BotRow`/`BotRowBatch`; [BotUIRowCodec] is the P09
 *   decoder and normalises the UI-only `cardType: "attachment"`.
 *
 * ## Derivations
 *
 * - [BotUIRendering] and [BotUICardContent] with [BotUIChoice],
 *   [BotUIProgressStep], [BotUIChecklistItem], [BotUILink],
 *   [BotUIAttachmentParser]: fail-closed card parsing, renderability, surface,
 *   copy text, and every card sub-value.
 * - [BotSettlementRules] (`null` keeps the card full),
 *   [BotSettlementGlyph], [BotSettlementTone], [BotCardSettlement].
 * - [BotMutedCards], [BotCounts] (pending / attention / following).
 * - [BotHeaderPresence] with [BotHeaderPhase], [BotHeaderMotion].
 * - [BotActivityPhrases] (tool → category/phrase, cleaning, target, rotation,
 *   work style, minute suffix) and [BotActivityLineState] (800 ms hold,
 *   2 400 ms rotation, next-deadline); [BotActivityLine] is the output.
 * - [BotUiStateInput] → [BotUiStateDerivation.derive] → [BotUiState], which is
 *   exactly the `ui-state-vectors.json` expected object (including the shared
 *   `fishState`).
 * - [BotFishProjection] is the single UI-1 lifecycle projection consumed by
 *   the page and roster (priority: pending approval, unexpired one-shot, live
 *   over durable, running idle→working, idle sleeping, idle).
 * - [BotActionStateMachine] is the per-key UI-2 action state machine
 *   (`pending|accepted|failed`); [BotActionRetryPolicy] is the frozen guard
 *   where a failed key — including `cardDismiss` — is retryable and
 *   pending/accepted are ignored.
 * - [BotTimers] carries every frozen duration; no page retypes one.
 *
 * ## Data and tests
 *
 * [BotUiStrings] is generated from `spec/ui/v1/bot/strings.json`;
 * [BotActivityPhraseData] from `activity-phrases.json`. Golden tests read the
 * spec files and vectors from disk through the `pdsh.repo.root` system
 * property and prove the generated data is byte-identical, so a spec edit
 * either flows through or fails the build. No test carries a hand-copied
 * vector. The model-written description always wins over the phrase table but
 * never changes the category.
 */
public object BotUiStateSeam {
    /** This object exists only so the package KDoc has a compilable file. */
    public const val CONTRACT: String = "spec/ui/v1/bot/ui-state.md"
}
