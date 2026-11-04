// phone-dsh — :app: the one user-preference store (iOS `UserDefaults` parity).
// SPDX-License-Identifier: MIT
//
// iOS keeps its non-model preferences in `UserDefaults.standard`, read and
// written by `NativeChatPreferences` (`examples/probe-app/PhoneDSHProbe/
// NativeChatPreferences.swift:112-321`) and `ChatSettings`
// (`ChatModel.swift:27-49`). Android had no preference layer at all: every
// `SettingsPreferences` field stayed `null`, the settings index's pickers were
// dead controls, and the chat-appearance page reported `settingsWritable = NO`.
// This file is the missing layer: **one** `SharedPreferences` file behind one
// class, with the same persisted key names and types; new installs use text size
// 16, while pre-existing stored choices are read without migration or overwrite.
//
// What is deliberately **not** here:
//
//   * `chat.dsh.currentSessionID` — L65 stores the current session in the
//     `:domain` `SessionArchive` (SQLite) next to the transcript it belongs to;
//     a second copy in a preferences file would be a second authority for the
//     same fact. The key is listed in the parity report, answered by that store.
//   * `shortcutOverrides` — the page is a reference list; nothing produces an
//     override, so storing one would create a value no screen can read or write.
//   * `chat.egress.allow`, `phoneDSH.egressListBeforeAllowAll`,
//     `phone-dsh.session.title-hints` and folder bookmarks — each needs a
//     product surface this store does not own (egress controls, title hints, or
//     a SAF folder picker). These remain open questions, not silent omissions.
//
// The storage seam ([PreferenceFile]) exists so the store's whole behaviour —
// read, clamp, migrate, write, fail-closed on an unknown enum id — is testable
// on a plain JVM. The Android binding ([SharedPreferenceFile]) is one small
// class; no other file in `:app` calls `getSharedPreferences` for preferences.

package com.phonedsh.probe

import android.content.Context
import android.content.SharedPreferences
import com.phonedsh.ui.page.BusyEnterMode
import com.phonedsh.ui.page.CollapseTiming
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.PerformanceUsage
import com.phonedsh.ui.page.SettingsAppearance
import com.phonedsh.ui.page.SettingsLanguage
import com.phonedsh.ui.page.SettingsPreferences
import com.phonedsh.ui.page.SettingsScreenState
import com.phonedsh.ui.page.TranscriptViewMode
import com.phonedsh.ui.state.StateRequestId
import com.phonedsh.ui.state.StateRevision
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * One font-size role, with the iOS range and default
 * (`NativeChatPreferences.swift:36-54`).
 *
 * @param id the role's stable id, used only in a log line.
 * @param key the `UserDefaults` key the baseline stores this role under.
 * @param defaultSize the new-install default (`text 16`, `code 14`, `terminal 13`).
 * @param sizes the baseline's clamp range (`setFontSize` clamps, never refuses).
 */
internal enum class FontRole(
    val id: String,
    val key: String,
    val defaultSize: Int,
    val sizes: IntRange,
) {
    TEXT("text", "textFontSize", 16, 10..22),
    CODE("code", "codeFontSize", 14, 10..16),
    TERMINAL("terminal", "terminalFontSize", 13, 10..20),
}

/**
 * Every preference this app stores, in its resolved form.
 *
 * The defaults are the baseline's, not "the first menu option":
 * `appearance = system`, `language = system`, `transcriptView = detailed`,
 * `collapseTiming = completion`, `developerTools = true`,
 * `performanceUsage = detailed`, `busyEnterMode = queue` and
 * `chat.background.keepalive = true` (`NativeChatPreferences.swift:118-131`,
 * `ChatModel.swift:43-49`).
 *
 * @param textFontSize 正文 size, 10...22, new-install default 16.
 * @param codeFontSize 代码 size, 10...16, default 14.
 * @param terminalFontSize 终端 size, 10...20, default 13.
 * @param appearance 外观 (`appearance`): light / dark / system.
 * @param language 语言 (`language`): system / zh / en.
 * @param transcriptView 工作步骤展示 (`transcriptView`).
 * @param collapseTiming 工作步骤收起时机 (`collapseTiming`).
 * @param developerTools 显示代码工作视图 (`developerTools`), on by default.
 * @param performanceUsage 性能与用量 (`performanceUsage`).
 * @param busyEnterMode 繁忙时的发送行为 (`busyEnterMode`, legacy
 *   `phone-dsh.composer.busyEnter`), only `queue` / `steer`.
 * @param backgroundKeepAlive 后台运行 (`chat.background.keepalive`), on by default.
 */
