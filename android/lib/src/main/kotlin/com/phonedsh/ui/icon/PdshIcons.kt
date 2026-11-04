// PR22 native icon registry. Every mark is vector geometry, never text glyphs.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.icon

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Stable app icon identifiers. [sfSymbol] is the iOS system fallback; [sourceOwner] names a DSH asset when that view uses one. */
public enum class PdshIcon(
    public val sfSymbol: String,
    public val permissionOnly: Boolean = false,
    public val sourceOwner: String? = null,
    /** Explicit Swift font-weight variant when the owning view requests one. */
    public val sourceWeight: FontWeight? = null,
) {
    NEW_CHAT("square.and.pencil"),
    CLOCK("clock"),
    GEAR("gearshape"),
    FOLDER("folder"),
    SESSIONS("list.dash"),
    ARCHIVE("archivebox"),
    FOLDER_PLUS("folder.badge.plus"),
    CHEVRON_DOWN("chevron.down", sourceOwner = "Assets.xcassets/DSHChevronDown.imageset/DSHChevronDown.svg"),
    CHEVRON_UP("chevron.up"),
    CHEVRON_RIGHT("chevron.right"),
    CHEVRON_LEFT("chevron.left"),
    CLOSE("xmark", sourceOwner = "Assets.xcassets/DSHClose.imageset/DSHClose.svg"),
    CHECK("checkmark", sourceOwner = "Assets.xcassets/DSHCheck.imageset/DSHCheck.svg"),
    COPY("doc.on.doc", sourceOwner = "Assets.xcassets/DSHCopy.imageset/DSHCopy.svg"),
    TEXT_ALIGN_LEFT("text.alignleft"),
    ARROW_LEFT_RIGHT("arrow.left.and.right"),
    PLUS("plus"),
    MORE("ellipsis"),
    REFRESH("arrow.clockwise"),
    CPU("cpu"),
    THINK("brain.head.profile", sourceOwner = "Assets.xcassets/DSHThink.imageset/DSHThink.svg"),
    READ("circle", sourceOwner = "Assets.xcassets/DSHRead.imageset/DSHRead.svg"),
    EDIT("circle", sourceOwner = "Assets.xcassets/DSHEdit.imageset/DSHEdit.svg"),
    CODE("circle", sourceOwner = "Assets.xcassets/DSHCode.imageset/DSHCode.svg"),
    BRANCH("circle", sourceOwner = "Assets.xcassets/DSHBranch.imageset/DSHBranch.svg"),
    DATABASE("circle", sourceOwner = "Assets.xcassets/DSHDatabase.imageset/DSHDatabase.svg"),
    GAUGE("circle", sourceOwner = "Assets.xcassets/DSHGauge.imageset/DSHGauge.svg"),
    PEOPLE("person.2"),
    PUZZLE("puzzlepiece.extension"),
    LOCK_SHIELD("lock.shield"),
    HAND("hand.raised"),
    NETWORK("network"),
    GLOBE("globe"),
    TEXT_SIZE("textformat.size"),
    LIST("list.bullet.rectangle"),
    COMMAND("command"),
    BOLT("bolt.horizontal"),
    WAVEFORM("waveform.path.ecg"),
    INFO("info.circle"),
    DOCUMENT("doc.text"),
    NUMBER("number"),
    /** ChatPage's bold 18pt ellipsis from `ChatPage.swift:329-340`. */
    CHAT_MORE("ellipsis", sourceWeight = FontWeight.Bold),
    MENU("line.3.horizontal"),
    /** ChatPage's two-stroke HomeSpec menu artwork (`ChatPage.swift:207-211`). */
    CHAT_DRAWER("line.2.horizontal"),
    DEVICE("iphone"),
    DEVICE_RADIO("dot.radiowaves.left.and.right"),
    CHAT_BUBBLE("bubble.left"),
    TERMINAL("terminal", sourceOwner = "Assets.xcassets/DSHTerminal.imageset/DSHTerminal.svg"),
    SEND("arrow.up"),
    WARNING("exclamationmark.triangle"),
    TRASH("trash"),
    PENCIL("pencil"),
    SEARCH("circle", sourceOwner = "Assets.xcassets/DSHSearch.imageset/DSHSearch.svg"),
    SPARKLE("circle", sourceOwner = "Assets.xcassets/DSHSparkle.imageset/DSHSparkle.svg"),
    /** Permission artwork only; HomeSpec currently has `showsVoiceInput = false`. */
    MICROPHONE_PERMISSION("mic", permissionOnly = true),
}

