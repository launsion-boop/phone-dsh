// PCLink page metrics (P09/P28).
// SPDX-License-Identifier: MIT
//
// The two PCLink page contracts carry structure and labels, not geometry, and
// the shared HomeSpec table has no PC row. These are the page-local values used
// by PCPairingPage / ConnectedComputerPage / PcDrawer, kept here so the page
// sources (and the drawer) never re-type a length. They mirror the iOS page's
// own literals (16pt content inset, 50pt primary pill, 44pt row floor).
package com.phonedsh.ui

import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Page-local PCLink geometry; see the file header for provenance. */
public object PcMetrics {
    /** Content inset shared by the pairing and connected pages (`PCPairingPage.swift:118`). */
    public val PAGE_INSET = 16.dp

    /** Section/row vertical gap. */
    public val SECTION_GAP = 8.dp

    /** Tight gap between a label and its field. */
    public val TIGHT_GAP = 4.dp

    /** Gap between a field and its hint. */
    public val LABEL_GAP = 6.dp

    /** Padding inside a text field or command card. */
    public val FIELD_INSET = 10.dp

    /** Hairline border on the grouped cards. */
    public val HAIRLINE = 0.5.dp

    /** Card corner radius. */
    public val CARD_RADIUS = 10.dp

    /** Text-field corner radius. */
    public val FIELD_RADIUS = 8.dp

    /** The primary capsule height (`HomeSpec.homePrimaryButtonHeight`). */
    public val PRIMARY_HEIGHT = 50.dp

    /** Primary capsule label inset. */
    public val PRIMARY_VERTICAL = 12.dp

    /** Busy spinner box. */
    public val PROGRESS_SIZE = 18.dp

    /** Busy spinner stroke. */
    public val PROGRESS_STROKE = 2.dp

    /** The install command's monospaced size (`PCPairingPage.swift:122`). */
    public val COMMAND_TEXT_SIZE = 11.5.sp

    /** Online-status dot (`ConnectedComputerPage.swift:70`). */
    public val STATUS_DOT = 7.dp

    /** Gap between the status dot and its word (`ConnectedComputerPage.swift:73`). */
    public val STATUS_GAP = 5.dp

    /** Vertical inset of a status row. */
    public val ROW_VERTICAL = 12.dp

    /** List-row top/bottom gap. */
    public val LIST_GAP = 8.dp
}