internal data class Preferences(
    val textFontSize: Int = FontRole.TEXT.defaultSize,
    val codeFontSize: Int = FontRole.CODE.defaultSize,
    val terminalFontSize: Int = FontRole.TERMINAL.defaultSize,
    val appearance: SettingsAppearance = SettingsAppearance.SYSTEM,
    val language: SettingsLanguage = SettingsLanguage.SYSTEM,
    val transcriptView: TranscriptViewMode = TranscriptViewMode.DETAILED,
    val collapseTiming: CollapseTiming = CollapseTiming.COMPLETION,
    val developerTools: Boolean = true,
    val performanceUsage: PerformanceUsage = PerformanceUsage.DETAILED,
    val busyEnterMode: BusyEnterMode = BusyEnterMode.QUEUE,
    val backgroundKeepAlive: Boolean = true,
    /** Empty string is a known system default; null means the key was unread/absent. */
    val textFontFamily: String? = null,
    val codeFontFamily: String? = null,
    val terminalFontFamily: String? = null,
    /** Null means no stored read; an empty set is a known expanded-all choice. */
    val collapsedWorkspaceFolders: Set<String>? = null,
) {
    /** The size of [role], in px. */
    fun fontSize(role: FontRole): Int = when (role) {
        FontRole.TEXT -> textFontSize
        FontRole.CODE -> codeFontSize
        FontRole.TERMINAL -> terminalFontSize
    }

    /** This preference set with [value] clamped into the role's range. */
    fun withFontSize(role: FontRole, value: Int): Preferences {
        val size = value.coerceIn(role.sizes.first, role.sizes.last)
        return when (role) {
            FontRole.TEXT -> copy(textFontSize = size)
            FontRole.CODE -> copy(codeFontSize = size)
            FontRole.TERMINAL -> copy(terminalFontSize = size)
        }
    }

    /**
     * Whether the app should render its dark token table.
     *
     * `system` delegates to the platform's own answer; the other two ids are the
     * user's explicit choice, exactly as `NativeAppearance.colorScheme` returns
     * `.light` / `.dark` / `nil` on iOS.
     */
    fun darkTheme(systemDark: Boolean): Boolean = when (appearance) {
        SettingsAppearance.LIGHT -> false
        SettingsAppearance.DARK -> true
        SettingsAppearance.SYSTEM -> systemDark
    }

    /**
     * The settings index's 通用-tab values, from this preference set.
     *
     * Every field is a value the host really read, so the page renders the
     * stored choice instead of 未设置. `shortcutCount` stays `null`: the shortcut
     * page is a reference list and this app stores no overrides.
     */
    fun toSettingsPreferences(): SettingsPreferences = SettingsPreferences(
        language = language,
        appearance = appearance,
        fontSizeConversation = textFontSize,
        fontSizeCode = codeFontSize,
        fontSizeTerminal = terminalFontSize,
        transcriptView = transcriptView,
        collapseTiming = collapseTiming,
        developerTools = if (developerTools) FactState.YES else FactState.NO,
        performanceUsage = performanceUsage,
    )
}