private data class IconPath(val data: String, val filled: Boolean = false, val width: Float = 1.8f)

/** One source of truth for rendered vectors, SF Symbol provenance and caller tint. */
public object PdshIcons {
    /** Resolves a real, distinct vector path for [icon], with the requested tint embedded. */
    public fun vector(icon: PdshIcon, tint: Color): ImageVector {
        val builder = ImageVector.Builder(
            name = icon.name,
            defaultWidth = 24.dp,
            defaultHeight = 24.dp,
            viewportWidth = 24f,
            viewportHeight = 24f,
        )
        definitions.getValue(icon).forEach { part ->
            val parsed = PathParser().parsePathString(part.data).toNodes()
            builder.addPath(
                pathData = parsed,
                fill = if (part.filled) SolidColor(tint) else null,
                stroke = if (part.filled) null else SolidColor(tint),
                strokeLineWidth = part.width,
                strokeLineCap = androidx.compose.ui.graphics.StrokeCap.Round,
                strokeLineJoin = androidx.compose.ui.graphics.StrokeJoin.Round,
            )
        }
        return builder.build()
    }

    private val definitions: Map<PdshIcon, List<IconPath>> = mapOf(
        PdshIcon.NEW_CHAT to listOf(
            IconPath("M13 4H5.5C4.67 4 4 4.67 4 5.5v13c0 .83.67 1.5 1.5 1.5H18c.83 0 1.5-.67 1.5-1.5V13"),
            IconPath("M11 13l1.1-4.1L19.2 1.8a1.98 1.98 0 0 1 2.8 2.8l-7.1 7.1L11 13Z"),
        ),
        PdshIcon.CLOCK to listOf(
            IconPath("M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17Z"),
            IconPath("M12 7v5l3.5 2"),
        ),
        PdshIcon.GEAR to listOf(
            IconPath("M12 3.3 13.2 3.5 14 5.5 15.5 6.1 17.5 5.1 18.9 6.5 17.9 8.5 18.5 10 20.5 10.8 20.7 12 20.5 13.2 18.5 14 17.9 15.5 18.9 17.5 17.5 18.9 15.5 17.9 14 18.5 13.2 20.5 12 20.7 10.8 20.5 10 18.5 8.5 17.9 6.5 18.9 5.1 17.5 6.1 15.5 5.5 14 3.5 13.2 3.3 12 3.5 10.8 5.5 10 6.1 8.5 5.1 6.5 6.5 5.1 8.5 6.1 10 5.5 10.8 3.5Z"),
            IconPath("M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"),
        ),
        PdshIcon.FOLDER to listOf(IconPath("M3 6.2c0-.9.7-1.6 1.6-1.6h5l2 2.3h7.8c.9 0 1.6.7 1.6 1.6v9.3c0 .9-.7 1.6-1.6 1.6H4.6c-.9 0-1.6-.7-1.6-1.6V6.2Z")),
        PdshIcon.SESSIONS to listOf(IconPath("M5 7h14M5 12h14M5 17h9", width = 1.5f)),
        PdshIcon.ARCHIVE to listOf(IconPath("M3 4.5h18v4H3z"), IconPath("M4 8.5h16v10.8H4z"), IconPath("M9 12.5h6")),
        PdshIcon.FOLDER_PLUS to listOf(IconPath("M2.8 6.1c0-.9.7-1.6 1.6-1.6h5l2 2.3h7.9c.9 0 1.6.7 1.6 1.6v3.3H7c-.8 0-1.5.5-1.8 1.3l-2.4 6.4V6.1Z"), IconPath("M16.5 13v7M13 16.5h7")),
        PdshIcon.CHEVRON_DOWN to listOf(IconPath("M6 9 10.939335 13.939335C11.52513 14.52513 12.47487 14.52513 13.060665 13.939335L18 9", width = 1.5f)),
        PdshIcon.CHEVRON_UP to listOf(IconPath("M5 15l7-7 7 7")),
        PdshIcon.CHEVRON_RIGHT to listOf(IconPath("M9 5l7 7-7 7")),
        PdshIcon.CHEVRON_LEFT to listOf(IconPath("M15 5l-7 7 7 7")),
        // DSHClose.svg and DSHCheck.svg (viewBox 16) scaled to the 24pt registry viewport.
        PdshIcon.CLOSE to listOf(IconPath("M3.75 3.75 20.25 20.25M20.25 3.75 3.75 20.25", width = 1.5f)),
        PdshIcon.CHECK to listOf(IconPath("M3.375 12.75 8.24598 17.62095C8.857785 18.2328 9.858945 18.2016 10.43139 17.5527L20.625 6", width = 1.5f)),
        PdshIcon.COPY to listOf(
            // DSHCopy.svg rect/path scaled from viewBox16 to24.
            IconPath("M5.281125 6.110595H14.870925a3 3 0 0 1 3 3v9.5898a3 3 0 0 1-3 3h-9.5898a3 3 0 0 1-3-3v-9.5898a3 3 0 0 1 3-3Z", width = 1.5f),
            IconPath("M17.9688 2.29944C20.04 2.29944 21.7188 3.978375 21.7188 6.04944V14.142705C21.7188 15.5634 20.92815 16.79805 19.76325 17.4342V15.4947C20.0478 15.11805 20.2188 14.6511 20.2188 14.142705V6.04944C20.2188 4.806795 19.21155 3.79944 17.9688 3.79944H9.87561C9.41949 3.799515 8.99526 3.93525 8.64075 4.168575H6.63537C7.28478 3.051945 8.49084 2.29956 9.87561 2.29944H17.9688Z", filled = true),
        ),
        PdshIcon.TEXT_ALIGN_LEFT to listOf(IconPath("M3.5 5.5h17M3.5 10h12M3.5 14.5h17M3.5 19h12", width = 1.5f)),
        PdshIcon.ARROW_LEFT_RIGHT to listOf(IconPath("M3.5 12h17M7.5 8l-4 4 4 4M16.5 8l4 4-4 4", width = 1.5f)),
        // DSHThink.svg, DSHRead.svg, DSHEdit.svg and DSHCode.svg, scaled from
        // their 16pt source viewBoxes to this registry's 24pt viewport.
        PdshIcon.THINK to listOf(
            IconPath("M15.4281 8.572215C19.45095 12.594945 21.1773 17.3907 19.2843 19.28385C17.3913 21.17685 12.59559 19.45035 8.57277 15.42765C4.549995 11.404845 2.82354 6.60912 4.716615 4.716045C6.60966 2.823 11.4054 4.549455 15.4281 8.572215Z", width = 1.5f),
            IconPath("M15.4281 15.42765C11.4054 19.45035 6.60966 21.17685 4.716615 19.28385C2.82354 17.3907 4.549995 12.594945 8.57277 8.572215C12.59559 4.549455 17.3913 2.823 19.2843 4.716045C21.1773 6.60912 19.45095 11.404845 15.4281 15.42765Z", width = 1.5f),
            IconPath("M13.294365 12.0003C13.294365 12.713235 12.71643 13.291305 12.00336 13.291305C11.29041 13.291305 10.7124 12.713235 10.7124 12.0003C10.7124 11.287275 11.29041 10.709295 12.00336 10.709295C12.71643 10.709295 13.294365 11.287275 13.294365 12.0003Z", filled = true),
        ),
        PdshIcon.READ to listOf(
            IconPath("M7.40625 8.854425H16.59375", width = 1.5f),
            IconPath("M7.40625 13.544865H12.417615", width = 1.5f),
            IconPath("M18.75 1.989255C19.95585 1.989255 21 2.927565 21 4.164555V19.8369C20.9994 21.07335 19.9554 22.0107 18.75 22.0107H5.25C4.044555 22.0107 3.00063 21.07335 3 19.8369V4.164555C3 2.927565 4.044195 1.989255 5.25 1.989255H18.75ZM5.25 3.489255C4.79895 3.489255 4.5 3.82779 4.5 4.164555V19.8369C4.50066 20.17335 4.799445 20.5107 5.25 20.5107H18.75C19.2006 20.5107 19.4994 20.17335 19.5 19.8369V4.164555C19.5 3.82779 19.20105 3.489255 18.75 3.489255H5.25Z", filled = true),
        ),
        PdshIcon.EDIT to listOf(
            IconPath("M13.28394 4.049565H6.299565C5.057115 4.049565 4.04988 5.05719 4.049565 6.299565V17.70045C4.04988 18.94275 5.057115 19.95045 6.299565 19.95045H17.70045C18.94245 19.94985 19.95015 18.94245 19.95045 17.70045V11.848395H21.45045V17.70045C21.45015 19.7709 19.7709 21.44985 17.70045 21.45045H6.299565C4.228695 21.45045 2.54988 19.7712 2.549565 17.70045V6.299565C2.54988 4.22877 4.228695 2.549565 6.299565 2.549565H13.28394V4.049565Z", filled = true),
            IconPath("M11.67735 12.35817 20.832 3.20361", width = 1.5f),
        ),
        PdshIcon.CODE to listOf(
            IconPath("M9.41418 2.25 6.78918 21.75", width = 1.5f),
            IconPath("M17.21085 2.25 14.58582 21.75", width = 1.5f),
            IconPath("M3.59802 8.25H21.10215", width = 1.5f),
            IconPath("M2.89782 15.75H20.40195", width = 1.5f),
        ),
        PdshIcon.SEARCH to listOf(
            IconPath("M9.880905 17.7879C14.325915 17.7879 17.92935 14.184555 17.92935 9.73956C17.92935 5.29455 14.325915 1.69116 9.880905 1.69116C5.43591 1.69116 1.83252 5.29455 1.83252 9.73956C1.83252 14.184555 5.43591 17.7879 9.880905 17.7879Z", width = 1.5f),
            IconPath("M15.44865 15.58995 22.16745 22.30875", width = 1.5f),
        ),
        PdshIcon.TERMINAL to listOf(
            IconPath("M4.5 6 10.5 12 4.5 18", width = 1.5f),
            IconPath("M13.5 18H19.5", width = 1.5f),
        ),
        PdshIcon.SPARKLE to listOf(
            IconPath("M8.8125 4.5C8.8125 9.499995 11.312505 12 16.3125 12C11.312505 12 8.8125 14.500005 8.8125 19.5C8.8125 14.500005 6.312495 12 1.3125 12C6.312495 12 8.8125 9.499995 8.8125 4.5Z", width = 1.5f),
            IconPath("M18.5625 2.337345C18.5625 5.08734 19.93755 6.462345 22.6875 6.462345C19.93755 6.462345 18.5625 7.837335 18.5625 10.587345C18.5625 7.837335 17.18745 6.462345 14.4375 6.462345C17.18745 6.462345 18.5625 5.08734 18.5625 2.337345Z", width = 1.5f),
            IconPath("M18.5625 15.6627C18.5625 17.66265 19.56255 18.6627 21.5625 18.6627C19.56255 18.6627 18.5625 19.6626 18.5625 21.6627C18.5625 19.6626 17.56245 18.6627 15.5625 18.6627C17.56245 18.6627 18.5625 17.66265 18.5625 15.6627Z", width = 1.5f),
        ),
        PdshIcon.BRANCH to listOf(
            IconPath("M1.522545 12.00015L8.5446 12.00015C9.628695 12.00015 10.170735 12.00015 10.681725 11.879265C11.1348 11.77206 11.568495 11.59521 11.967315 11.355C12.417135 11.084085 12.8046 10.705035 13.579545 9.946935L16.99215 6.60846", width = 1.5f),
            IconPath("M1.518315 11.99985L8.5446 11.99985C9.628695 11.99985 10.170735 11.99985 10.681725 12.120735C11.1348 12.22794 11.568495 12.40479 11.967315 12.645C12.417135 12.915915 12.8046 13.294965 13.579545 14.053065L16.99215 17.3916", width = 1.5f),
            IconPath("M21.02973 4.96185C21.02973 6.26216578 19.97561578 7.31628 18.6753 7.31628C17.37498422 7.31628 16.32087 6.26216578 16.32087 4.96185C16.32087 3.66153422 17.37498422 2.60742 18.6753 2.60742C19.97561578 2.60742 21.02973 3.66153422 21.02973 4.96185Z", width = 1.5f),
            IconPath("M21.02973 19.03815C21.02973 20.33846578 19.97561578 21.39258 18.6753 21.39258C17.37498422 21.39258 16.32087 20.33846578 16.32087 19.03815C16.32087 17.73783422 17.37498422 16.68372 18.6753 16.68372C19.97561578 16.68372 21.02973 17.73783422 21.02973 19.03815Z", width = 1.5f),
        ),
        PdshIcon.DATABASE to listOf(
            IconPath("M19.79505 7.78035C20.5848 7.16067 21.00045 6.457755 21.00015 5.742285C21.00045 5.0268 20.5848 4.323885 19.79505 3.704205C19.0053 3.084525 17.8692 2.56992 16.5009 2.212125C15.13275 1.854315 13.580565 1.66593 12.000585 1.6659C10.420605 1.665855 8.86845 1.85418 7.500135 2.211915C6.13113 2.569515 4.99422 3.08406 4.203735 3.703785C3.41325 4.323525 2.997075 5.02659 2.997075 5.742285C2.997075 6.457965 3.41325 7.16103 4.203735 7.78077C4.99422 8.400495 6.13113 8.91504 7.500135 9.27264C8.86845 9.630375 10.420605 9.8187 12.000585 9.81867C13.580565 9.818625 15.13275 9.63024 16.5009 9.272445C17.8692 8.914635 19.0053 8.40003 19.79505 7.78035Z", width = 1.5f),
            IconPath("M3 5.705565V17.6772M21 5.705565V17.6772", width = 1.5f),
            IconPath("M3 17.67705C3 18.91215 3.94821 20.09655 5.63604 20.97C7.32387 21.8433 9.61305 22.33395 12 22.33395C14.38695 22.33395 16.6761 21.8433 18.3639 20.97C20.05185 20.09655 21 18.91215 21 17.67705", width = 1.5f),
        ),
        PdshIcon.GAUGE to listOf(
            IconPath("M5.10615 19.644C3.74271 18.2805 2.81421 16.5432 2.438055 14.65197C2.061885 12.76074 2.254965 10.80042 2.992875 9.018915C3.730785 7.23741 4.980375 5.714715 6.58365 4.643355C8.186925 3.57201 10.07187 3.00012 12.00015 3C13.928445 3.00012 15.81345 3.57201 17.41665 4.643355C19.02 5.714715 20.2695 7.23741 21.0075 9.018915C21.74535 10.80042 21.9384 12.76074 21.5622 14.65197C21.18615 16.5432 20.25765 18.2805 18.89415 19.644", width = 1.5f),
            IconPath("M12 12.74991 17.4171 7.332825", width = 1.5f),
            IconPath("M12 14.625C13.03554 14.625 13.875 13.78554 13.875 12.75C13.875 11.71446 13.03554 10.875 12 10.875C10.96446 10.875 10.125 11.71446 10.125 12.75C10.125 13.78554 10.96446 14.625 12 14.625Z", filled = true),
        ),
        PdshIcon.PLUS to listOf(IconPath("M12 5v14M5 12h14")),
        PdshIcon.MORE to listOf(IconPath("M5 12a1 1 0 1 0 0-.01M12 12a1 1 0 1 0 0-.01M19 12a1 1 0 1 0 0-.01", filled = true)),
        PdshIcon.REFRESH to listOf(IconPath("M20 11a8 8 0 0 0-14-5L4 8"), IconPath("M4 4v4h4"), IconPath("M4 13a8 8 0 0 0 14 5l2-2"), IconPath("M20 20v-4h-4")),
        PdshIcon.CPU to listOf(IconPath("M7 7h10v10H7z"), IconPath("M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3")),
        PdshIcon.PEOPLE to listOf(IconPath("M9 11a3.2 3.2 0 1 0 0-6.4A3.2 3.2 0 0 0 9 11ZM16.5 10a2.6 2.6 0 1 0 0-5.2"), IconPath("M2.8 19c.3-3.2 2.4-5.1 6.2-5.1s5.9 1.9 6.2 5.1M15 14.2c3.2-.1 5.2 1.5 5.8 4.2")),
        PdshIcon.PUZZLE to listOf(IconPath("M9 3.5h2a2.5 2.5 0 1 1 5 0h2.5v5a2.5 2.5 0 1 1 0 5v7H13v-2a2.5 2.5 0 1 0-5 0v2H4v-6.5h2a2.5 2.5 0 1 0 0-5H4v-5h5v-2Z")),
        PdshIcon.LOCK_SHIELD to listOf(IconPath("M12 2.8 20 6v5.5c0 4.8-3.2 8.1-8 10-4.8-1.9-8-5.2-8-10V6l8-3.2Z"), IconPath("M8.5 10V8.5a3.5 3.5 0 0 1 7 0V10M8 10h8v5H8z")),
        PdshIcon.HAND to listOf(IconPath("M7.5 11V6.2a1.5 1.5 0 0 1 3 0V10 5.2a1.5 1.5 0 0 1 3 0V10 6.3a1.5 1.5 0 0 1 3 0v5.1l.6-1a1.5 1.5 0 0 1 2.6 1.5l-3.1 5.3a4 4 0 0 1-3.4 1.9h-2.1a5 5 0 0 1-3.8-1.8L5 14.5a1.8 1.8 0 0 1 2.5-2.6l2 1.8")),
        PdshIcon.NETWORK to listOf(IconPath("M12 12 5 6M12 12l7-6M12 12l-1 8M5 6l2-2M5 6l-2 2M19 6l2-2M19 6l2 2"), IconPath("M14.5 12a2.5 2.5 0 1 1-5 0 2.5 2.5 0 0 1 5 0ZM7 5a2 2 0 1 1-4 0 2 2 0 0 1 4 0ZM21 5a2 2 0 1 1-4 0 2 2 0 0 1 4 0ZM13 20a2 2 0 1 1-4 0 2 2 0 0 1 4 0Z")),
        PdshIcon.GLOBE to listOf(IconPath("M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18ZM3.5 12h17M12 3c2.2 2.4 3.2 5.4 3.2 9S14.2 18.6 12 21M12 3c-2.2 2.4-3.2 5.4-3.2 9S9.8 18.6 12 21")),
        PdshIcon.TEXT_SIZE to listOf(IconPath("M3.5 7V4.5h12V7M9.5 4.5V19M5.5 19h8M16 11h5M18.5 11v8M16.5 19h4")),
        PdshIcon.LIST to listOf(IconPath("M8 5h12M8 9h12M8 13h12M8 17h12M3.5 5h.1M3.5 9h.1M3.5 13h.1M3.5 17h.1")),
        PdshIcon.COMMAND to listOf(IconPath("M8 8V5.5a2.5 2.5 0 1 0-2.5 2.5H8Zm0 0h8m0 0V5.5A2.5 2.5 0 1 1 18.5 8H16Zm0 0v8m0 0h2.5a2.5 2.5 0 1 1-2.5 2.5V16Zm0 0H8m0 0v2.5A2.5 2.5 0 1 1 5.5 16H8Zm0 0V8")),
        PdshIcon.BOLT to listOf(IconPath("M21.2 13.5 11 5.7v5.5l-8.2-.7L13 18.3v-5.5l8.2.7Z", filled = true)),
        PdshIcon.WAVEFORM to listOf(IconPath("M2.5 12H7l2-6 4 12 2-6h6.5")),
        PdshIcon.INFO to listOf(IconPath("M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18Z"), IconPath("M12 11v5M12 7.5h.01")),
        PdshIcon.DOCUMENT to listOf(IconPath("M6 3.5h8l4 4V20H6zM14 3.5V8h4M9 12h6M9 15h6M9 18h4")),
        PdshIcon.NUMBER to listOf(IconPath("M8 4 6 20M18 4l-2 16M4 9h16M3 15h16")),
        PdshIcon.CHAT_MORE to listOf(
            IconPath("M7 12a2 2 0 1 1-4 0 2 2 0 0 1 4 0M14 12a2 2 0 1 1-4 0 2 2 0 0 1 4 0M21 12a2 2 0 1 1-4 0 2 2 0 0 1 4 0", filled = true),
        ),
        PdshIcon.MENU to listOf(IconPath("M4 6h16M4 12h16M4 18h16")),
        PdshIcon.CHAT_DRAWER to listOf(
            IconPath("M3 8h18M3 16h12", width = 2.4f),
        ),
        PdshIcon.DEVICE to listOf(IconPath("M7 2.8h10c1 0 1.8.8 1.8 1.8v14.8c0 1-.8 1.8-1.8 1.8H7c-1 0-1.8-.8-1.8-1.8V4.6c0-1 .8-1.8 1.8-1.8ZM10 5.5h4M10.5 18h3")),
        PdshIcon.DEVICE_RADIO to listOf(IconPath("M12 13v.1M8.5 9.5a5 5 0 0 0 0 7M15.5 9.5a5 5 0 0 1 0 7M5.5 6.5a9.2 9.2 0 0 0 0 13M18.5 6.5a9.2 9.2 0 0 1 0 13")),
        PdshIcon.CHAT_BUBBLE to listOf(IconPath("M4 5.5c0-1.1.9-2 2-2h12c1.1 0 2 .9 2 2v9c0 1.1-.9 2-2 2h-8l-5 4v-4.2c-.6-.4-1-1-1-1.8v-9Z")),
        PdshIcon.SEND to listOf(IconPath("M12 19V5M6.5 10.5 12 5l5.5 5.5")),
        PdshIcon.WARNING to listOf(IconPath("M10.3 4.2 2.8 17.5c-.6 1 .1 2.2 1.3 2.2h15.8c1.2 0 1.9-1.2 1.3-2.2L13.7 4.2a2 2 0 0 0-3.4 0Z"), IconPath("M12 9v4M12 16.5h.01")),
        PdshIcon.TRASH to listOf(IconPath("M4 6.5h16M9 6.5V4h6v2.5M6.5 6.5l1 14h9l1-14M10 10v7M14 10v7")),
        PdshIcon.PENCIL to listOf(IconPath("M4 16.5V20h3.5L19 8.5 15.5 5 4 16.5ZM13.8 6.7l3.5 3.5")),
        PdshIcon.MICROPHONE_PERMISSION to listOf(IconPath("M12 3.2a3 3 0 0 0-3 3v6.2a3 3 0 0 0 6 0V6.2a3 3 0 0 0-3-3ZM6.5 11.5a5.5 5.5 0 0 0 11 0M12 17v4M8.5 21h7")),
    )
}

/** Caller-owned size, tint and accessibility description for a registered vector icon. */
@Composable
public fun PdshIconView(
    icon: PdshIcon,
    size: Dp,
    tint: Color,
    contentDescription: String?,
    modifier: Modifier = Modifier,
) {
    val vector = remember(icon, tint) { PdshIcons.vector(icon, tint) }
    Image(
        imageVector = vector,
        contentDescription = contentDescription,
        modifier = modifier.size(size),
    )
}
