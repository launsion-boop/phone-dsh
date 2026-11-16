<!-- SPDX-License-Identifier: MIT -->
# iOS Bot activity: readable type and restrained transitions

Contract revision: `activity-ui-v2`, frozen 2026-11-16.
Base: `2b167fc99980bee430ea6d90f1ef46b852de30b3`.
Protocol impact: P09; P27: none — no row/action/persistence shape change;
P26: none — model/tool activity semantics are unchanged.

The user asks for a more readable Bot activity bubble and natural dynamic text
changes. This is an iOS presentation refinement of `activity-evidence-v3.5`.
The bubble remains single-line, non-interactive and outside the transcript's
scroll content. No new state, model call, tool, control, history or detail view.

Latest user ruling: waiting for a response and streaming a reply show **only
three dots** in this same bubble, without the visible words `等待响应` or
`正在回复`. This supersedes the earlier no-dots presentation requirement.
Real task progress, approvals and errors retain their text. The internal
activity values remain compatible; no placeholder message is inserted into the
transcript. Accessibility uses a meaningful phase label rather than reading
three punctuation marks aloud.

## Frozen presentation

- Default text: 16 pt medium, 22 pt line box, replacing 13/18. Text and line box
  scale together with Dynamic Type relative to callout. The reserved band is
  `max(38, scaledLineBox + 16)` points whether visible or hidden; it changes
  only with the user's text-size setting, never with the activity sentence.
- Surface: existing Bot bubble shape, surface and 0.5 pt border; 12 pt horizontal
  padding. The width hugs the current sentence, capped at 94% of the content
  column (previously 86%). Long text truncates at the tail; the accessibility
  label retains the complete short activity sentence. No hit testing.
- Text color: light `#53606D`, dark `#C3CAD4`. A subtle white highlight uses
  opacity 0.12/0.30; the steady text remains readable throughout the sweep.
  Failure uses the existing light danger red `#C0392B` and dark error token
  `#F25A5A`. No whole-text opacity breathing.
- Sentence changes: approximately 220 ms ease-out crossfade with at most 3 pt
  vertical movement. Outgoing text is an overlay and must not hold the bubble's
  intrinsic width or cause a second resize at transition completion. The bubble
  surface may ease to its new width; the reserved band and composer do not move.
- Reduce Motion: no sweep, slide or size animation. Prefer Cross-Fade: opacity
  transition only. Inactive pages and waiting/error states stop ambient motion.
- Three dots are 5 pt at the default text size, separated by 4 pt, with a subtle
  staggered pulse and at most 2 pt lift. Reduce Motion/inactive pages use static
  dots. The waiting-to-reply transition keeps the same dots without restarting
  the visual cue. Dots and text occupy the same reserved-height band.
- Keep the existing 800 ms latest-wins scheduling for normal progress. Waiting
  for user action and failures bypass pending display dwell so an obsolete work
  sentence is not briefly recolored as an error or approval.

## Compatibility and ownership

Old/new model events, stored rows and clients are unchanged. This has no wire,
schema, capability or version negotiation, and requires no migration. Android
and the native DSH chat are out of scope. Root owns the iOS views and matching
capture fixture/checks; the completed Bot runtime work stays frozen.

The authoritative iOS display clause is updated in
`spec/ui/v1/bot/ios/activity-evidence.md`. Earlier 13/18, 32 pt and 86% descriptions
are historical for this surface.

## Acceptance

Build and inspect the production Bot views in the iOS Simulator at light/dark
appearance and normal/enlarged text. Exercise actual sentence changes and
waiting/error transitions in the existing fixture harness; check stable composer
position, no new hit target, readable text and tail truncation. Save before/after
screenshots and a short motion recording. Label fixture playback separately
from the already recorded real-model content evidence; no additional model
sampling is needed for these visual-only changes. Record any unrun system
accessibility/device checks explicitly.

Design references: [Apple typography](https://developer.apple.com/design/human-interface-guidelines/typography),
[Apple motion](https://developer.apple.com/design/human-interface-guidelines/motion),
[ScaledMetric](https://developer.apple.com/documentation/swiftui/scaledmetric).