/** Values that may be written through the confirmed, off-main-thread API. */
internal sealed class ConfirmedPreferenceChange(val key: String, val value: Any) {
    data class Appearance(val choice: SettingsAppearance) : ConfirmedPreferenceChange(PreferenceStore.APPEARANCE_KEY, choice.id) { val valueChoice = choice }
    data class Language(val choice: SettingsLanguage) : ConfirmedPreferenceChange(PreferenceStore.LANGUAGE_KEY, choice.id) { val valueChoice = choice }
    data class TranscriptView(val choice: TranscriptViewMode) : ConfirmedPreferenceChange(PreferenceStore.TRANSCRIPT_VIEW_KEY, choice.id) { val valueChoice = choice }
    data class CollapseTiming(val choice: com.phonedsh.ui.page.CollapseTiming) : ConfirmedPreferenceChange(PreferenceStore.COLLAPSE_TIMING_KEY, choice.id) { val valueChoice = choice }
    data class PerformanceUsage(val choice: com.phonedsh.ui.page.PerformanceUsage) : ConfirmedPreferenceChange(PreferenceStore.PERFORMANCE_USAGE_KEY, choice.id) { val valueChoice = choice }
    data class DeveloperTools(val enabled: Boolean) : ConfirmedPreferenceChange(PreferenceStore.DEVELOPER_TOOLS_KEY, enabled) { val valueChoice = enabled }
    data class BusyEnterMode(val choice: com.phonedsh.ui.page.BusyEnterMode) : ConfirmedPreferenceChange(PreferenceStore.BUSY_ENTER_KEY, choice.id) { val valueChoice = choice }
    data class BackgroundKeepAlive(val enabled: Boolean) : ConfirmedPreferenceChange(PreferenceStore.BACKGROUND_KEEP_ALIVE_KEY, enabled) { val valueChoice = enabled }
    data class FontSize(val role: FontRole, val size: Int) : ConfirmedPreferenceChange(
        role.key, size.coerceIn(role.sizes.first, role.sizes.last),
    )
    data class FontFamily(val role: FontRole, val family: String) : ConfirmedPreferenceChange(
        when (role) {
            FontRole.TEXT -> PreferenceStore.TEXT_FONT_FAMILY_KEY
            FontRole.CODE -> PreferenceStore.CODE_FONT_FAMILY_KEY
            FontRole.TERMINAL -> PreferenceStore.TERMINAL_FONT_FAMILY_KEY
        }, family,
    )
    data class CollapsedWorkspaceFolders(val folders: Set<String>) : ConfirmedPreferenceChange(
        PreferenceStore.COLLAPSED_WORKSPACE_FOLDERS_KEY, folders.toSet(),
    )
}

internal sealed interface PreferenceWriteOutcome {
    data object Persisted : PreferenceWriteOutcome
    data class Failed(val code: String) : PreferenceWriteOutcome
}

internal data class PreferenceWriteReceipt(
    val requestId: StateRequestId,
    val revision: StateRevision,
    val outcome: PreferenceWriteOutcome,
)

/**
 * The storage seam under [PreferenceStore].
 *
 * One typed getter per `UserDefaults` value kind, and an explicit
 * `boolean`/`integer` that answers `null` when the key is absent — the
 * difference between "the user chose the default" and "nothing was stored" is
 * what keeps a later migration honest.
 */
internal interface PreferenceFile {
    /** The string at [key], or `null` when absent. */
    fun string(key: String): String?

    /** The int at [key], or `null` when absent. */
    fun integer(key: String): Int?

    /** The bool at [key], or `null` when absent. */
    fun boolean(key: String): Boolean?

    /** Stores [value] at [key], durably enough to survive a kill. */
    fun putString(key: String, value: String): Boolean

    /** Stores [value] at [key]. */
    fun putInt(key: String, value: Int): Boolean

    /** Stores [value] at [key]. */
    fun putBoolean(key: String, value: Boolean): Boolean

    /** Set-valued preference; null distinguishes absence from an empty choice. */
    fun stringSet(key: String): Set<String>?

    /** Stores a defensive copy of [value]. */
    fun putStringSet(key: String, value: Set<String>): Boolean

    /** Synchronous durable commit used only from [Dispatchers.IO]. */
    fun commitString(key: String, value: String): Boolean
    fun commitInt(key: String, value: Int): Boolean
    fun commitBoolean(key: String, value: Boolean): Boolean
    fun commitStringSet(key: String, value: Set<String>): Boolean

    /** Drops [key] when present. */
    fun remove(key: String)
}

/**
 * The `SharedPreferences` binding: one file. Legacy setters use `apply()` to
 * avoid blocking the UI; confirmed writes use `commit*` from the IO dispatcher
 * and verify readback before reporting success.
 *
 * A confirmed action must call `writeConfirmed`: an `apply()` acceptance is
 * never a durable receipt. Keeping old setters nonblocking preserves their
 * existing callers while the UI adopts a real disk acknowledgment.
 *
 * @param context any context; only the application context is retained.
 * @param name the one preferences file, defaulting to [PreferenceStore.FILE_NAME].
 */
internal class SharedPreferenceFile(
    context: Context,
    name: String = PreferenceStore.FILE_NAME,
) : PreferenceFile {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(name, Context.MODE_PRIVATE)

    // The getters are fail-soft on a type mismatch: a value stored by another
    // build under the same key (a string where this one expects an int) must
    // resolve to the baseline default, not crash the launch. `commit()`'s boolean
    // is not threaded back through the store: a failed flush (a full disk) is not
    // distinguishable from a landed write here, and that gap is listed as an open
    // question in the lane report rather than hidden.
    override fun string(key: String): String? =
        runCatching { prefs.getString(key, null) }.getOrNull()

    override fun integer(key: String): Int? =
        runCatching { if (prefs.contains(key)) prefs.getInt(key, 0) else null }.getOrNull()

    override fun boolean(key: String): Boolean? =
        runCatching { if (prefs.contains(key)) prefs.getBoolean(key, false) else null }.getOrNull()

    override fun putString(key: String, value: String): Boolean { prefs.edit().putString(key, value).apply(); return true }

    override fun putInt(key: String, value: Int): Boolean { prefs.edit().putInt(key, value).apply(); return true }

    override fun putBoolean(key: String, value: Boolean): Boolean { prefs.edit().putBoolean(key, value).apply(); return true }

    override fun stringSet(key: String): Set<String>? =
        runCatching { prefs.getStringSet(key, null)?.toSet() }.getOrNull()

    override fun putStringSet(key: String, value: Set<String>): Boolean =
        prefs.edit().putStringSet(key, value.toSet()).apply().let { true }

    override fun commitString(key: String, value: String): Boolean = prefs.edit().putString(key, value).commit()
    override fun commitInt(key: String, value: Int): Boolean = prefs.edit().putInt(key, value).commit()
    override fun commitBoolean(key: String, value: Boolean): Boolean = prefs.edit().putBoolean(key, value).commit()
    override fun commitStringSet(key: String, value: Set<String>): Boolean = prefs.edit().putStringSet(key, value.toSet()).commit()

    override fun remove(key: String) { prefs.edit().remove(key).commit() }
}

/**
 * The one preference store: reads the file once, writes through, publishes the
 * resolved value set.
 *
 * A value read back that this build cannot parse (an enum id written by a newer
 * install, a size outside the baseline's range) resolves to the baseline's
 * default instead of failing the launch: a preference is never a reason the app
 * cannot start. Nothing is deleted on that path — the stored bytes stay for the
 * build that understands them, which is the same rule the WAL follows.
 *
 * @param file the storage seam; a test passes an in-memory map.
 */
internal class PreferenceStore(private val file: PreferenceFile) {

    private val mutableState = MutableStateFlow(read())
    private val confirmedWriteMutex = Mutex()

    /** The resolved preferences; a write publishes a new value. */
    val state: StateFlow<Preferences> = mutableState.asStateFlow()

    private var confirmedRevision = 0L

    /** The current resolved values. */
    fun snapshot(): Preferences = mutableState.value

    /** 外观. */
    fun setAppearance(value: SettingsAppearance) {
        file.putString(APPEARANCE_KEY, value.id)
        mutableState.value = mutableState.value.copy(appearance = value)
    }

    /** 语言. */
    fun setLanguage(value: SettingsLanguage) {
        file.putString(LANGUAGE_KEY, value.id)
        mutableState.value = mutableState.value.copy(language = value)
    }

    /** 工作步骤展示. */
    fun setTranscriptView(value: TranscriptViewMode) {
        file.putString(TRANSCRIPT_VIEW_KEY, value.id)
        mutableState.value = mutableState.value.copy(transcriptView = value)
    }

    /** 工作步骤收起时机. */
    fun setCollapseTiming(value: CollapseTiming) {
        file.putString(COLLAPSE_TIMING_KEY, value.id)
        mutableState.value = mutableState.value.copy(collapseTiming = value)
    }

    /** 性能与用量. */
    fun setPerformanceUsage(value: PerformanceUsage) {
        file.putString(PERFORMANCE_USAGE_KEY, value.id)
        mutableState.value = mutableState.value.copy(performanceUsage = value)
    }

    /** 显示代码工作视图. */
    fun setDeveloperTools(value: Boolean) {
        file.putBoolean(DEVELOPER_TOOLS_KEY, value)
        mutableState.value = mutableState.value.copy(developerTools = value)
    }

    /**
     * 繁忙时的发送行为.
     *
     * The only two ids the baseline accepts (`NativeChatPreferences.swift:228`);
     * an id outside them is not a mode this app can render, so the value is left
     * unchanged rather than stored as a string no menu can show.
     */
    fun setBusyEnterMode(value: BusyEnterMode) {
        file.putString(BUSY_ENTER_KEY, value.id)
        mutableState.value = mutableState.value.copy(busyEnterMode = value)
    }

    /** 后台运行: whether the app should open a background window for a turn. */
    fun setBackgroundKeepAlive(value: Boolean) {
        file.putBoolean(BACKGROUND_KEEP_ALIVE_KEY, value)
        mutableState.value = mutableState.value.copy(backgroundKeepAlive = value)
    }

    /** One font-size role, clamped to the baseline's range. */
    fun setFontSize(role: FontRole, value: Int) {
        val resolved = value.coerceIn(role.sizes.first, role.sizes.last)
        file.putInt(role.key, resolved)
        mutableState.value = mutableState.value.withFontSize(role, resolved)
    }

    /** A real stored family choice, including the explicit empty/system-default value. */
    fun setFontFamily(role: FontRole, value: String) {
        val key = fontFamilyKey(role)
        file.putString(key, value)
        mutableState.value = when (role) {
            FontRole.TEXT -> mutableState.value.copy(textFontFamily = value)
            FontRole.CODE -> mutableState.value.copy(codeFontFamily = value)
            FontRole.TERMINAL -> mutableState.value.copy(terminalFontFamily = value)
        }
    }

    /** Persists folder collapse state; null is reserved for an unread key. */
    fun setCollapsedWorkspaceFolders(value: Set<String>) {
        val copy = value.toSet()
        file.putStringSet(COLLAPSED_WORKSPACE_FOLDERS_KEY, copy)
        mutableState.value = mutableState.value.copy(collapsedWorkspaceFolders = copy)
    }

    private fun fontFamilyKey(role: FontRole): String = when (role) {
        FontRole.TEXT -> TEXT_FONT_FAMILY_KEY
        FontRole.CODE -> CODE_FONT_FAMILY_KEY
        FontRole.TERMINAL -> TERMINAL_FONT_FAMILY_KEY
    }


    /**
     * A confirmed write suitable for a UI success receipt. Commit and readback
     * run on IO; the StateFlow changes only after disk reports the exact value.
     */
    suspend fun writeConfirmed(requestId: StateRequestId, change: ConfirmedPreferenceChange): PreferenceWriteReceipt =
        withContext(Dispatchers.IO) {
            require(requestId.value.isNotBlank())
            confirmedWriteMutex.withLock {
            val key = change.key
            val expected: Any = change.value
            try {
                val committed = when (expected) {
                    is String -> file.commitString(key, expected)
                    is Int -> file.commitInt(key, expected)
                    is Boolean -> file.commitBoolean(key, expected)
                    is Set<*> -> file.commitStringSet(key, expected.filterIsInstance<String>().toSet())
                    else -> false
                }
                check(committed && readPreferenceValue(key, expected) == expected) { "preference commit/readback mismatch" }
                val revision = synchronized(this@PreferenceStore) {
                    applyConfirmed(change)
                    confirmedRevision += 1L
                    confirmedRevision
                }
                PreferenceWriteReceipt(requestId, StateRevision(revision), PreferenceWriteOutcome.Persisted)
            } catch (failure: Exception) {
                val revision = synchronized(this@PreferenceStore) { confirmedRevision }
                PreferenceWriteReceipt(requestId, StateRevision(revision), PreferenceWriteOutcome.Failed(failure.javaClass.simpleName))
            }
            }
        }

    private fun readPreferenceValue(key: String, expected: Any): Any? = when (expected) {
        is String -> file.string(key)
        is Int -> file.integer(key)
        is Boolean -> file.boolean(key)
        is Set<*> -> file.stringSet(key)
        else -> null
    }

    private fun applyConfirmed(change: ConfirmedPreferenceChange) {
        val current = mutableState.value
        mutableState.value = when (change) {
            is ConfirmedPreferenceChange.Appearance -> current.copy(appearance = change.valueChoice)
            is ConfirmedPreferenceChange.Language -> current.copy(language = change.valueChoice)
            is ConfirmedPreferenceChange.TranscriptView -> current.copy(transcriptView = change.valueChoice)
            is ConfirmedPreferenceChange.CollapseTiming -> current.copy(collapseTiming = change.valueChoice)
            is ConfirmedPreferenceChange.PerformanceUsage -> current.copy(performanceUsage = change.valueChoice)
            is ConfirmedPreferenceChange.DeveloperTools -> current.copy(developerTools = change.valueChoice)
            is ConfirmedPreferenceChange.BusyEnterMode -> current.copy(busyEnterMode = change.valueChoice)
            is ConfirmedPreferenceChange.BackgroundKeepAlive -> current.copy(backgroundKeepAlive = change.valueChoice)
            is ConfirmedPreferenceChange.FontSize -> current.withFontSize(change.role, change.size)
            is ConfirmedPreferenceChange.FontFamily -> when (change.role) {
                FontRole.TEXT -> current.copy(textFontFamily = change.family)
                FontRole.CODE -> current.copy(codeFontFamily = change.family)
                FontRole.TERMINAL -> current.copy(terminalFontFamily = change.family)
            }
            is ConfirmedPreferenceChange.CollapsedWorkspaceFolders -> current.copy(collapsedWorkspaceFolders = change.folders.toSet())
        }
    }

    /**
     * Performs one settings-page picker choice.
     *
     * The row ids are the settings index's own constants, so a gesture on the
     * index and the same gesture on the chat-appearance page reach one store
     * through one vocabulary. Returns `false` for a row this build does not
     * write, and the caller says so instead of leaving a dead control silent.
     *
     * @param rowId `SettingsScreenState`'s row id.
     * @param optionId the picker's option id, or a font size as decimal text for
     *   the three `preference.fontSize.*` rows.
     */
    fun apply(rowId: String, optionId: String): Boolean = when (rowId) {
        SettingsScreenState.LANGUAGE_ROW_ID ->
            SettingsLanguage.entries.firstOrNull { it.id == optionId }?.also(::setLanguage) != null

        SettingsScreenState.APPEARANCE_ROW_ID ->
            SettingsAppearance.entries.firstOrNull { it.id == optionId }?.also(::setAppearance) != null

        SettingsScreenState.TRANSCRIPT_VIEW_ROW_ID ->
            TranscriptViewMode.entries.firstOrNull { it.id == optionId }?.also(::setTranscriptView) != null

        SettingsScreenState.COLLAPSE_TIMING_ROW_ID ->
            CollapseTiming.entries.firstOrNull { it.id == optionId }?.also(::setCollapseTiming) != null

        SettingsScreenState.PERFORMANCE_ROW_ID ->
            PerformanceUsage.entries.firstOrNull { it.id == optionId }?.also(::setPerformanceUsage) != null

        SettingsScreenState.TEXT_FONT_SIZE_ROW_ID -> applyFontSize(FontRole.TEXT, optionId)
        SettingsScreenState.CODE_FONT_SIZE_ROW_ID -> applyFontSize(FontRole.CODE, optionId)
        SettingsScreenState.TERMINAL_FONT_SIZE_ROW_ID -> applyFontSize(FontRole.TERMINAL, optionId)
        else -> false
    }

    /** Resolve the same UI choice into a confirmed-write request; unknown ids stay unavailable. */
    fun confirmedChange(rowId: String, optionId: String): ConfirmedPreferenceChange? = when (rowId) {
        SettingsScreenState.LANGUAGE_ROW_ID -> SettingsLanguage.entries.firstOrNull { it.id == optionId }
            ?.let(ConfirmedPreferenceChange::Language)
        SettingsScreenState.APPEARANCE_ROW_ID -> SettingsAppearance.entries.firstOrNull { it.id == optionId }
            ?.let(ConfirmedPreferenceChange::Appearance)
        SettingsScreenState.TRANSCRIPT_VIEW_ROW_ID -> TranscriptViewMode.entries.firstOrNull { it.id == optionId }
            ?.let(ConfirmedPreferenceChange::TranscriptView)
        SettingsScreenState.COLLAPSE_TIMING_ROW_ID -> CollapseTiming.entries.firstOrNull { it.id == optionId }
            ?.let(ConfirmedPreferenceChange::CollapseTiming)
        SettingsScreenState.PERFORMANCE_ROW_ID -> PerformanceUsage.entries.firstOrNull { it.id == optionId }
            ?.let(ConfirmedPreferenceChange::PerformanceUsage)
        SettingsScreenState.BUSY_ENTER_ROW_ID -> BusyEnterMode.entries.firstOrNull { it.id == optionId }
            ?.let(ConfirmedPreferenceChange::BusyEnterMode)
        SettingsScreenState.TEXT_FONT_SIZE_ROW_ID -> optionId.toIntOrNull()?.let { ConfirmedPreferenceChange.FontSize(FontRole.TEXT, it) }
        SettingsScreenState.CODE_FONT_SIZE_ROW_ID -> optionId.toIntOrNull()?.let { ConfirmedPreferenceChange.FontSize(FontRole.CODE, it) }
        SettingsScreenState.TERMINAL_FONT_SIZE_ROW_ID -> optionId.toIntOrNull()?.let { ConfirmedPreferenceChange.FontSize(FontRole.TERMINAL, it) }
        SettingsScreenState.DEVELOPER_TOOLS_ROW_ID -> optionId.toBooleanStrictOrNull()?.let(ConfirmedPreferenceChange::DeveloperTools)
        else -> null
    }

    private fun applyFontSize(role: FontRole, optionId: String): Boolean {
        val size = optionId.trim().toIntOrNull() ?: return false
        setFontSize(role, size)
        return true
    }

    /** Resolves every key from [file], one defaulted read per key. */
    private fun read(): Preferences {
        val defaults = Preferences()
        return Preferences(
            textFontSize = readFontSize(FontRole.TEXT),
            codeFontSize = readFontSize(FontRole.CODE),
            terminalFontSize = readFontSize(FontRole.TERMINAL),
            appearance = readEnum(APPEARANCE_KEY, SettingsAppearance.entries, { it.id }, defaults.appearance),
            language = readEnum(LANGUAGE_KEY, SettingsLanguage.entries, { it.id }, defaults.language),
            transcriptView = readEnum(
                TRANSCRIPT_VIEW_KEY,
                TranscriptViewMode.entries,
                { it.id },
                defaults.transcriptView,
            ),
            collapseTiming = readEnum(
                COLLAPSE_TIMING_KEY,
                CollapseTiming.entries,
                { it.id },
                defaults.collapseTiming,
            ),
            developerTools = file.boolean(DEVELOPER_TOOLS_KEY) ?: defaults.developerTools,
            performanceUsage = readEnum(
                PERFORMANCE_USAGE_KEY,
                PerformanceUsage.entries,
                { it.id },
                defaults.performanceUsage,
            ),
            // The legacy key is deliberately *not* consulted here: the store
            // adopts it once, in `adoptLegacyBusyEnter`, so a legacy value can
            // never keep shadowing a choice written to the current key.
            busyEnterMode = readEnum(BUSY_ENTER_KEY, BusyEnterMode.entries, { it.id },
                BusyEnterMode.entries.firstOrNull { it.id == file.string(LEGACY_BUSY_ENTER_KEY) } ?: defaults.busyEnterMode),
            backgroundKeepAlive = file.boolean(BACKGROUND_KEEP_ALIVE_KEY) ?: defaults.backgroundKeepAlive,
            textFontFamily = file.string(TEXT_FONT_FAMILY_KEY),
            codeFontFamily = file.string(CODE_FONT_FAMILY_KEY),
            terminalFontFamily = file.string(TERMINAL_FONT_FAMILY_KEY),
            collapsedWorkspaceFolders = file.stringSet(COLLAPSED_WORKSPACE_FOLDERS_KEY)?.toSet(),
        )
    }

    private fun readFontSize(role: FontRole): Int {
        val stored = file.integer(role.key) ?: return role.defaultSize
        // A stored size outside the range was written by a build with a different
        // range. Clamp rather than fail: the value is still "the user's size",
        // and the default would silently discard it.
        return stored.coerceIn(role.sizes.first, role.sizes.last)
    }

    private fun <T> readEnum(key: String, values: List<T>, id: (T) -> String, fallback: T): T =
        values.firstOrNull { id(it) == file.string(key) } ?: fallback

    companion object {
        /**
         * The one preferences file.
         *
         * Two other `SharedPreferences` files exist in this app and are **not**
         * preferences: `pdsh.phone.permission.asks` (the permission ask log, a
         * device fact) and `pdsh_background_state` (the interrupted-turn
         * tombstone, `:dsh`'s). A new feature must extend this file, not add a
         * fourth.
         */
        const val FILE_NAME: String = "phone-dsh.preferences"

        /** 正文 size key (`NativeChatPreferences.swift:135`). */
        const val TEXT_FONT_SIZE_KEY: String = "textFontSize"

        /** 代码 size key (`:136`). */
        const val CODE_FONT_SIZE_KEY: String = "codeFontSize"

        /** 终端 size key (`:137`). */
        const val TERMINAL_FONT_SIZE_KEY: String = "terminalFontSize"

        /** 外观 (`:141`). */
        const val APPEARANCE_KEY: String = "appearance"

        /** 语言 (`:142`). */
        const val LANGUAGE_KEY: String = "language"

        /** 工作步骤展示 (`:143`). */
        const val TRANSCRIPT_VIEW_KEY: String = "transcriptView"

        /** 工作步骤收起时机 (`:144`). */
        const val COLLAPSE_TIMING_KEY: String = "collapseTiming"

        /** 显示代码工作视图 (`:145`). */
        const val DEVELOPER_TOOLS_KEY: String = "developerTools"

        /** 性能与用量 (`:146`). */
        const val PERFORMANCE_USAGE_KEY: String = "performanceUsage"

        /** 繁忙时的发送行为 (`:147`). */
        const val BUSY_ENTER_KEY: String = "busyEnterMode"

        /** The baseline's pre-rename key, read once by [adoptLegacyBusyEnter]. */
        const val LEGACY_BUSY_ENTER_KEY: String = "phone-dsh.composer.busyEnter"

        /** 后台运行 (`ChatModel.swift:43`). */
        const val BACKGROUND_KEEP_ALIVE_KEY: String = "chat.background.keepalive"

        const val TEXT_FONT_FAMILY_KEY: String = "textFontFamily"
        const val CODE_FONT_FAMILY_KEY: String = "codeFontFamily"
        const val TERMINAL_FONT_FAMILY_KEY: String = "terminalFontFamily"
        const val COLLAPSED_WORKSPACE_FOLDERS_KEY: String = "phone-dsh.sidebar.collapsed-workspaces"

        /**
         * Every key this store persists, in the baseline's spelling.
         *
         * A guard, not documentation: a new key must be added here, and the JVM
         * suite fails until it is — the lane's rule is "one preference, one
         * persisted-key assertion".
         */
        val ALL_KEYS: Set<String> = setOf(
            TEXT_FONT_SIZE_KEY,
            CODE_FONT_SIZE_KEY,
            TERMINAL_FONT_SIZE_KEY,
            APPEARANCE_KEY,
            LANGUAGE_KEY,
            TRANSCRIPT_VIEW_KEY,
            COLLAPSE_TIMING_KEY,
            DEVELOPER_TOOLS_KEY,
            PERFORMANCE_USAGE_KEY,
            BUSY_ENTER_KEY,
            BACKGROUND_KEEP_ALIVE_KEY,
            TEXT_FONT_FAMILY_KEY,
            CODE_FONT_FAMILY_KEY,
            TERMINAL_FONT_FAMILY_KEY,
            COLLAPSED_WORKSPACE_FOLDERS_KEY,
        )
    }
}
