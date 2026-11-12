// The host shell: drawer, page stack, back gesture and the Web surface container.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 (the 入口 column: 抽屉「工作文件夹」、
// 设置 › 定时任务、页头 `⋯`、设置首行/设置内、页头运行状态点、引擎就绪时的默认面),
// §2 (`back-gesture` in §5: the stack pops one level per gesture) and §3.1 (a page
// is a pure function of facts and local state; nothing here reads the engine for
// a page).
//
// This file owns the three things a page library cannot own:
//
//   * the page stack ([PdshNavState]) and the system back gesture;
//   * the drawer and the page-header entries §1 names;
//   * the engine's one WebView as the Web surface's `surface` slot — the engine
//     owns the instance, this app only attaches it and never creates a second.
//
// Facts come from [ProbeEngineViewModel.navFacts]; every field the host could
// not read stays unknown inside that snapshot, so no page here shows a value the
// host did not measure. Write gestures reach [handleHostAction], which logs the
// handoff and performs only the actions this host really owns (engine stop and
// engine start).
//
// The one deliberate deviation from §1 is recorded at [HostShell]: the Web
// surface is the engine-ready default face only when the launch asks for it
// (`pdsh.face.web`), because the demo acceptance taps 跑一轮 on the native face
// after the worker is ready.
//
// Product launches land on ChatPage. The PR22 session drawer overlays that
// conversation and reads App-owned chat records; the diagnostic probe remains an
// explicit launch face (`--ez pdsh.face.probe true`).
package com.phonedsh.probe

import com.phonedsh.dsh.localexec.UbuntuApproval
import android.content.Context
import android.content.ContextWrapper
import android.util.Log
import android.view.View
import androidx.activity.compose.LocalOnBackPressedDispatcherOwner
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import androidx.compose.runtime.rememberCoroutineScope
import com.phonedsh.engine.ChannelStatus
import com.phonedsh.engine.EngineState
import com.phonedsh.engine.HandshakeSummary
import com.phonedsh.engine.KernelVerdict
import com.phonedsh.platform.EngineHostState
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.nav.BackCoordinator
import com.phonedsh.ui.nav.PdshBackLevel
import com.phonedsh.ui.nav.PdshHostAction
import com.phonedsh.ui.nav.SettingsWrite
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.nav.PdshNavHost
import com.phonedsh.ui.nav.HomeDrawer
import com.phonedsh.ui.nav.HomeDrawerFacts
import com.phonedsh.ui.nav.HomeDrawerFolder
import com.phonedsh.ui.nav.HomeDrawerSession
import com.phonedsh.ui.nav.HomeDrawerEngineState
import com.phonedsh.ui.nav.HomeDrawerArchiveResult
import com.phonedsh.ui.nav.HomeDrawerArchiveRequest
import com.phonedsh.ui.nav.rememberHomeDrawerUiState
import com.phonedsh.ui.nav.PdshNavState
import com.phonedsh.ui.nav.PdshRoute
import com.phonedsh.ui.nav.HomeTab
import com.phonedsh.ui.nav.HomeTabBar
import com.phonedsh.ui.nav.PushBackState
import com.phonedsh.ui.nav.PushOverlay
import com.phonedsh.ui.nav.selectedHomeTab
import com.phonedsh.ui.nav.confirms
import com.phonedsh.ui.sheet.SheetBackHost
import com.phonedsh.ui.theme.generated.TokenBackLayer
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.AgentPresetActions
import com.phonedsh.ui.page.PhoneCapability
import com.phonedsh.ui.page.ProviderDraft
import com.phonedsh.ui.page.ProviderKeyStatus
import com.phonedsh.ui.page.BusyEnterMode
import com.phonedsh.ui.page.SettingsScreenState
import com.phonedsh.ui.page.WorkbenchSection
import com.phonedsh.ui.page.ShellRun
import com.phonedsh.ui.page.ConnectedComputerUiState
import com.phonedsh.ui.page.PCPairingUiState
import com.phonedsh.ui.page.PcDrawerBackend
import com.phonedsh.ui.page.PcDrawerUiState
import com.phonedsh.probe.pc.PcBackend
import com.phonedsh.probe.pc.PcCameraAvailability
import com.phonedsh.probe.pc.PcQrScanner
import com.phonedsh.probe.pc.PcWorkspaceController
import com.phonedsh.probe.pc.PcWorkspaceState
import com.phonedsh.probe.pc.cancelPcPairing
import com.phonedsh.probe.pc.connectionScreenOpened
import com.phonedsh.probe.pc.finishPcPairing
import com.phonedsh.probe.pc.pairWithPcCode
import com.phonedsh.probe.pc.pairWithPcLink
import com.phonedsh.probe.pc.pairWithPcQr
import com.phonedsh.probe.pc.retryPcPairing
import com.phonedsh.probe.pc.retryPcRoster
import com.phonedsh.probe.pc.selectPcBackend
import com.phonedsh.probe.pc.startPcScan
import com.phonedsh.probe.pc.toConnectedComputerUiState
import com.phonedsh.probe.pc.toPcDrawerUiState
import com.phonedsh.probe.pc.toPcPairingUiState
import com.phonedsh.probe.pc.toPcSettingsValue
import com.phonedsh.probe.pc.unpairPc
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.PdshThemeValues
import com.phonedsh.ui.theme.UiTypePreferences
import com.phonedsh.ui.state.StateRequestId
import java.util.UUID

/** The installed app opens the real conversation; the diagnostic face is opt-in. */
internal fun initialHostNavState(probeFaceOnLaunch: Boolean): PdshNavState =
    PdshNavState(listOf(if (probeFaceOnLaunch) PdshRoute.Home else PdshRoute.Chat))

/**
 * How many pages sit above [tab]'s root in [nav].
 *
 * Each tab owns its route stack (`interaction.md` §4 rule 1), so the depth comes
 * from that tab's stack even while another tab is showing. A tab whose root is
 * not on its stack (the diagnostic [PdshRoute.Home] face) counts every route
 * above the stack floor.
 */
internal fun PdshNavState.hostPushDepth(tab: HomeTab): Int = depthOf(tab)

/**
 * Mirrors every tab's depth into the contract's push state.
 *
 * `interaction.md` §4 rule 1 needs a depth for each tab, not only the one on
 * screen: the hidden tabs keep their pages while another tab is selected, so
 * storing only the selected tab would lose them at the next switch. Zero depths
 * are omitted (they read as zero through [PushBackState.depthOf]); overlays and
 * the keyboard flag are not depth and are preserved untouched.
 */
internal fun PushBackState.mirroredTo(nav: PdshNavState, tab: HomeTab = selectedTab): PushBackState {
    val depths = HomeTab.entries.mapNotNull { candidate ->
        val depth = nav.hostPushDepth(candidate)
        if (depth == 0) null else candidate to depth
    }.toMap()
    return copy(selectedTab = tab, stackDepths = depths)
}

/**
 * The host's one navigation value: the route stack and the layered back state.
 *
 * `interaction.md` §4 makes [PushBackState] the authority for the tab bar
 * (rule 4), tab selection (rules 1-2) and layer order (rule 5), while the
 * pages are still rendered from [PdshNavState]. Keeping both halves in one
 * value is what stops the two from drifting: every transition below updates
 * both, and [applyPushState] is the only way a coordinator transition reaches
 * the route stack. A back that the coordinator reports at depth 0 leaves both
 * halves unchanged, so the platform's own exit remains in charge.
 */
internal data class HostBackChain(
    val nav: PdshNavState = productFloor,
    val pushBack: PushBackState = PushBackState(),
) {
    private companion object {
        /** The product floor; the diagnostic `Home` face is built explicitly. */
        val productFloor: PdshNavState = PdshNavState(listOf(PdshRoute.Chat))
    }

    /** True while the drawer's overlay layer is present (`interaction.md` §1 rule 9). */
    val drawerOpen: Boolean get() = PushOverlay.DRAWER in pushBack.overlays

    /** The selected tab's contract depth; the tab bar reads [PushBackState.tabBarVisible]. */
    val depth: Int get() = pushBack.depth

    /** Push one route and add one level to the selected tab's mirrored depth. */
    fun push(route: PdshRoute): HostBackChain = withNav(nav.push(route))

    /**
     * Pop one route, mirroring the depth. The page header's back arrow calls
     * this directly (there is no gesture to dispatch), so the tab bar returns
     * at the same moment the route does.
     */
    fun pop(): HostBackChain {
        if (!nav.canGoBack) return this
        return withNav(nav.pop())
    }

    /**
     * `interaction.md` §4 rules 1-2: select a tab. A re-tap of the current tab
     * returns this value, so it can never pop to root. `nav.selectHomeTab`
     * restores the target tab's own route stack (rule 1), and the mirror then
     * carries every tab's depth.
     */
    fun selectTab(tab: HomeTab): HostBackChain {
        val selected = pushBack.selectTab(tab)
        if (selected === pushBack) return this
        val next = nav.selectHomeTab(tab)
        return copy(nav = next, pushBack = selected.mirroredTo(next, tab))
    }

    /** §1 rule 9: the drawer becomes the top overlay; the page stack is untouched. */
    fun openDrawer(): HostBackChain = copy(pushBack = pushBack.openOverlay(PushOverlay.DRAWER))

    /** Close the drawer overlay only; the motion stays mounted until `onClose`. */
    fun closeDrawer(): HostBackChain = copy(pushBack = pushBack.closeOverlay(PushOverlay.DRAWER))

    /** §4 rule 4: the keyboard hides the bar without touching the stack. */
    fun withKeyboard(visible: Boolean): HostBackChain =
        copy(pushBack = pushBack.withKeyboardVisible(visible))

    /**
     * Return to a single-route floor (`Home` or `Chat`) and drop every overlay.
     * The drawer stays mounted through its close motion because [drawerOpen]
     * turns false here; the host clears `drawerMounted` only in `onClose`.
     */
    fun resetTo(route: PdshRoute, tab: HomeTab = HomeTab.TASKS): HostBackChain = copy(
        nav = PdshNavState(stacks = mapOf(tab to listOf(route)), selectedTab = tab),
        pushBack = pushBack.copy(selectedTab = tab, stackDepths = emptyMap(), overlays = emptyList()),
    )

    /**
     * Apply one [BackCoordinator] transition.
     *
     * The coordinator consumes exactly one layer (`interaction.md` §4 rule 5).
     * A stack pop must also pop the route it names; an overlay close must leave
     * the route stack alone. The depth difference is that decision, so the host
     * never repeats the layer order here.
     */
    fun applyPushState(next: PushBackState): HostBackChain {
        val pops = (pushBack.depth - next.depth).coerceAtLeast(0)
        var nextNav = nav
        repeat(pops) { nextNav = nextNav.pop() }
        // A pop that lands on a tab root names that tab; a pop that lands on a
        // pushed page keeps the tab the person selected.
        val tab = if (pops > 0) nextNav.selectedHomeTab() ?: next.selectedTab else next.selectedTab
        return copy(nav = nextNav, pushBack = next.mirroredTo(nextNav, tab))
    }

    /** Move the route stack and keep `selectedTab` on the tab root under it. */
    private fun withNav(next: PdshNavState): HostBackChain {
        val tab = next.selectedHomeTab() ?: next.selectedTab
        return copy(nav = next, pushBack = pushBack.mirroredTo(next, tab))
    }
}

private fun ShellRun.withExecEvent(event: com.phonedsh.dsh.exec.ExecEvent): ShellRun = when (event) {
    is com.phonedsh.dsh.exec.ExecEvent.Start -> copy(runningExecId = event.execId)
    is com.phonedsh.dsh.exec.ExecEvent.Output -> copy(
        output = output + String(java.util.Base64.getDecoder().decode(event.data), Charsets.UTF_8),
    )
    is com.phonedsh.dsh.exec.ExecEvent.Error -> copy(error = event.message, runningExecId = null)
    is com.phonedsh.dsh.exec.ExecEvent.Exit -> copy(
        output = output + buildString {
            append("\n[结束：")
            append(event.code?.toString() ?: "未知")
            event.signal?.let { append(", signal ").append(it) }
            if (event.status == com.phonedsh.dsh.exec.ExecEvent.ExitStatus.TIMED_OUT) append("，超时")
            if (event.status == com.phonedsh.dsh.exec.ExecEvent.ExitStatus.CANCELLED) append("，已取消")
            append("]")
        },
        runningExecId = null,
    )
    is com.phonedsh.dsh.exec.ExecEvent.Quiescent -> this
}

private fun resolvePreferenceFont(id: String?): androidx.compose.ui.text.font.FontFamily? = when (id?.lowercase()) {
    null, "", "system", "default" -> null
    "sans-serif", "sansserif" -> androidx.compose.ui.text.font.FontFamily.SansSerif
    "serif" -> androidx.compose.ui.text.font.FontFamily.Serif
    "monospace", "monospaced" -> androidx.compose.ui.text.font.FontFamily.Monospace
    "cursive" -> androidx.compose.ui.text.font.FontFamily.Cursive
    else -> null
}

/** Verified Android native client artifacts (Maven POM evidence, 2026-11-03). */
private val ANDROID_NATIVE_LICENSE_FACTS = listOf(
    com.phonedsh.ui.nav.PdshLicenseFact("kotlin-stdlib", "Kotlin standard library 2.1.0", "Apache-2.0"),
    com.phonedsh.ui.nav.PdshLicenseFact("androidx-core-ktx", "AndroidX Core KTX 1.15.0", "Apache-2.0"),
    com.phonedsh.ui.nav.PdshLicenseFact("androidx-compose-ui", "Jetpack Compose UI 1.7.6", "Apache-2.0"),
    // Native SSH/SCP (docs/native-ssh.md); versions are the catalog pins.
    com.phonedsh.ui.nav.PdshLicenseFact("jsch", "JSch (com.github.mwiede) 2.28.8", "BSD-3-Clause AND ISC"),
    com.phonedsh.ui.nav.PdshLicenseFact("bcprov", "Bouncy Castle Provider (bcprov-jdk18on) 1.86", "MIT"),
)

/**
 * The app's one screen: the navigation shell around every routed page.
 *
 * @param engine the composition root, read for facts and the WebView instance.
 * @param state the engine lifecycle state (also the runtime page's engine fact).
 * @param handshake the merged HELLO; its presence is what makes the Web surface
 *   live, because a HELLO can only come from the loaded page.
 * @param channel the channel counters (the native face renders them).
 * @param turn the one turn's state (the workbench's tool output comes from it).
 * @param recoveryNotice the fail-loud report from a previous process death, a torn
 *   WAL tail or an unreadable reclaim token; `null` when nothing is wrong.
 * @param backgroundRevision a counter the Activity bumps when the notification
 *   permission answer changes what the background facts may say. It is a fact
 *   key, not a value: the facts are still measured, this only says "measure
 *   again", because the grant happens after the first snapshot was taken.
 * @param permissionRevision the same kind of key for the phone-permissions matrix:
 *   bumped when a permission answer arrives, when the Activity resumes (a grant can
 *   change in the settings page this app sends the user to), and when a request is
 *   launched so the row can show it is in flight.
 * @param onStart start the engine.
 * @param onStop stop the engine.
 * @param onRunTurn run one turn through the App's own `/api` lane.
 * @param onPhonePermissionRequest 继续 on a capability row: raise the real system
 *   request (or, for a capability with no requestable permission, open the page that
 *   holds it).
 * @param onPhonePermissionSettings 去系统设置 on a capability row: open the system page
 *   that can change that capability's grant.
 */
@Composable
internal fun HostShell(
    engine: ProbeEngineViewModel,
    state: EngineState,
    hostState: com.phonedsh.controller.HostState,
    handshake: HandshakeSummary?,
    channel: ChannelStatus,
    turn: AppTurnState,
    recoveryNotice: RecoveryNotice?,
    backgroundRevision: Int,
    permissionRevision: Int,
    filesImportReceipt: Pair<String, com.phonedsh.ui.page.FilesImportReceipt>?,
    onSpeakText: ((String) -> Boolean)?,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onRunTurn: () -> Unit,
    onPhonePermissionRequest: (PhoneCapability) -> Unit,
    onPhonePermissionSettings: (PhoneCapability) -> Unit,
    onPickFiles: () -> Unit,
    onPickImages: () -> Unit,
    onPickWorkspaceFile: (String) -> Unit,
) {
    // The facts are one host walk per lifecycle/HELLO/turn change: a page never
    // asks the host for anything itself. `backgroundRevision` is the one key that
    // is not engine state: a permission answer lands after the first walk and must
    // not leave the runtime page showing the pre-answer verdict.
    // `settingsRevision` is the same kind of key for a write this host performed:
    // the device store changed, so the walk must run again — the facts themselves
    // still come only from reads.
    var settingsRevision by remember { mutableIntStateOf(0) }
    // The user preferences, collected so the theme and the facts follow a write.
    // The store is the view model's; this shell never reads the file itself.
    val preferences by engine.preferenceState.collectAsState()
    val permissionDefaults by engine.permissionDefaults.collectAsState()
    val configurationFacts by engine.configuration.collectAsState()
    val agentPresetFacts by engine.agentPresets.collectAsState()
    val context = LocalContext.current
    // PCLink C5: the view model owns the controller's lifetime (`onCleared`), so
    // this shell only observes its snapshot and maps it onto the plain `:lib`
    // page state. The camera prompt stays the Activity's one CAMERA request.
    val pcController = engine.pcWorkspace
    val pcStateFlow: StateFlow<PcWorkspaceState?> = remember(pcController) {
        pcController?.state ?: MutableStateFlow(null)
    }
    val pcState by pcStateFlow.collectAsState()
    val pcWiring = remember(pcController, context) {
        HostPcLinkWiring(pcController) {
            (context as? MainActivity)?.requestPcCameraPermission()
        }
    }
    val pcPairingState = pcWiring.pairingState(pcState)
    val pcConnectedState = pcWiring.connectedState(pcState)
    val pcDrawerState = pcWiring.drawerState(pcState)
    val pcConnectedValue = pcWiring.settingsValue(pcState)
    // One successful unpair ends the attempt; otherwise a later, unrelated error
    // (a roster read, a turn) would reopen 解除没有完成 on a page with no pairing.
    LaunchedEffect(pcState?.record?.machineId) {
        if (pcState?.record == null) pcWiring.onDismissUnpairFailure()
    }
    val pcScannerController = pcController
    val pcScannerContent: (@Composable () -> Unit)? =
        if (pcScannerController != null && pcPairingState.scanning &&
            pcState?.camera == PcCameraAvailability.AVAILABLE
        ) {
            {
                PcQrScannerContent(
                    controller = pcScannerController,
                    onDecoded = { payload -> pcWiring.onQrDecoded(payload) },
                    onUnavailable = { pcWiring.onCameraUnavailable() },
                )
            }
        } else {
            null
        }
    // 蓝牙设备: the process-owned scan + standard GATT store (android-standard-gatt.md).
    val bleDevices = remember { AndroidBleDevices.get(context) }
    BindBluetoothHost(bleDevices)
    val bluetoothFacts by bleDevices.facts.collectAsState()
    // SSH 主机: the process-wide saved connections (docs/native-ssh.md).
    val sshSettings = remember { SshSettingsStore.get(context) }
    val sshFacts by sshSettings.facts.collectAsState()
    // Android ADB: the process-owned native android_* tool host (native-mcp.md).
    val androidAdb = remember { AndroidAdbHost.get(context) }
    val androidAdbFacts by androidAdb.facts.collectAsState()
    // Tono 账号: the process-owned cloud account session (tono-account.md).
    val tonoAccount = remember { TonoAccountHost.get(context) }
    val tonoAccountFacts by tonoAccount.facts.collectAsState()
    // 局域网设备 on the MCP page: the user-started mDNS browse (lan-mcp.md).
    val lanDiscovery = remember { AndroidLanDiscovery.get(context) }
    val lanFacts by lanDiscovery.facts.collectAsState()
    val systemDark = isSystemInDarkTheme()
    // L69: the chat page's one state. Collected here so a Worker event rebuilds the
    // page on the next frame; the view model is its only writer.
    val chatUi by engine.chat.collectAsState()
    val sessionSnapshot by engine.sessions.collectAsState()
    // L81: the 本 session 产物 attribution. Collected so a finished turn rebuilds the
    // artifacts page with the paths it wrote; the diff itself runs on the turn's IO
    // thread, never here. It is also an `@`-menu refresh key: a turn that wrote a
    // workspace file changes no chat/session state, so the candidates would keep
    // the pre-turn listing without it.
    val artifactFacts by engine.artifactFacts.collectAsState()
    // The `@` menu's candidates are a host read, not a projection: the workspace
    // walk and the session-store read happen here, on the IO lane, and the page
    // only ever receives the bounded result. A frame never touches the disk.
    //
    // The refresh key carries every input that can change the workspace but not
    // the transcript: a 文件 page import (`filesImportReceipt`, `attachToChat =
    // false` makes no attachment), an agent turn's writes (`artifactFacts`), and
    // the trigger itself (a file can be deleted or changed while the menu is
    // closed). Re-reading on open is the bounded catch-all; typing inside the
    // token is one boolean and does not repeat the walk.
    var chatMention by remember { mutableStateOf(ChatMentionFacts()) }
    LaunchedEffect(
        chatMentionRefreshKey(
            chatId = chatUi.chatId,
            attachments = chatUi.attachments,
            notice = chatUi.notice,
            sessions = sessionSnapshot.sessions,
            archivedSessions = sessionSnapshot.archivedSessions,
            settingsRevision = settingsRevision,
            importReceipt = filesImportReceipt,
            artifactWrites = artifactFacts.writtenPaths.orEmpty(),
            referenceMenuOpen = isReferenceMenuOpen(chatUi.draft),
        ),
    ) {
        chatMention = engine.chatMentionFacts(chatUi.chatId)
    }
    val chatScreenState = engine.chatSurfaceState(chatMention.files, chatMention.sessionTitles)
    LaunchedEffect(Unit) { engine.startNativeSurface() }
    LaunchedEffect(state is EngineHostState.Running, chatUi.chatId) {
        if (state is EngineHostState.Running) engine.prepareChatSession()
    }
    val automationFacts by engine.automation.collectAsState()
    var drawerRecords by remember { mutableStateOf<List<ChatRecord>?>(null) }
    var drawerFolders by remember { mutableStateOf<List<ChatWorkspaceGroup>?>(null) }
    var drawerSnapshotFailure by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(settingsRevision, chatUi.chatId, chatUi.updatedAtMs, sessionSnapshot.sessions, sessionSnapshot.archivedSessions) {
        val loaded = withContext(Dispatchers.IO) {
            runCatching {
                val groups = engine.chatStore.loadWorkspaceGroups()
                if (groups.isEmpty()) {
                    val receipt = engine.chatStore.ensureDefaultWorkspaceGroup(
                        StateRequestId("default-folder:${UUID.randomUUID()}"),
                    )
                    check(receipt.outcome is ChatWriteOutcome.Persisted)
                }
                engine.chatStore.loadAll() to engine.chatStore.loadWorkspaceGroups()
            }
        }
        loaded.onSuccess { (records, folders) ->
            drawerRecords = records
            drawerFolders = folders
            drawerSnapshotFailure = null
        }.onFailure { failure ->
            drawerSnapshotFailure = failure.message?.substringBefore('\n')?.take(180)
                ?: "会话和文件夹列表读取失败，请重试"
        }
    }
    var providerConnectionTest by remember {
        mutableStateOf<com.phonedsh.ui.page.ProviderConnectionTestFact?>(null)
    }
    var providerSave by remember {
        mutableStateOf<com.phonedsh.ui.page.ProviderSaveFact?>(null)
    }
    var providerModels by remember {
        mutableStateOf<com.phonedsh.ui.nav.PdshProviderOperationFact?>(null)
    }
    var providerCatalog by remember {
        mutableStateOf<com.phonedsh.ui.page.ProviderCatalogFact?>(null)
    }
    var activeProviderTestRequest by remember { mutableStateOf<String?>(null) }
    var activeProviderSaveRequest by remember { mutableStateOf<String?>(null) }
    val providerProbeScope = rememberCoroutineScope()
    var notice by remember { mutableStateOf<String?>(null) }
    // The route stack and the contract's push state move as one value: the tab
    // bar, the drawer overlay and the coordinator all read the same [hostBack],
    // so a back gesture can never leave the two halves at different depths.
    var hostBack by remember {
        mutableStateOf(HostBackChain(nav = initialHostNavState(engine.probeFaceOnLaunch())))
    }
    val nav: PdshNavState = hostBack.nav

    fun pushRoute(route: PdshRoute) {
        hostBack = hostBack.push(route)
    }

    fun popRoute() {
        hostBack = hostBack.pop()
    }

    fun selectHomeTab(tab: HomeTab) {
        hostBack = hostBack.selectTab(tab)
    }

    fun resetTo(route: PdshRoute) {
        hostBack = hostBack.resetTo(route)
    }

    fun openHostDrawer() {
        hostBack = hostBack.openDrawer()
    }

    fun closeHostDrawer() {
        hostBack = hostBack.closeDrawer()
    }

    fun applyPushState(next: PushBackState) {
        hostBack = hostBack.applyPushState(next)
    }
    var shellRun by remember { mutableStateOf(ShellRun()) }
    var speechNotice by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(nav.current) {
        if (nav.current == PdshRoute.Settings || nav.current == PdshRoute.SettingsMore) {
            engine.refreshDefaultPermissionTier()?.let { notice = "新会话默认权限读取失败：$it" }
        }
        if (nav.current == PdshRoute.Configuration) {
            // The plugin page's permission block reads the same measured
            // startup-lock facts as the settings sub-page; refresh this field
            // before the configuration walk so a writable engine keeps its
            // write path and a locked one explains itself.
            engine.refreshDefaultPermissionTier()
            engine.refreshConfiguration()?.let { notice = "本会话设置部分读取失败：$it" }
        }
    }
    LaunchedEffect(state is EngineHostState.Running, chatUi.workerSessionId) {
        if (state is EngineHostState.Running) engine.refreshAutomation()
    }
    val facts: PdshNavFacts = remember(
        state,
        // The runtime page's 最近出錯 reads the D14 failure, so a host-state
        // change must rebuild the facts even when the engine and turn did not.
        hostState,
        handshake,
        turn,
        backgroundRevision,
        permissionRevision,
        settingsRevision,
        preferences,
        automationFacts,
        chatUi.chatId,
        chatUi.title,
        chatUi.workerSessionId,
        chatUi.error,
        chatUi.lastSubmission,
        chatUi.lastAttachments,
        chatUi.lastPromptRequestId,
        chatUi.pendingNodes,
        chatScreenState.pending,
        chatScreenState.rows,
        chatScreenState.queueItems,
        onSpeakText,
        shellRun,
        speechNotice,
        providerConnectionTest,
        providerSave,
        providerModels,
        providerCatalog,
        permissionDefaults,
        configurationFacts,
        sessionSnapshot,
        nav,
    ) {
        val measured = engine.navFacts(state, handshake, turn)
        val shellFacts = engine.shellSnapshot(shellRun)
        val actions = mutableMapOf<com.phonedsh.ui.nav.PdshActionKey,
            com.phonedsh.ui.nav.PdshActionAvailability<(com.phonedsh.ui.nav.PdshUiHostCommand) -> Unit>>()
        fun available(
            key: com.phonedsh.ui.nav.PdshActionKey,
            handler: (com.phonedsh.ui.nav.PdshUiHostCommand) -> Unit,
        ) {
            actions[key] = com.phonedsh.ui.nav.PdshActionAvailability.Available(handler)
        }
        available(com.phonedsh.ui.nav.PdshActionKey.FILE_IMPORT) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.FileImport) onPickFiles()
        }
        available(com.phonedsh.ui.nav.PdshActionKey.IMAGE_IMPORT) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.ImageImport) onPickImages()
        }
        available(com.phonedsh.ui.nav.PdshActionKey.SAF_IMPORT) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.SafImport) onPickWorkspaceFile(request.requestId.value)
        }
        available(com.phonedsh.ui.nav.PdshActionKey.SELECT_MODEL) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.SelectModel) engine.selectChatModel(request.model, request.effort)
        }
        available(com.phonedsh.ui.nav.PdshActionKey.SELECT_PERMISSION_MODE) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.SelectPermissionMode) engine.selectChatAccessMode(request.modeId)
        }
        available(com.phonedsh.ui.nav.PdshActionKey.ANSWER_QUESTION) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.AnswerQuestion && request.sessionId == chatUi.chatId) {
                engine.answerChatQuestion(request.pending, request.answer)
            }
        }
        available(com.phonedsh.ui.nav.PdshActionKey.DISCARD_QUESTION) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.DiscardQuestion && request.sessionId == chatUi.chatId) {
                engine.dismissChatQuestion(request.pending)
            }
        }
        if (!shellFacts.commands.isNullOrEmpty() && state is EngineHostState.Running &&
            hostState == com.phonedsh.controller.HostState.RUNNING
        ) available(com.phonedsh.ui.nav.PdshActionKey.EXECUTE_COMMAND) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.ExecuteCommand) {
                val execRequest = engine.shellExecRequest(
                    request.command,
                    request.workingDirectory,
                    request.arguments,
                    request.requestId,
                )
                if (execRequest == null) {
                    shellRun = shellRun.copy(error = "命令请求未通过本机能力校验。")
                } else if (shellRun.runningExecId == null) {
                    shellRun = ShellRun(runningExecId = execRequest.execId)
                    providerProbeScope.launch {
                        try {
                            engine.runShellRequest(execRequest).collect { event ->
                                if (shellRun.runningExecId == execRequest.execId) {
                                    shellRun = shellRun.withExecEvent(event)
                                }
                            }
                            if (shellRun.runningExecId == execRequest.execId) {
                                shellRun = shellRun.copy(
                                    error = "执行流结束时没有收到终止事件。",
                                    runningExecId = null,
                                )
                            }
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (failure: Exception) {
                            if (shellRun.runningExecId == execRequest.execId) {
                                shellRun = shellRun.copy(
                                    error = failure.message?.substringBefore('\n')?.take(180) ?: "执行失败。",
                                    runningExecId = null,
                                )
                            }
                        }
                    }
                }
            }
        }
        if (shellRun.runningExecId != null) {
            available(com.phonedsh.ui.nav.PdshActionKey.SHELL_CANCEL) { request ->
                if (request is com.phonedsh.ui.nav.PdshUiHostCommand.ShellCancel &&
                    request.execId == shellRun.runningExecId
                ) engine.cancelShellRequest(request.execId)
            }
        }
        available(com.phonedsh.ui.nav.PdshActionKey.RUNTIME_RESTART) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.RuntimeRestart) engine.restartChatEngine()
        }
        available(com.phonedsh.ui.nav.PdshActionKey.RUNTIME_STOP) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.RuntimeStop) onStop()
        }
        if (chatUi.running && !chatUi.workerSessionId.isNullOrBlank()) {
            available(com.phonedsh.ui.nav.PdshActionKey.STOP) { request ->
                if (request is com.phonedsh.ui.nav.PdshUiHostCommand.Stop &&
                    request.sessionId == chatUi.workerSessionId && chatUi.chatId.isNotBlank()
                ) engine.stopChat()
            }
            if (preferences.busyEnterMode == BusyEnterMode.QUEUE) {
                available(com.phonedsh.ui.nav.PdshActionKey.QUEUE) { request ->
                    if (request is com.phonedsh.ui.nav.PdshUiHostCommand.Queue && request.sessionId == chatUi.workerSessionId) {
                        engine.submitWhileRunning(
                            request.sessionId,
                            request.requestId,
                            request.text,
                            com.phonedsh.ui.state.EnterMode.QUEUE,
                        )
                    }
                }
            }
            if (preferences.busyEnterMode == BusyEnterMode.STEER) {
                available(com.phonedsh.ui.nav.PdshActionKey.STEER) { request ->
                    if (request is com.phonedsh.ui.nav.PdshUiHostCommand.Steer && request.sessionId == chatUi.workerSessionId) {
                        engine.submitWhileRunning(
                            request.sessionId,
                            request.requestId,
                            request.text,
                            com.phonedsh.ui.state.EnterMode.STEER,
                        )
                    }
                }
            }
        }
        if (state is EngineHostState.Running && !chatUi.running && chatUi.error != null &&
            !chatUi.lastPromptRequestId.isNullOrBlank() &&
            (chatUi.lastSubmission.isNotBlank() || chatUi.lastAttachments.isNotEmpty())
        ) {
            available(com.phonedsh.ui.nav.PdshActionKey.RETRY) { request ->
                if (request is com.phonedsh.ui.nav.PdshUiHostCommand.Retry && request.sessionId == chatUi.chatId) {
                    engine.retryFailedChat(request.sessionId, request.requestId)
                }
            }
        }
        val durableQueueItems = chatScreenState.queueItems.orEmpty().filter { it.id is com.phonedsh.ui.state.QueueItemId.Durable }
        if (chatUi.workerSessionId != null && durableQueueItems.isNotEmpty()) {
            if (durableQueueItems.any { it.canEdit == true }) {
                available(com.phonedsh.ui.nav.PdshActionKey.QUEUE_EDIT) { request ->
                    if (request is com.phonedsh.ui.nav.PdshUiHostCommand.EditQueueItem && request.sessionId == chatUi.workerSessionId) {
                        val item = durableQueueItems.firstOrNull {
                            (it.id as? com.phonedsh.ui.state.QueueItemId.Durable)?.value == request.itemId
                        }
                        if (item != null) engine.updateChatQueueItem(item, com.phonedsh.ui.state.QueueAction.EDIT, request.requestId, request.text)
                    }
                }
            }
            if (durableQueueItems.any { it.canRemove == true }) {
                available(com.phonedsh.ui.nav.PdshActionKey.QUEUE_REMOVE) { request ->
                    if (request is com.phonedsh.ui.nav.PdshUiHostCommand.RemoveQueueItem && request.sessionId == chatUi.workerSessionId) {
                        val item = durableQueueItems.firstOrNull {
                            (it.id as? com.phonedsh.ui.state.QueueItemId.Durable)?.value == request.itemId
                        }
                        if (item != null) engine.updateChatQueueItem(item, com.phonedsh.ui.state.QueueAction.REMOVE, request.requestId)
                    }
                }
            }
            if (durableQueueItems.any { it.canSteer == true }) {
                available(com.phonedsh.ui.nav.PdshActionKey.QUEUE_STEER) { request ->
                    if (request is com.phonedsh.ui.nav.PdshUiHostCommand.SteerQueueItem && request.sessionId == chatUi.workerSessionId) {
                        val item = durableQueueItems.firstOrNull {
                            (it.id as? com.phonedsh.ui.state.QueueItemId.Durable)?.value == request.itemId
                        }
                        if (item != null) engine.updateChatQueueItem(item, com.phonedsh.ui.state.QueueAction.STEER, request.requestId)
                    }
                }
            }
        }
        val visiblePending = listOfNotNull(chatScreenState.pending.primary) + chatScreenState.pending.folded
        val latestAssistantReply = chatScreenState.rows.asReversed().firstNotNullOfOrNull { row ->
            (row as? com.phonedsh.ui.state.ChatRow.Assistant)
                ?.takeIf { !it.streaming && it.text.isNotBlank() }
                ?.text
        }
        val visiblePlan = visiblePending.firstOrNull { pending ->
            pending.channelAvailable == true && pending.questionItems.singleOrNull()?.let { item ->
                item.intentKind == "plan-review" && !item.detail.isNullOrBlank() && !item.approveWireLabel.isNullOrBlank()
            } == true
        }
        if (visiblePlan != null) {
            available(com.phonedsh.ui.nav.PdshActionKey.APPROVE_PLAN) { request ->
                if (request is com.phonedsh.ui.nav.PdshUiHostCommand.ApprovePlan &&
                    request.sessionId == chatUi.chatId && request.planRequestId == visiblePlan.typedRequestId &&
                    request.answer.isNotBlank()
                ) engine.answerChatQuestion(visiblePlan, request.answer)
            }
            available(com.phonedsh.ui.nav.PdshActionKey.REJECT_PLAN) { request ->
                if (request is com.phonedsh.ui.nav.PdshUiHostCommand.RejectPlan &&
                    request.sessionId == chatUi.chatId && request.planRequestId == visiblePlan.typedRequestId
                ) engine.dismissChatQuestion(visiblePlan)
            }
        }
        if (onSpeakText != null && latestAssistantReply != null && chatUi.chatId.isNotBlank()) {
            available(com.phonedsh.ui.nav.PdshActionKey.SPEAK_RECENT_REPLY) { request ->
                if (request is com.phonedsh.ui.nav.PdshUiHostCommand.SpeakRecentReply &&
                    request.sessionId == chatUi.chatId && request.text == latestAssistantReply
                ) {
                    if (!onSpeakText.invoke(request.text)) speechNotice = "系统语音服务未能启动朗读。"
                }
            }
        }
        available(com.phonedsh.ui.nav.PdshActionKey.EXPORT_TRANSCRIPT) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.ExportTranscript &&
                request.sessionId == chatScreenState.sessionID
            ) {
                val markdown = chatTranscriptMarkdown(chatUi.title, chatScreenState.rows)
                shareChatTranscript(context, chatUi.title, markdown)?.let { notice = it }
            }
        }
        available(com.phonedsh.ui.nav.PdshActionKey.SESSION_RENAME) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.SessionRename) providerProbeScope.launch {
                val receipt = withContext(Dispatchers.IO) { applyHostSessionCommand(engine.chatStore, request) }
                if (receipt?.requestId == request.requestId && receipt.sessionId == request.sessionId &&
                    receipt.outcome == com.phonedsh.ui.nav.PdshActionOutcome.SUCCEEDED
                ) {
                    engine.reloadChatMetadata()
                    engine.refreshSessions()
                    settingsRevision++
                }
            }
        }
        available(com.phonedsh.ui.nav.PdshActionKey.SESSION_ARCHIVE) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.SessionArchive) providerProbeScope.launch {
                val receipt = withContext(Dispatchers.IO) { applyHostSessionCommand(engine.chatStore, request) }
                if (receipt?.requestId == request.requestId && receipt.sessionId == request.sessionId &&
                    receipt.outcome == com.phonedsh.ui.nav.PdshActionOutcome.SUCCEEDED
                ) {
                    engine.reloadChatMetadata()
                    engine.refreshSessions()
                    settingsRevision++
                }
            }
        }
        available(com.phonedsh.ui.nav.PdshActionKey.SESSION_RESTORE) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.SessionRestore) providerProbeScope.launch {
                val receipt = withContext(Dispatchers.IO) { applyHostSessionCommand(engine.chatStore, request) }
                if (receipt?.requestId == request.requestId && receipt.sessionId == request.sessionId &&
                    receipt.outcome == com.phonedsh.ui.nav.PdshActionOutcome.SUCCEEDED
                ) {
                    engine.reloadChatMetadata()
                    engine.refreshSessions()
                    settingsRevision++
                } else notice = "恢复会话未确认，会话仍保留在归档列表中。"
            }
        }
        available(com.phonedsh.ui.nav.PdshActionKey.WORKSPACE_FOLDER_CREATE) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.WorkspaceFolderCreate) providerProbeScope.launch {
                val receipt = withContext(Dispatchers.IO) { applyHostWorkspaceCommand(engine.chatStore, request) }
                if (receipt?.requestId == request.requestId && receipt.outcome == com.phonedsh.ui.nav.PdshActionOutcome.SUCCEEDED) {
                    settingsRevision++
                }
            }
        }
        available(com.phonedsh.ui.nav.PdshActionKey.WORKSPACE_FOLDER_RENAME) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.WorkspaceFolderRename) providerProbeScope.launch {
                val receipt = withContext(Dispatchers.IO) { applyHostWorkspaceCommand(engine.chatStore, request) }
                if (receipt?.requestId == request.requestId && receipt.outcome == com.phonedsh.ui.nav.PdshActionOutcome.SUCCEEDED) {
                    settingsRevision++
                }
            }
        }
        available(com.phonedsh.ui.nav.PdshActionKey.WORKSPACE_FOLDER_DELETE) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.WorkspaceFolderDelete) providerProbeScope.launch {
                val receipt = withContext(Dispatchers.IO) { applyHostWorkspaceCommand(engine.chatStore, request) }
                if (receipt?.requestId == request.requestId && receipt.outcome == com.phonedsh.ui.nav.PdshActionOutcome.SUCCEEDED) {
                    settingsRevision++
                }
            }
        }
        available(com.phonedsh.ui.nav.PdshActionKey.OPEN_SETTINGS) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.OpenSettings) pushRoute(PdshRoute.Settings)
        }
        available(com.phonedsh.ui.nav.PdshActionKey.OPEN_SCHEDULES) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.OpenSchedules) pushRoute(PdshRoute.Automation)
        }
        available(com.phonedsh.ui.nav.PdshActionKey.PROVIDER_GET_MODELS) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.ProviderGetModels) {
                val draft = request.draft
                val requestId = request.requestId.value
                providerModels = com.phonedsh.ui.nav.PdshProviderOperationFact(
                    operation = com.phonedsh.ui.nav.PdshProviderOperation.GET_MODELS,
                    requestId = request.requestId,
                    profileId = draft.id.takeIf(String::isNotBlank),
                    receipt = null,
                )
                providerCatalog = com.phonedsh.ui.page.ProviderCatalogFact(
                    requestId = requestId,
                    profileId = draft.id.takeIf(String::isNotBlank),
                    isNew = draft.isNew,
                    isLoading = true,
                )
                providerProbeScope.launch {
                    val result = getProviderModels(draft, requestId)
                    val currentModels = providerModels
                    if (currentModels?.requestId?.value == result.requestId &&
                        currentModels.profileId == result.profileId
                    ) providerModels = currentModels.copy(models = result.models, message = result.message)
                    val current = providerCatalog
                    if (current?.requestId != result.requestId ||
                        current.profileId != result.profileId ||
                        current.isNew != draft.isNew
                    ) return@launch
                    providerCatalog = current.copy(
                        isLoading = false,
                        models = result.models,
                        message = result.message,
                    )
                }
            }
        }
        available(com.phonedsh.ui.nav.PdshActionKey.PROVIDER_TEST) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.ProviderTest) {
                val draft = request.draft
                val requestId = request.requestId.value
                activeProviderTestRequest = requestId
                providerConnectionTest = com.phonedsh.ui.page.ProviderConnectionTestFact(
                    profileId = draft.id, isNew = draft.isNew, isTesting = true,
                )
                providerProbeScope.launch {
                    val result = testProviderConnectionBound(draft, requestId)
                    if (activeProviderTestRequest != result.requestId || result.profileId != draft.id.takeIf(String::isNotBlank)) {
                        return@launch
                    }
                    providerConnectionTest = com.phonedsh.ui.page.ProviderConnectionTestFact(
                        profileId = draft.id,
                        isNew = draft.isNew,
                        isTesting = false,
                        succeeded = result.result is ProviderConnectionTestResult.Success,
                        message = result.result.message,
                    )
                }
            }
        }
        available(com.phonedsh.ui.nav.PdshActionKey.PROVIDER_SAVE) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.ProviderSave) {
                val draft = request.draft
                val requestId = request.requestId.value
                activeProviderSaveRequest = requestId
                providerSave = com.phonedsh.ui.page.ProviderSaveFact(
                    requestId = requestId, profileId = draft.id, isNew = draft.isNew, isSaving = true,
                )
                providerProbeScope.launch {
                    val result = saveProviderDraft(draft, requestId)
                    if (activeProviderSaveRequest != result.requestId ||
                        !providerSaveResultMatchesDraft(result, draft)
                    ) return@launch
                    if (result.recordWritten) settingsRevision++
                    providerSave = com.phonedsh.ui.page.ProviderSaveFact(
                        requestId = result.requestId,
                        profileId = result.profileId ?: draft.id,
                        isNew = draft.isNew,
                        isSaving = false,
                        succeeded = result.succeeded,
                        message = result.message,
                    )
                }
            }
        }
        available(com.phonedsh.ui.nav.PdshActionKey.NEW_SESSION) { request ->
            if (request is com.phonedsh.ui.nav.PdshUiHostCommand.NewSession) {
                // iOS `newSession(preset:)` opens a new chat and sends nothing; the
                // composer copy stays with the person. Read the draft at the click,
                // not from a remembered frame, so the newest typing survives.
                val draft = engine.chat.value.draft
                providerProbeScope.launch {
                    val receipt = engine.newChatSessionConfirmed(request.requestId)
                    if (receipt.confirms(request.requestId, receipt.sessionId, null)) {
                        if (draft.isNotEmpty()) engine.chatDraftChanged(draft)
                        resetTo(PdshRoute.Chat)
                    }
                }
            }
        }
        val readOnlyReason = when {
            permissionDefaults.writable -> null
            permissionDefaults.failure != null -> permissionDefaults.failure
            permissionDefaults.startupLocked -> UiStrings.DEFAULT_PERMISSION_STARTUP_LOCKED_REASON
            else -> permissionDefaults.readOnlyReason
        }
        // The plugin configuration page's permission block must read this
        // field's measured answer, not `settingsWritable`: the phone image's
        // startup home patch locks defaultPreset while the provider as a whole
        // still reports writable.
        val pageConfiguration = configurationFacts.copy(
            snapshot = configurationFacts.snapshot?.copy(
                defaultPermissionWritable = permissionDefaults.writable,
                defaultPermissionReadOnlyReason = readOnlyReason,
            ),
        )
        measured.copy(
            configuration = pageConfiguration,
            actionAvailability = com.phonedsh.ui.nav.PdshActionAvailabilities(actions),
            licenses = ANDROID_NATIVE_LICENSE_FACTS,
            sessions = if (sessionSnapshot.waiting && sessionSnapshot.sessions.isEmpty() && sessionSnapshot.archivedSessions.isEmpty()) null else
                (sessionSnapshot.sessions.map { record ->
                    com.phonedsh.ui.nav.PdshSessionRecord(
                        id = record.id, title = record.title, archived = false,
                        workspaceId = record.workspaceID, updatedAt = record.lastActivityMs?.let { java.time.Instant.ofEpochMilli(it).toString() },
                    )
                } + sessionSnapshot.archivedSessions.map { record ->
                    com.phonedsh.ui.nav.PdshSessionRecord(
                        id = record.id, title = record.title, archived = true,
                        workspaceId = record.workspaceID, updatedAt = record.lastActivityMs?.let { java.time.Instant.ofEpochMilli(it).toString() },
                    )
                }),
            sessionsWaiting = sessionSnapshot.waiting,
            sessionsFailure = sessionSnapshot.failure,
            settings = measured.settings.copy(
                providerSetupRequired = when (chatScreenState.empty) {
                    com.phonedsh.ui.state.ChatEmpty.PROVIDER_SETUP -> true
                    com.phonedsh.ui.state.ChatEmpty.READY -> false
                    com.phonedsh.ui.state.ChatEmpty.ENGINE_NOT_STARTED -> measured.settings.providerSetupRequired
                },
                defaultPermissionTier = permissionDefaults.currentTier,
                defaultPermissionAvailableTiers = permissionDefaults.availableTiers,
                defaultPermissionWritable = permissionDefaults.writable,
                defaultPermissionBusy = permissionDefaults.busy,
                defaultPermissionFailure = permissionDefaults.failure,
                defaultPermissionReadOnlyReason = readOnlyReason,
                defaultPermissionStartupLocked = !permissionDefaults.writable && permissionDefaults.startupLocked,
                archivedSessionCount = if (sessionSnapshot.waiting) null else sessionSnapshot.archivedSessions.size,
            ),
            automation = automationFacts.copy(currentSessionID = chatUi.workerSessionId),
            modelProvider = measured.modelProvider.copy(
                connectionTest = providerConnectionTest,
                providerSave = providerSave,
                catalog = providerCatalog,
            ),
            shell = shellFacts,
            providerOperations = listOfNotNull(providerModels),
        )
    }
    // The one fact in that snapshot that is not an engine reading: whether the
    // platform really carries this app's back gesture through the invoker. It is
    // measured by the back callback (one gesture moves it), so it is applied here
    // rather than inside the remembered walk.
    val shownFacts = PredictiveBack.measured(facts).copy(bluetooth = bluetoothFacts, ssh = sshFacts, androidAdb = androidAdbFacts, tonoAccount = tonoAccountFacts, lan = lanFacts)
    LaunchedEffect(chatUi.commandExecution?.id) {
        if (chatUi.commandExecution != null) pushRoute(PdshRoute.CommandResult)
    }
    // The model may have saved a new target with android_connect since the last read.
    LaunchedEffect(nav.current) {
        if (nav.current == PdshRoute.AndroidAdb) androidAdb.refresh()
    }
    // The drawer's open state is the contract's DRAWER overlay (`interaction.md`
    // §1 rule 9), so the system back and the close button consume the same layer.
    val drawerOpen = hostBack.drawerOpen
    // Opening the drawer on the PC segment asks the PC for its own session list;
    // the cached roster is already painted from the controller, so an offline or
    // reconnecting PC never waits on this read (and never falls back to 手机).
    LaunchedEffect(drawerOpen, pcState?.backend, pcState?.presence?.isOnline) {
        if (drawerOpen && pcState?.backend == PcBackend.PC && pcState?.presence?.isOnline == true) {
            pcController?.retryPcRoster()
        }
    }
    // The drawer stays mounted after the host closes it (selecting a session, a tab,
    // a route) so its close motion can run (spec/ui/v1/interaction.md §1 rule 8);
    // HomeDrawer reports the end of that motion through onClose.
    var drawerMounted by remember { mutableStateOf(false) }
    LaunchedEffect(drawerOpen) { if (drawerOpen) drawerMounted = true }
    var webFaceOpened by remember { mutableStateOf(false) }
    // L62: the probe is no longer the home face; it is the host's own surface
    // *at* the home address. Keeping it in the `home` slot (instead of a new
    // route) is deliberate: `PdshRoute` lives in `:lib` and this lane may not
    // extend it, and the probe was always the host's own face rather than a page
    // of §1. The default value is `false`, which is what makes the product home —
    // the session list — the launch face. L72 removed its drawer row (iOS has no
    // such row), so the only entry left is the launch the device scripts already
    // use: `--ez pdsh.face.probe true`.
    var probeOpen by remember { mutableStateOf(engine.probeFaceOnLaunch()) }
    val webFaceOnLaunch = remember { engine.webFaceOnLaunch() }
    // The one fact the home's onboarding card is drawn from. Re-read when this
    // host writes a model service (`settingsRevision`), because a save is what
    // turns the card off — and never on a recomposition alone: reading the
    // Keystore per frame would be a per-frame cost for a value that only a write
    // can change.
    val providerConfigured = remember(settingsRevision) {
        ProbeLaunchConfig.active().keyFact().status == ProviderKeyStatus.CONFIGURED
    }

    // The host's own voice. A page owns its controls, so this host cannot render
    // a button disabled; what it can do is state the truth on every route that
    // has no write command, and state the outcome of every gesture it cannot
    // complete. A dead button that says nothing reads as a missed tap.
    val routeNote: String? = hostRouteNote(nav.current)
    LaunchedEffect(notice) {
        if (notice != null) {
            delay(NOTICE_MILLIS)
            notice = null
        }
    }
    LaunchedEffect(speechNotice) {
        if (speechNotice != null) {
            delay(NOTICE_MILLIS)
            speechNotice = null
        }
    }

    // 外观 is a real preference here: the stored choice picks the token table for
    // every surface above the page (the probe face draws its own theme and is
    // handed the same resolved answer below). `system` follows the platform.
    PdshTheme(
        darkTheme = preferences.darkTheme(systemDark),
        typePreferences = UiTypePreferences(
            textSizePt = preferences.textFontSize.toFloat(),
            codeSizePt = preferences.codeFontSize.toFloat(),
            terminalSizePt = preferences.terminalFontSize.toFloat(),
            textFontFamily = resolvePreferenceFont(preferences.textFontFamily),
            codeFontFamily = resolvePreferenceFont(preferences.codeFontFamily),
            terminalFontFamily = resolvePreferenceFont(preferences.terminalFontFamily),
        ),
    ) {
        val tokens = PdshThemeValues.tokens
        // §1 says the Web surface is 引擎就绪时的默认面. This host makes that
        // opt-in (`pdsh.face.web`) instead of unconditional: the demo acceptance
        // waits for the worker and then taps 跑一轮 on the native face, so an
        // automatic switch would take the button off screen and break the demo.
        LaunchedEffect(state, webFaceOnLaunch) {
            if (webFaceOnLaunch && !webFaceOpened && state is EngineHostState.Running) {
                webFaceOpened = true
                pushRoute(PdshRoute.WebSurface)
            }
        }
        // `spec/ui/v1/README.md` §5 back-gesture: one gesture consumes exactly
        // one layer in `interaction.md` §4 rule 5's order (sheet, drawer, stack,
        // root). [BackCoordinator] is that order's only owner; this host supplies
        // the two inner levels a route owns:
        //
        //   * STACK — the rendered page's own inner level (`PdshBackLevel`: a
        //     folder drill-down, an embedded preview), then the route pop;
        //   * SHEET — a mounted `PdshSheet`, whose own inner stack pops before
        //     the sheet closes (§2 rule 9). The sheet layer is backed by the one
        //     [SheetBackHost] this host owns, so page sheets register on the same
        //     decider rather than a per-sheet chain.
        //
        // The probe is the host's own face *at* the home address (L62), not a
        // route: while it is showing, its root back leaves it for the product
        // home. Passing `onExit` only for that case keeps the real root free of a
        // callback, which is what leaves "exit the app" (and the platform's
        // back-to-home animation) to the platform itself.
        val backLevel = remember { PdshBackLevel() }
        val sheetBackHost = remember { SheetBackHost() }
        val sheetBackLayer = remember(sheetBackHost) {
            observingBackLayer(TokenBackLayer.SHEET) { sheetBackHost.dispatch() }
        }
        val stackBackLayer = remember(backLevel) {
            observingBackLayer(TokenBackLayer.STACK) { backLevel.consume() }
        }
        val activityBackDispatcher = LocalOnBackPressedDispatcherOwner.current?.onBackPressedDispatcher
        BackCoordinator(
            state = hostBack.pushBack,
            onStateChange = { next -> applyPushState(next) },
            layers = remember(sheetBackLayer, stackBackLayer) {
                listOf(sheetBackLayer, stackBackLayer)
            },
            // Only the diagnostic face intercepts the root; anywhere else the
            // platform's default exit stays in charge (`BackCoordinator` then
            // registers no callback at all).
            onExit = if (probeOpen) {
                {
                    probeOpen = false
                    resetTo(PdshRoute.Chat)
                }
            } else {
                null
            },
            enabled = hostBack.pushBack.canConsumeBack || probeOpen,
        )
        val note = notice ?: speechNotice ?: routeNote
        val statusBarTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
        Box(Modifier.fillMaxSize().background(tokens.colors.selector)) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    // Only a route with a note consumes the status bar here: the
                    // strip painted below then owns that area, and the page's own
                    // statusBarsPadding sees zero instead of pushing the page
                    // header down a second time.
                    .then(
                        if (note != null) {
                            Modifier.windowInsetsPadding(WindowInsets.statusBars)
                        } else {
                            Modifier
                        },
                    ),
            ) {
                if (note != null) HostNoteBar(text = note)
                // PR #60's bottom menu (`NativeShell.tabPages`): it belongs to the
                // first-level pages only, and leaves while the keyboard is up so the
                // composer rides the keyboard. The drawer is drawn over it below.
                val homeTab = if (probeOpen) null else nav.selectedHomeTab()
                @OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
                val imeVisible = WindowInsets.isImeVisible
                // §4 rule 4: the bar follows the *selected tab's* contract depth
                // and leaves while the keyboard is up. `PushBackState` owns both
                // facts; the host only supplies the measured IME state.
                val showTabBar = homeTab != null &&
                    hostBack.withKeyboard(imeVisible).pushBack.tabBarVisible
                Box(
                    Modifier
                        .weight(1f)
                        // The bar paints the navigation-bar inset itself, so the page
                        // above it must not pad for it a second time.
                        .then(if (showTabBar) Modifier.consumeWindowInsets(WindowInsets.navigationBars) else Modifier),
                ) {
                    PdshNavHost(
                        nav = nav,
                        facts = shownFacts,
                        // §2 rule 9 / §4 rule 5: the same chain the SHEET layer
                        // above dispatches to, so a page-owned or route-presented
                        // sheet is the layer this host's back closes first.
                        sheetBackHost = sheetBackHost,
                        onNavigate = { route ->
                            closeHostDrawer()
                            pushRoute(route)
                        },
                        onBack = { popRoute() },
                        onHome = {
                            // 原生恢复 returns to the *product* home, never back
                            // into the diagnostic face the person left open.
                            probeOpen = false
                            resetTo(PdshRoute.Chat)
                        },
                        onHostAction = { action ->
                            // L72: one action is a navigation edge, not a handoff —
                            // `OpenWorkspaceFiles` is the documented "this folder
                            // asked for its file listing" gesture, and the page it
                            // names is a route this host already renders. It is
                            // dispatched by the 开发者工具 index's 工作文件夹 row, so
                            // the person lands on the files page with one back to
                            // the index (the drawer no longer carries either page).
                            if (action.wire.startsWith("bluetooth.")) {
                                // The page owns its result line (结果); no host note.
                                bleDevices.handle(action)
                            } else if (action.wire.startsWith("ssh.")) {
                                // The page owns its result lines; no host note.
                                sshSettings.handle(action)
                            } else if (action.wire.startsWith("androidAdb.")) {
                                // The page owns its 连接状态 line; no host note.
                                androidAdb.handle(action)
                            } else if (action.wire.startsWith("tonoAccount.")) {
                                // The page owns its status line; no host note.
                                tonoAccount.handle(action)
                            } else if (action is PdshHostAction.LanScan) {
                                // The page owns its status line; no host note.
                                lanDiscovery.handle(action)
                            } else if (action is PdshHostAction.OpenWorkspaceFiles) {
                                notice = null
                                pushRoute(PdshRoute.Files(action.id.ifBlank { null }))
                            } else if (action == PdshHostAction.RestartRuntime) {
                                engine.restartChatEngine()
                                notice = null
                            } else if (action == PdshHostAction.RefreshConfiguration) {
                                providerProbeScope.launch {
                                    notice = engine.refreshConfiguration()
                                        ?: "已重新读取本会话设置"
                                }
                            } else if (action is PdshHostAction.SaveConfigurationGroup) {
                                providerProbeScope.launch {
                                    val error = engine.saveConfigurationGroup(action.namespace, action.patch)
                                    notice = error ?: "已保存本会话设置"
                                }
                            } else if (action is PdshHostAction.ResetConfigurationField) {
                                providerProbeScope.launch {
                                    val error = engine.resetConfigurationField(action.namespace, action.field)
                                    notice = error ?: "已恢复 DSH 默认值"
                                }
                            } else if (action is PdshHostAction.SaveDefaultPermission) {
                                providerProbeScope.launch {
                                    val error = engine.saveDefaultPermission(action.modeId)
                                    notice = error ?: "已更新新会话默认权限"
                                }
                            } else if (action is PdshHostAction.SelectProvider) {
                                providerProbeScope.launch {
                                    val store = ProviderConfigStore.active()
                                    if (store == null) {
                                        notice = "本宿主没有安装模型服务存储"
                                    } else {
                                        when (val outcome = withContext(Dispatchers.IO) { store.select(action.id) }) {
                                            ProviderWriteOutcome.Saved -> {
                                                settingsRevision++
                                                notice = "已选择默认模型服务；下次启动 App 时生效"
                                            }
                                            is ProviderWriteOutcome.Rejected -> notice = outcome.reason
                                            else -> notice = "本机存储不可写，本次未选择"
                                        }
                                    }
                                }
                            } else if (action is PdshHostAction.GetProviderModels) {
                                val draft = action.draft
                                val requestId = action.requestId.ifBlank { UUID.randomUUID().toString() }
                                providerCatalog = com.phonedsh.ui.page.ProviderCatalogFact(
                                    requestId = requestId,
                                    profileId = draft.id.takeIf(String::isNotBlank),
                                    isNew = draft.isNew,
                                    isLoading = true,
                                )
                                providerProbeScope.launch {
                                    val result = getProviderModels(draft, requestId)
                                    val current = providerCatalog
                                    if (current?.requestId != result.requestId ||
                                        current.profileId != result.profileId ||
                                        current.isNew != draft.isNew
                                    ) return@launch
                                    providerCatalog = current.copy(
                                        isLoading = false,
                                        models = result.models,
                                        message = result.message,
                                    )
                                }
                            } else if (action is PdshHostAction.TestProvider) {
                                if (providerConnectionTest?.isTesting != true) {
                                    val draft = action.draft
                                    val requestId = UUID.randomUUID().toString()
                                    activeProviderTestRequest = requestId
                                    providerConnectionTest = com.phonedsh.ui.page.ProviderConnectionTestFact(
                                        profileId = draft.id, isNew = draft.isNew, isTesting = true,
                                        succeeded = null, message = null,
                                    )
                                    providerProbeScope.launch {
                                        val result = testProviderConnectionBound(draft, requestId)
                                        if (activeProviderTestRequest != result.requestId ||
                                            result.profileId != draft.id.takeIf { it.isNotBlank() }
                                        ) return@launch
                                        providerConnectionTest = com.phonedsh.ui.page.ProviderConnectionTestFact(
                                            profileId = draft.id, isNew = draft.isNew, isTesting = false,
                                            succeeded = result.result is ProviderConnectionTestResult.Success,
                                            message = result.result.message,
                                        )
                                    }
                                }
                            } else if (action is PdshHostAction.SaveProvider) {
                                if (providerSave?.isSaving != true) {
                                    val draft = action.draft
                                    val requestId = action.requestId
                                    activeProviderSaveRequest = requestId
                                    providerSave = com.phonedsh.ui.page.ProviderSaveFact(
                                        requestId = requestId,
                                        profileId = draft.id,
                                        isNew = draft.isNew,
                                        isSaving = true,
                                    )
                                    providerProbeScope.launch {
                                        val result = saveProviderDraft(draft, requestId)
                                        if (activeProviderSaveRequest != result.requestId ||
                                            !providerSaveResultMatchesDraft(result, draft)
                                        ) return@launch
                                        if (result.recordWritten) settingsRevision++
                                        providerSave = com.phonedsh.ui.page.ProviderSaveFact(
                                            requestId = result.requestId,
                                            profileId = result.profileId ?: draft.id,
                                            isNew = draft.isNew,
                                            isSaving = false,
                                            succeeded = result.succeeded,
                                            message = result.message,
                                        )
                                    }
                                }
                            } else if (engine.handleAutomationAction(action)) {
                                notice = null
                            } else {
                                val feedback = handleHostAction(
                                    action = action,
                                    onStart = onStart,
                                    onStop = onStop,
                                    onSettingsChanged = { settingsRevision++ },
                                )
                                if (feedback != null) notice = feedback
                            }
                        },
                        // Settings writes reach their real stores: ordinary choices
                        // use PreferenceStore, while the new-session permission tier
                        // updates the DSH permission namespace and is accepted only
                        // after a settings/describe readback.
                        onSettingsWrite = { write ->
                            if (write is SettingsWrite.DefaultPermissionTier) {
                                providerProbeScope.launch {
                                    val result = runCatching { engine.writeDefaultPermissionTier(write.tier) }
                                    if (result.isSuccess) {
                                        settingsRevision++
                                        notice = null
                                    } else {
                                        notice = "新会话默认权限没有保存：${result.exceptionOrNull()?.message ?: "未确认"}"
                                    }
                                }
                                return@PdshNavHost
                            }
                            val change = when (write) {
                                is SettingsWrite.BackgroundKeepAlive -> ConfirmedPreferenceChange.BackgroundKeepAlive(write.value)
                                is SettingsWrite.BusyEnter -> ConfirmedPreferenceChange.BusyEnterMode(write.mode)
                                is SettingsWrite.DefaultPermissionTier -> null
                            }
                            if (change == null) {
                                notice = "本宿主没有保存「${settingsWriteLabel(write)}」的命令，本次没有保存"
                            } else {
                                providerProbeScope.launch {
                                    val receipt = engine.writePreferenceConfirmed(
                                        StateRequestId(UUID.randomUUID().toString()), change,
                                    )
                                    if (receipt.outcome is PreferenceWriteOutcome.Persisted) {
                                        Log.i(TAG_NAV, "PREF_WRITE ${write.wire}")
                                        settingsRevision++
                                    } else notice = "保存「${settingsWriteLabel(write)}」失败，本次未确认"
                                }
                            }
                        },
                        // The four generic pickers (语言 / 外观 / 工作步骤展示 / 收起时机 /
                        // 性能与用量) and the 显示代码工作视图 switch: the row id and the
                        // option id are the store's own vocabulary.
                        onPreferenceWrite = { choice ->
                            val change = engine.confirmedPreferenceChange(choice.rowId, choice.optionId)
                            if (change == null) {
                                notice = "本宿主没有保存「${preferenceRowLabel(choice.rowId)}」的命令，本次没有保存"
                            } else providerProbeScope.launch {
                                val receipt = engine.writePreferenceConfirmed(
                                    StateRequestId(UUID.randomUUID().toString()), change,
                                )
                                if (receipt.outcome is PreferenceWriteOutcome.Persisted) {
                                    Log.i(TAG_NAV, "PREF_WRITE ${choice.rowId}=${choice.optionId}")
                                    settingsRevision++
                                } else notice = "保存「${preferenceRowLabel(choice.rowId)}」失败，本次未确认"
                            }
                        },
                        onSelectFontFamily = { rowId, family ->
                            val role = when (rowId) {
                                SettingsScreenState.TEXT_FONT_SIZE_ROW_ID -> FontRole.TEXT
                                SettingsScreenState.CODE_FONT_SIZE_ROW_ID -> FontRole.CODE
                                SettingsScreenState.TERMINAL_FONT_SIZE_ROW_ID -> FontRole.TERMINAL
                                else -> null
                            }
                            if (role == null) {
                                notice = "本宿主无法保存这个字体角色，本次没有保存"
                            } else providerProbeScope.launch {
                                val receipt = engine.writePreferenceConfirmed(
                                    StateRequestId(UUID.randomUUID().toString()),
                                    ConfirmedPreferenceChange.FontFamily(role, family),
                                )
                                if (receipt.outcome is PreferenceWriteOutcome.Persisted) settingsRevision++
                                else notice = "字体偏好保存失败，本次未确认"
                            }
                        },
                        onToggleDeveloperTools = { value ->
                            providerProbeScope.launch {
                                val receipt = engine.writePreferenceConfirmed(
                                    StateRequestId(UUID.randomUUID().toString()), ConfirmedPreferenceChange.DeveloperTools(value),
                                )
                                if (receipt.outcome is PreferenceWriteOutcome.Persisted) {
                                    Log.i(TAG_NAV, "PREF_WRITE ${SettingsScreenState.DEVELOPER_TOOLS_ROW_ID}=$value")
                                    settingsRevision++
                                } else notice = "保存显示代码工作视图失败，本次未确认"
                            }
                        },
                        // The preference pages' own capability. This host owns a
                        // preference store, so the chat-appearance page's pickers and
                        // steppers are live; the session-config page keeps its own
                        // (still NO) `settingsWritable` fact.
                        preferencesWritable = FactState.YES,
                        // The two hosted gestures of the phone-permissions page: a real
                        // system request, and the settings page that can change the
                        // grant. Both are the Activity's, because a permission prompt
                        // is an Activity-scoped contract. The page has no app-use
                        // switch on this host: it is disarmed with a visible reason,
                        // because there is no capability-enable store or gate behind
                        // it (see `HostPhonePermissions.kt`).
                        onPhonePermissionRequest = onPhonePermissionRequest,
                        onPhonePermissionSettings = onPhonePermissionSettings,
                        // PCLink C5: the two PC routes render the controller's
                        // snapshot; the scanner is a host composable because :lib
                        // carries no camera dependency.
                        pcPairingState = pcPairingState,
                        pcConnectedState = pcConnectedState,
                        pcScannerContent = pcScannerContent,
                        connectedComputerValue = pcConnectedValue,
                        onPcScan = pcWiring::onScan,
                        onPcToggleOtherWays = pcWiring::onToggleOtherWays,
                        onPcPairingLinkChange = pcWiring::onPairingLinkChange,
                        onPcPairWithLink = pcWiring::onPairWithLink,
                        onPcPairingCodeChange = pcWiring::onPairingCodeChange,
                        onPcPairManually = pcWiring::onPairManually,
                        onPcCancelPairing = pcWiring::onCancelPairing,
                        onPcRetry = pcWiring::onRetry,
                        onPcDone = {
                            pcWiring.onDone()
                            popRoute()
                        },
                        onPcClose = {
                            pcWiring.onClose()
                            popRoute()
                        },
                        onPcCancelScanner = pcWiring::onCancelScanner,
                        onPcUnpair = pcWiring::onUnpairConfirmed,
                        onPcDismissUnpairFailure = pcWiring::onDismissUnpairFailure,
                        onPcConnectionScreenOpened = pcWiring::onConnectionScreenOpened,
                        onOpenDrawer = { openHostDrawer() },
                        onOpenSubagentSession = engine::openSubagentSession,
                        onLoadEarlierChatTranscript = engine::loadEarlierSubagentTranscript,
                        onFilesImportRequest = onPickWorkspaceFile,
                        filesImportReceipt = filesImportReceipt,
                        onSpeakText = onSpeakText?.let { speaker ->
                            { text ->
                                if (!speaker(text)) speechNotice = "系统语音服务未能启动朗读。"
                            }
                        },
                        onConfigurationWrite = { request ->
                            when (request) {
                                is com.phonedsh.ui.page.ConfigurationWriteRequest.SaveGroup ->
                                    engine.saveConfigurationGroupConfirmed(
                                        request.namespace,
                                        request.patch,
                                        request.expectedRevision,
                                        request.requestId,
                                    )
                                is com.phonedsh.ui.page.ConfigurationWriteRequest.ResetField ->
                                    engine.resetConfigurationFieldConfirmed(
                                        request.namespace,
                                        request.field,
                                        request.expectedRevision,
                                        request.requestId,
                                    )
                                is com.phonedsh.ui.page.ConfigurationWriteRequest.SaveDefaultPermission ->
                                    engine.saveDefaultPermissionConfirmed(
                                        request.modeId, request.expectedRevision, request.requestId,
                                    )
                                is com.phonedsh.ui.page.ConfigurationWriteRequest.Refresh -> {
                                    val failure = engine.refreshConfiguration()
                                    com.phonedsh.ui.page.ConfigurationWriteReceipt(
                                        requestId = request.requestId,
                                        success = failure == null,
                                        message = failure,
                                    )
                                }
                            }
                        },

                        // Agent 预设: the host owns all three reads/writes. The list
                        // is collected above; 使用预设 creates the Worker session with
                        // `request.agentPreset` and only then closes the settings sheet
                        // onto the new conversation. A failure returns its `code:
                        // message` and the route keeps the page open.
                        agentPresets = agentPresetFacts,
                        agentPresetActions = AgentPresetActions(
                            refresh = {
                                providerProbeScope.launch { engine.refreshAgentPresets() }
                            },
                            read = { presetId -> engine.readAgentPresetDocument(presetId) },
                            use = { presetId ->
                                val failure = engine.useAgentPreset(
                                    presetId,
                                    StateRequestId("ui.presets.use.${UUID.randomUUID()}"),
                                )
                                if (failure == null) {
                                    notice = null
                                    resetTo(PdshRoute.Chat)
                                }
                                failure
                            },
                        ),

                        // L62: the home face is the product home — the session list
                        // (option (a): the list is rendered *in* the home slot, so
                        // `popToHome()` and the launch face are the same screen). The
                        // probe is the host's own face at this address, reached only by
                        // a launch that asks for it (`--ez pdsh.face.probe true`).
                        home = {
                            if (probeOpen) {
                                ProbeScreen(
                                    state = state,
                                    hostState = hostState,
                                    handshake = handshake,
                                    channel = channel,
                                    turn = turn,
                                    notice = recoveryNotice,
                                    darkTheme = preferences.darkTheme(systemDark),
                                    onStart = onStart,
                                    onStop = onStop,
                                    onRunTurn = onRunTurn,
                                    onOpenDrawer = { openHostDrawer() },
                                    onOpenConfiguration = { pushRoute(PdshRoute.Configuration) },
                                    onOpenRuntime = { pushRoute(PdshRoute.Runtime) },
                                    onOpenWorkbench = { section, path ->
                                        pushRoute(
                                            PdshRoute.Workbench(previewPath = path, section = section),
                                        )
                                    },
                                )
                            } else {
                                HostHomeScreen(
                                    engine = engine,
                                    state = state,
                                    turn = turn,
                                    providerConfigured = providerConfigured,
                                    onHostNotice = { notice = it },
                                    onOpenDrawer = { openHostDrawer() },
                                    onOpenModelProvider = { pushRoute(PdshRoute.ModelProvider) },
                                    onOpenChat = { pushRoute(PdshRoute.Chat) },
                                )
                            }
                        },
                        webSurface = { EngineWebSurface(engine, state) },
                        // 会话 is a route now, and this host is the one that owns
                        // the session read, so the route renders the real list
                        // instead of `:lib`'s facts-only empty page.
                        sessions = {
                            HostSessionsScreen(
                                engine = engine,
                                state = state,
                                turn = turn,
                                onBack = { popRoute() },
                                onHostNotice = { notice = it },
                                // L69: selecting a row (or 新建会话) opens the chat at
                                // that conversation. The list stays the drawer's
                                // 会话 page; the person lands on the transcript they
                                // chose instead of an empty one.
                                onOpenChat = { pushRoute(PdshRoute.Chat) },
                            )
                        },
                        // The chain's middle level: what the top route can still go
                        // back to inside itself.
                        backLevel = backLevel,
                        // L69: the chat page's host half. `chatSurfaceState()` folds the
                        // Worker's projected events into the page's state; the seven
                        // callbacks are the App's own commands, not handoffs.
                        chat = chatScreenState,
                        chatTitle = chatUi.title,
                        timelineRetryAvailability = com.phonedsh.ui.nav.PdshActionAvailability.Unavailable(
                            com.phonedsh.ui.nav.PdshUnavailableReason.NOT_IMPLEMENTED,
                        ),
                        permissionApproveAvailability = com.phonedsh.ui.nav.PdshActionAvailability.Available { pending ->
                            engine.answerChatPermission(pending, true)
                        },
                        permissionDenyAvailability = com.phonedsh.ui.nav.PdshActionAvailability.Available { pending ->
                            engine.answerChatPermission(pending, false)
                        },
                        chatSubpages = com.phonedsh.ui.page.ChatSubpageFacts(
                            commandExecution = chatUi.commandExecution,
                            subagents = chatUi.sessionSnapshot.subagents,
                            schedules = automationFacts.snapshot?.schedules?.map { schedule ->
                                com.phonedsh.ui.page.ChatScheduleRow(schedule.id, schedule.title,
                                    listOfNotNull(schedule.rule, schedule.nextRun).joinToString(" · "),
                                    status = when (schedule.status) {
                                        com.phonedsh.ui.page.ScheduleStatus.ACTIVE -> "active"
                                        com.phonedsh.ui.page.ScheduleStatus.STOPPED -> "stopped"
                                        else -> null
                                    }, prompt = schedule.prompt)
                            },
                        ),
                        onChatDraftChange = engine::chatDraftChanged,
                        onChatSend = engine::sendChat,
                        onChatStop = engine::stopChat,
                        onChatRename = { title -> engine.renameCurrentChat(title) },
                        onChatAddFiles = onPickFiles,
                        onChatAddImages = onPickImages,
                        onChatRemoveAttachment = engine::removeChatAttachment,
                        onChatDismissNotice = engine::dismissChatNotice,
                        chatActions = com.phonedsh.ui.nav.ChatInteractionActions(
                            toggleRow = engine::toggleChatRow,
                            approve = { engine.answerChatPermission(it, true) },
                            deny = { engine.answerChatPermission(it, false) },
                            answer = engine::answerChatQuestion,
                            dismissQuestion = engine::dismissChatQuestion,
                            goalCommand = { engine.runChatCommand("/goal $it", showResult = false) },
                            selectAccessMode = engine::selectChatAccessMode,
                            refreshCatalogs = { engine.refreshChatSession() },
                            imeChanged = engine::chatImeChanged,
                            expandPending = engine::expandChatPending,
                            startEngine = onStart,
                            executeCommand = { engine.runChatCommand("/$it") },
                            selectModel = engine::selectChatModel,
                            restartEngine = engine::restartChatEngine,
                        ),
                        // L81: the 本 session 产物 page's attribution fact. The page
                        // reads the real materialized workspace; this is what tells
                        // it which of those files this session's turns wrote.
                        artifacts = artifactFacts,
                    )
                }
                if (showTabBar) {
                    HomeTabBar(
                        selection = homeTab,
                        onSelect = { tab ->
                            // A re-tap is a no-op inside `selectTab` (§4 rule 2), and
                            // the target tab's route stack is the only one this host owns.
                            closeHostDrawer()
                            selectHomeTab(tab)
                        },
                    )
                }
            }
            if (note != null && statusBarTop > 0.dp) {
                // The consumed status-bar strip: the same ink as the note bar, so
                // the note reads as one band from the system bar down. Drawn after
                // the routed page so it paints over the page, not under it.
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(statusBarTop)
                        .background(tokens.colors.code),
                )
            }
            if (drawerOpen || drawerMounted) {
                val groupedIds = drawerFolders.orEmpty().map { it.id }.toSet()
                val drawerFacts = HomeDrawerFacts(
                    folders = drawerFolders?.map { folder ->
                        HomeDrawerFolder(
                            id = folder.id,
                            title = folder.name,
                            isDefault = folder.id == ChatSessionStore.DEFAULT_WORKSPACE_GROUP_ID,
                            sessions = drawerRecords.orEmpty().filter { !it.archived && it.workspaceGroupId == folder.id }
                                .sortedByDescending { it.updatedAtMs }
                                .map { HomeDrawerSession(it.id, it.title.ifBlank { UiStrings.SESSION_TITLE_NEW }, running = it.id == chatUi.chatId && chatUi.running) },
                        )
                    },
                    unassignedSessions = drawerRecords?.filter {
                        !it.archived && (it.workspaceGroupId == null || it.workspaceGroupId !in groupedIds)
                    }?.sortedByDescending { it.updatedAtMs }
                        ?.map { HomeDrawerSession(it.id, it.title.ifBlank { UiStrings.SESSION_TITLE_NEW }, running = it.id == chatUi.chatId && chatUi.running) },
                    activeSessionId = chatUi.chatId.takeIf(String::isNotBlank),
                    languageId = preferences.language?.id,
                    engine = when {
                        chatScreenState.empty == com.phonedsh.ui.state.ChatEmpty.PROVIDER_SETUP -> HomeDrawerEngineState.CONFIGURATION_REQUIRED
                        state is EngineHostState.Running -> HomeDrawerEngineState.READY
                        state == EngineHostState.Starting -> HomeDrawerEngineState.STARTING
                        state == EngineHostState.Stopped -> if (providerConfigured) HomeDrawerEngineState.STOPPED else HomeDrawerEngineState.CONFIGURATION_REQUIRED
                        else -> HomeDrawerEngineState.UNKNOWN
                    },
                    // A session switch is not a reason: Android closes the
                    // drawer as soon as the tap starts, and chatUi.running is
                    // the real turn fact. Only a stopped engine or a genuinely
                    // running turn supplies the line; the drawer keeps a fixed
                    // height for it either way.
                    newSessionBlockedReason = when {
                        state !is EngineHostState.Running -> UiStrings.SESSIONS_NEW_BLOCKED_ENGINE
                        chatUi.running -> UiStrings.DRAWER_NEW_BLOCKED_TURN
                        else -> null
                    },
                    failure = drawerSnapshotFailure,
                )
                val legacyCollapsed = remember(preferences.collapsedWorkspaceFolders) {
                    if (preferences.collapsedWorkspaceFolders == null) {
                        runCatching {
                            context.getSharedPreferences("phone-dsh-home-drawer", android.content.Context.MODE_PRIVATE)
                                .getStringSet(com.phonedsh.ui.nav.HomeDrawerState.COLLAPSED_FOLDERS_KEY, null)?.toSet()
                        }.getOrNull()
                    } else null
                }
                LaunchedEffect(preferences.collapsedWorkspaceFolders, legacyCollapsed) {
                    if (preferences.collapsedWorkspaceFolders == null && !legacyCollapsed.isNullOrEmpty()) {
                        engine.writePreferenceConfirmed(
                            StateRequestId(UUID.randomUUID().toString()),
                            ConfirmedPreferenceChange.CollapsedWorkspaceFolders(legacyCollapsed),
                        )
                    }
                }
                val drawerUiState = rememberHomeDrawerUiState(
                    collapsedFolderIds = preferences.collapsedWorkspaceFolders ?: legacyCollapsed.orEmpty(),
                    onCollapsedFolderIdsChanged = { ids ->
                        val receipt = engine.writePreferenceConfirmed(
                            StateRequestId(UUID.randomUUID().toString()),
                            ConfirmedPreferenceChange.CollapsedWorkspaceFolders(ids),
                        )
                        receipt.outcome is PreferenceWriteOutcome.Persisted
                    },
                )
                HomeDrawer(
                    facts = drawerFacts,
                    isOpen = drawerOpen,
                    state = drawerUiState,
                    // One back, one layer: the drawer's dialog forwards the gesture
                    // to the Activity's [BackCoordinator] and the host starts the
                    // same close motion. The guard keeps a gesture made in the
                    // one-frame gap after the overlay closed (session chosen,
                    // drawer still animating) from reaching the platform default,
                    // which would exit the app instead of doing nothing.
                    onBackPressed = {
                        if (hostBack.pushBack.canConsumeBack || probeOpen) {
                            activityBackDispatcher?.onBackPressed()
                        }
                    },
                    onClose = { closeHostDrawer(); drawerMounted = false },
                    onCreateSession = {
                        val requestId = StateRequestId(UUID.randomUUID().toString())
                        val receipt = engine.newChatSessionConfirmed(requestId)
                        val created = receipt.confirms(requestId, receipt.sessionId, null)
                        if (created) {
                            notice = null
                            resetTo(PdshRoute.Chat)
                            settingsRevision++
                        } else {
                            drawerSnapshotFailure = "新会话没有创建成功，列表未改变。请重试。"
                        }
                        created
                    },
                    onCreateSessionInFolder = { folderId ->
                        val requestId = StateRequestId("ui.drawer.new-session.${UUID.randomUUID()}")
                        val receipt = engine.newChatSessionConfirmed(requestId, folderId)
                        val created = receipt.confirms(requestId, receipt.sessionId, null)
                        if (created) {
                            notice = null
                            drawerSnapshotFailure = null
                            resetTo(PdshRoute.Chat)
                            settingsRevision++
                        }
                        created
                    },
                    onMutation = { command ->
                        val receipt = withContext(Dispatchers.IO) {
                            when (command) {
                                is com.phonedsh.ui.nav.PdshUiHostCommand.WorkspaceFolderCreate,
                                is com.phonedsh.ui.nav.PdshUiHostCommand.WorkspaceFolderRename,
                                is com.phonedsh.ui.nav.PdshUiHostCommand.WorkspaceFolderDelete ->
                                    applyHostWorkspaceCommand(engine.chatStore, command)
                                is com.phonedsh.ui.nav.PdshUiHostCommand.SessionRename ->
                                    applyHostSessionCommand(engine.chatStore, command)
                                else -> null
                            }
                        }
                        val expectedRequestId = when (command) {
                            is com.phonedsh.ui.nav.PdshUiHostCommand.WorkspaceFolderCreate -> command.requestId
                            is com.phonedsh.ui.nav.PdshUiHostCommand.WorkspaceFolderRename -> command.requestId
                            is com.phonedsh.ui.nav.PdshUiHostCommand.WorkspaceFolderDelete -> command.requestId
                            is com.phonedsh.ui.nav.PdshUiHostCommand.SessionRename -> command.requestId
                            else -> null
                        }
                        val expectedSessionId = (command as? com.phonedsh.ui.nav.PdshUiHostCommand.SessionRename)?.sessionId
                        if (expectedRequestId != null && receipt?.confirms(expectedRequestId, expectedSessionId, null) == true) {
                            if (command is com.phonedsh.ui.nav.PdshUiHostCommand.SessionRename) {
                                engine.reloadChatMetadata()
                            }
                            settingsRevision++
                            drawerSnapshotFailure = null
                        }
                        receipt
                    },
                    onRetry = { settingsRevision++ },
                    onOpenSession = { id ->
                        engine.openChatSession(id)
                        notice = null
                        resetTo(PdshRoute.Chat)
                    },
                    onArchiveSession = { request: HomeDrawerArchiveRequest ->
                        val receipt = withContext(Dispatchers.IO) {
                            applyHostSessionCommand(
                                engine.chatStore,
                                com.phonedsh.ui.nav.PdshUiHostCommand.SessionArchive(
                                    request.sessionId,
                                    StateRequestId(request.requestId),
                                ),
                            )
                        }
                        val result = if (receipt?.requestId?.value == request.requestId &&
                            receipt.sessionId == request.sessionId && receipt.outcome == com.phonedsh.ui.nav.PdshActionOutcome.SUCCEEDED
                        ) {
                            engine.reloadChatMetadata()
                            engine.refreshSessions()
                            settingsRevision++
                            HomeDrawerArchiveResult.Archived(request.requestId, request.sessionId)
                        } else HomeDrawerArchiveResult.Failed(request.requestId, request.sessionId, "归档未确认，原会话仍保留")
                        result
                    },
                    // PCLink C5: the drawer's segment reads/writes the P18 value
                    // through the controller. Selecting PC while unpaired opens the
                    // PC empty card, never the phone list.
                    pcDrawer = pcDrawerState,
                    onSelectPcBackend = pcWiring::onSelectBackend,
                    onOpenPcPairing = { pushRoute(PdshRoute.PcPairing) },
                    onRetryPc = pcWiring::onRetryRoster,
                    onOpenConnectedComputer = { pushRoute(PdshRoute.ConnectedComputer) },
                )
            }
        }
    }
}

/**
 * The host half of PCLink C5: it keeps the page-local draft stages and maps the
 * controller snapshot through `PcUiMapping`. The controller stays the owner of
 * the protocol/record/roster facts; this class only remembers what the page
 * itself would remember (the 配对链接/配对码 drafts, the open scanner sheet and
 * whether an unpair was attempted).
 *
 * It is deliberately a plain object rather than a second state machine: every
 * callback is one controller intent from `PcUiMapping`, and the state getters
 * are pure projections of the caller's latest [PcWorkspaceState]. The JVM wiring
 * test drives the same methods the pages call.
 */
internal class HostPcLinkWiring(
    private val controller: PcWorkspaceController?,
    private val requestCameraPermission: () -> Unit = {},
) {
    /** The page-local pairing draft/scanner stage, before controller facts win. */
    var pairingUiState by mutableStateOf(PCPairingUiState())
        private set

    private var unpairAttempted by mutableStateOf(false)

    /** The pairing page snapshot the route renders. */
    fun pairingState(source: PcWorkspaceState?): PCPairingUiState =
        source?.toPcPairingUiState(pairingUiState) ?: pairingUiState

    /** The connected-computer snapshot; an unpair failure is the attempt's own. */
    fun connectedState(source: PcWorkspaceState?): ConnectedComputerUiState {
        if (source == null) return ConnectedComputerUiState()
        return source.toConnectedComputerUiState(
            unpairFailure = if (unpairAttempted) source.lastError?.message else null,
        )
    }

    /** The 手机 | PC segment plus the PC-scope list. */
    fun drawerState(source: PcWorkspaceState?): PcDrawerUiState =
        source?.toPcDrawerUiState() ?: PcDrawerUiState()

    /** 已连接的电脑's trailing value, or `null` when the host has no seam. */
    fun settingsValue(source: PcWorkspaceState?): String? = source?.toPcSettingsValue()

    // ---- Pairing page callbacks ----------------------------------------

    /** 扫码连接. A denied/absent camera becomes the page's one honest state. */
    fun onScan() {
        val target = controller ?: return
        pairingUiState = target.startPcScan(pairingUiState)
        if (target.state.value.camera == PcCameraAvailability.DENIED) {
            requestCameraPermission()
        }
    }

    fun onToggleOtherWays() {
        pairingUiState = pairingUiState.toggleOtherWays()
    }

    fun onPairingLinkChange(value: String) {
        pairingUiState = pairingUiState.withPairingLink(value)
    }

    fun onPairWithLink() {
        val target = controller ?: return
        pairingUiState = target.pairWithPcLink(pairingUiState)
    }

    fun onPairingCodeChange(value: String) {
        pairingUiState = pairingUiState.withPairingCode(value)
    }

    fun onPairManually() {
        val target = controller ?: return
        pairingUiState = target.pairWithPcCode(pairingUiState)
    }

    fun onQrDecoded(payload: String) {
        val target = controller ?: return
        target.pairWithPcQr(payload)
        pairingUiState = pairingUiState.scannerDismissed()
    }

    fun onCameraUnavailable() {
        controller?.onCameraPermissionResult(false)
        pairingUiState = pairingUiState.cameraUnavailable()
    }

    fun onCancelPairing() {
        val target = controller
        if (target != null) {
            pairingUiState = target.cancelPcPairing()
        } else {
            pairingUiState = PCPairingUiState()
        }
    }

    fun onRetry() {
        val target = controller ?: return
        pairingUiState = target.retryPcPairing(pairingUiState)
        if (target.state.value.camera == PcCameraAvailability.DENIED) {
            requestCameraPermission()
        }
    }

    fun onDone() {
        val target = controller
        pairingUiState = target?.finishPcPairing() ?: PCPairingUiState()
    }

    fun onClose() {
        if (controller?.state?.value?.pairing?.isBusy == true) controller.cancelPairing()
        pairingUiState = PCPairingUiState()
    }

    fun onCancelScanner() {
        pairingUiState = pairingUiState.scannerDismissed()
    }

    // ---- Drawer / connected page callbacks ------------------------------

    fun onSelectBackend(backend: PcDrawerBackend) {
        controller?.selectPcBackend(backend)
    }

    fun onRetryRoster() {
        controller?.retryPcRoster()
    }

    fun onUnpairConfirmed() {
        unpairAttempted = true
        controller?.unpairPc()
    }

    fun onDismissUnpairFailure() {
        unpairAttempted = false
    }

    fun onConnectionScreenOpened() {
        controller?.connectionScreenOpened()
    }
}

/**
 * The scanner slot `PCPairingPage` hands to the host. `:lib` carries no camera
 * dependency, so CameraX + ZXing live here and the page only sees a composable.
 * A bind that fails after `checkCameraForScanning` reports the unavailable page
 * state rather than leaving a dead preview on screen.
 */
@Composable
private fun PcQrScannerContent(
    controller: PcWorkspaceController,
    onDecoded: (String) -> Unit,
    onUnavailable: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = context.findLifecycleOwner()
    if (lifecycleOwner == null) {
        LaunchedEffect(Unit) { onUnavailable() }
        return
    }
    val previewView = remember(context) { PreviewView(context) }
    val scanner = remember(context, lifecycleOwner) { PcQrScanner(context, lifecycleOwner) }
    val mainExecutor = remember(context) { ContextCompat.getMainExecutor(context) }
    DisposableEffect(scanner) { onDispose { scanner.close() } }
    AndroidView(
        factory = { previewView },
        modifier = Modifier.fillMaxWidth().aspectRatio(1f),
    )
    LaunchedEffect(scanner, previewView) {
        val availability = scanner.start(previewView) { payload ->
            // The analysis executor must not write Compose state directly.
            mainExecutor.execute { onDecoded(payload) }
        }
        if (availability != PcCameraAvailability.AVAILABLE) onUnavailable()
    }
}

/** The Activity in the context chain, or `null` when this is not an Activity tree. */
private tailrec fun Context.findLifecycleOwner(): LifecycleOwner? = when (this) {
    is LifecycleOwner -> this
    is ContextWrapper -> baseContext.findLifecycleOwner()
    else -> null
}

/**
 * Hands one page gesture to the composition root and returns the line to show.
 *
 * The engine commands (stop, start, retry) and the model-service save are real
 * host commands and are performed here; their line says what happened. Every
 * other gesture is a handoff this build cannot complete, and the returned line
 * says exactly that instead of leaving a dead control silent.
 *
 * @param action the page's gesture.
 * @param onStart start the engine.
 * @param onStop stop the engine.
 * @param onSettingsChanged bumped after a write really landed, so the next facts
 *   walk re-reads the device store. It never carries a value.
 * @return the note-bar line for the gesture, or `null` when nothing should be
 *   shown: the page already says it itself (its inline editor opened, or the
 *   route note covers a read-only page).
 */
private fun handleHostAction(
    action: PdshHostAction,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onSettingsChanged: () -> Unit = {},
): String? {
    // The label is token-free: an action never carries user text into the log.
    Log.i(TAG_NAV, "host action handed off: ${action.wire}")
    // 网页搜索's five writes land in the independent Search/Fetch store. Its
    // line never contains the key; a write that changed nothing re-reads nothing.
    handleWebSearchAction(action, WebSearchSettingsStore.active())?.let { result ->
        if (result.changed) onSettingsChanged()
        return result.message
    }
    return when (action) {
        PdshHostAction.StopRuntime -> {
            onStop()
            "已请求：停止本地引擎"
        }

        PdshHostAction.RestartRuntime -> {
            onStart()
            "已请求：启动本地引擎"
        }

        PdshHostAction.RetryWebSurface -> {
            onStart()
            "已请求：重试本地引擎"
        }

        // The page's editor is its own inline form (`ModelProviderSettingsPage`
        // opens it before calling this), so the handoff is only the notification
        // and there is nothing for the host to open. No line: a notice saying
        // "opened" would duplicate the editor the person can already see.
        is PdshHostAction.OpenProviderEditor -> null

        PdshHostAction.RefreshModelProvider -> {
            onSettingsChanged()
            "已重新读取：模型服务"
        }

        is PdshHostAction.SaveProvider -> run {
            val result = runBlocking { saveProvider(action.draft) }
            if (result.recordWritten) onSettingsChanged()
            result.message
        }

        is PdshHostAction.DeleteProvider -> deleteProvider(action.id, onSettingsChanged)

        // A connectivity test would have to reach the endpoint from this device,
        // through the same gateway the turn uses; this build has no such probe, so
        // the gesture gets the fact instead of a fabricated 通过.
        is PdshHostAction.TestProvider -> "本宿主没有往模型端点发测试请求的命令，本次未测试"

        is PdshHostAction.RunShellCommand ->
            "只读：本宿主列出了本机可执行的加速器，但没有调用 exec 桥的命令，本次未运行"

        // Design §3 promises a revoke "at any time within this session". Before
        // this branch the only way was to stop the local engine, which ends the
        // session the approval belonged to — a revoke that costs the thing it
        // was revoking for. The answer is the gate's own, never a local guess:
        // nothing granted means nothing was revoked, and the sentence says so.
        PdshHostAction.RevokeUbuntuApproval -> run {
            val revoked = UbuntuApproval.revoke()
            if (revoked) {
                "已撤销本会话的本地 Ubuntu 授权；下一次 ubuntu run 会重新询问"
            } else {
                "本会话没有已授予的本地 Ubuntu 授权，没有可撤销的东西"
            }
        }

        // 工作文件夹's 重试: this host owns exactly one workspace fact (the
        // materialized tree's existence), so the retry is a real re-read — the
        // settings revision forces the next facts walk, and nothing is claimed that
        // was not measured again.
        PdshHostAction.RefreshWorkspace -> {
            onSettingsChanged()
            "已重新读取：工作文件夹"
        }

        // §1 assigns the MCP save to the host, so the gesture is a handoff. The
        // registry lives in the Worker (`/dsh/home/mcp.json`) and is edited through
        // the `phone/mcpUpsert` host tool, which this build does not register: a
        // second registry in the App would be a document nothing reads.
        is PdshHostAction.SaveMcpServer ->
            "本次未保存：本宿主没有改写 MCP 注册表的工具（phone/mcpUpsert）"

        // Every remaining action names a command this build does not carry. The
        // line is specific instead of a template, and it never says a write landed:
        // the page keeps whatever it was showing, and the person is told why.
        // 新会话默认权限 and the settings writes above are the same shape (L74).
        else -> "本宿主没有「${actionLabel(action)}」这条命令，页面保持只读，本次没有改动"
    }
}

/** A failed result keeps the editor open; `recordWritten` separately tells the host to refresh facts. */
private suspend fun saveProvider(draft: ProviderDraft): HostProviderSaveResult =
    saveProviderDraft(draft, requestId = "")

internal fun providerSaveResultMatchesDraft(result: HostProviderSaveResult, draft: ProviderDraft): Boolean =
    result.isNew == draft.isNew && (draft.isNew || result.profileId == draft.id.takeIf(String::isNotBlank))

/**
 * Removes what this host really owns: the saved record and its key.
 *
 * When no record is stored the row *is* the launch's service, which this App
 * cannot delete; only its key can be removed, and the line says which of the two
 * happened.
 *
 * @param onSettingsChanged bumped only after the record really changed.
 */
private fun deleteProvider(id: String, onSettingsChanged: () -> Unit): String {
    val result = deleteProviderRecord(id, ProviderConfigStore.active(), ApiKeyStore.active())
    if (result.profileRemoved || result.keyRemoved) onSettingsChanged()
    return result.message
}

/** The person-facing name of one handed-off action; every action has one. */
private fun actionLabel(action: PdshHostAction): String = when (action) {
    is PdshHostAction.WorkspaceCreate -> "新建文件夹"
    is PdshHostAction.WorkspaceSwitch -> "切换文件夹"
    is PdshHostAction.WorkspaceDelete -> "删除文件夹"
    is PdshHostAction.OpenWorkspaceFiles -> "打开文件夹的文件列表"
    PdshHostAction.RefreshWorkspace -> "重新读取文件夹"
    PdshHostAction.RefreshAutomation -> "重新读取定时任务"
    is PdshHostAction.SaveAutomationSchedule -> "保存定时任务"
    is PdshHostAction.DeleteAutomationSchedule -> "删除定时任务"
    is PdshHostAction.LoadAutomationHistory -> "定时任务投递记录"
    PdshHostAction.LoadMoreAutomationHistory -> "加载更多定时任务历史"
    is PdshHostAction.OpenAutomationEditor -> "定时任务编辑器"
    PdshHostAction.RefreshConfiguration -> "重新读取会话配置"
    is PdshHostAction.SaveConfigurationGroup -> "保存会话配置"
    is PdshHostAction.ResetConfigurationField -> "恢复配置默认值"
    is PdshHostAction.SaveDefaultPermission -> "保存新会话默认权限"
    is PdshHostAction.OpenProviderEditor -> "模型服务编辑器"
    PdshHostAction.RefreshModelProvider -> "重新读取模型服务"
    is PdshHostAction.SaveProvider -> "保存模型服务"
    is PdshHostAction.DeleteProvider -> "删除模型服务"
    is PdshHostAction.SelectProvider -> "选择默认模型服务"
    is PdshHostAction.GetProviderModels -> "获取模型列表"
    is PdshHostAction.TestProvider -> "测试模型服务"
    PdshHostAction.RevokeUbuntuApproval -> "撤销本地 Ubuntu 授权"
    is PdshHostAction.SetWebSearchEnabled -> "网页搜索开关"
    is PdshHostAction.SelectWebSearchBackend -> "网页搜索后端"
    is PdshHostAction.SetWebSearchMode -> "选择网页搜索方式"
    is PdshHostAction.CommitWebSearchAddress -> "保存搜索服务地址"
    is PdshHostAction.CommitWebSearchKey -> "保存搜索服务密钥"
    PdshHostAction.ClearWebSearchKey -> "清除搜索服务密钥"
    PdshHostAction.RemoveWebSearchConfiguration -> "删除搜索服务"
    PdshHostAction.RefreshWebSearch -> "重新读取网页搜索"
    PdshHostAction.RefreshMcp -> "重新读取 MCP 服务器"
    is PdshHostAction.BluetoothPageVisible -> "蓝牙设备页"
    is PdshHostAction.BluetoothScan -> "扫描蓝牙设备"
    is PdshHostAction.LanScan -> "扫描局域网设备"
    is PdshHostAction.BluetoothConnect -> "连接蓝牙设备"
    is PdshHostAction.BluetoothDisconnect -> "断开蓝牙设备"
    is PdshHostAction.BluetoothGrant -> "蓝牙授权"
    is PdshHostAction.BluetoothRead -> "读取蓝牙数据"
    is PdshHostAction.BluetoothAlert -> "蓝牙提醒"
    is PdshHostAction.SshSaveConnection -> "保存 SSH 连接"
    is PdshHostAction.SshDeleteConnection -> "删除 SSH 连接"
    is PdshHostAction.SshInspectHostKey -> "读取 SSH 服务器指纹"
    is PdshHostAction.AndroidAdbSave -> "保存 Android ADB"
    is PdshHostAction.AndroidAdbCheck -> "测试 Android ADB 连接"
    PdshHostAction.AndroidAdbCancel -> "停止当前 Android 操作"
    is PdshHostAction.TonoAccountRequestCode -> "获取 Tono 验证码"
    is PdshHostAction.TonoAccountSignIn -> "登录 Tono 账号"
    PdshHostAction.TonoAccountSignOut -> "退出 Tono 账号"
    is PdshHostAction.SaveMcpServer -> "保存 MCP 服务器"
    PdshHostAction.StopRuntime -> "停止本地引擎"
    PdshHostAction.RestartRuntime -> "启动本地引擎"
    PdshHostAction.RefreshRuntime -> "重新读取运行时"
    is PdshHostAction.RunShellCommand -> "运行命令"
    PdshHostAction.RefreshEgress -> "重新读取出网白名单"
    is PdshHostAction.OpenWorkbenchFile -> "读取文件预览"
    PdshHostAction.RetryWebSurface -> "重试本地引擎"
    // L24: the chat sheets' one read (both `ChatPage.swift:441`/`:449` call
    // `refreshActivity`, which fills jobs and schedules together).
    PdshHostAction.RefreshSessionActivity -> "重新读取本会话的定时任务与后台任务"
}

/**
 * The route-wide read-only statement, or `null` on a route whose actions are real.
 *
 * These are the routes §1 gives host-owned writes that this host has no command
 * for. The note is the host's disclosure; a page that owns a field for the same
 * sentence (网页搜索's `readOnlyReason`) prints it itself, and this function then
 * returns `null` so the reason is not doubled.
 */
private fun hostRouteNote(route: PdshRoute): String? = when (route) {
    // Files are read: the row's file list opens the materialized workspace (the
    // `is PdshRoute.Files` note below is null because the page reports its own
    // read). Only the folder writes are missing, so the note names just those.
    PdshRoute.WorkspaceFolders ->
        "只读：本宿主未实现文件夹的新建、切换、删除"

    // The model service is writable now: the device record holds the row and the
    // Keystore holds the key, and the page's own 生效方式 line says when a save
    // applies. A route note would contradict it.
    PdshRoute.ModelProvider -> null

    // 网页搜索 prints the host's reason itself, under the controls it disabled
    // (`WebSearchFacts.readOnlyReason`): one statement, not a bar plus a footnote.
    PdshRoute.WebSearch -> null

    // The registry is the Worker's document; this App has no `phone/mcpUpsert`
    // host tool to change it, and writing a second registry here would be a
    // document nothing reads. The note names the missing tool, not just 只读.
    PdshRoute.Mcp ->
        "只读：MCP 注册表在 Worker 的 /dsh/home/mcp.json，改写要走宿主的 phone/mcpUpsert 工具；" +
            "本宿主只注册了 phone info 与 phone ubuntu"

    is PdshRoute.McpEditor ->
        "保存不会落盘：本宿主没有 phone/mcpUpsert 这个 host tool"

    PdshRoute.Bluetooth -> null
    PdshRoute.Ssh, is PdshRoute.SshEditor -> null
    PdshRoute.AndroidAdb -> null
    PdshRoute.TonoAccount -> null

    PdshRoute.Configuration -> null
    PdshRoute.Automation -> null

    // PCLink C5 is live: both pages render the controller's own pairing/record
    // state, and their failures are the page's own lines. A route-wide note would
    // be a second, weaker version of that disclosure.
    PdshRoute.PcPairing, PdshRoute.ConnectedComputer -> null

    // The rules are real: they are the App's own /v1/http policy. The note is
    // what keeps them from being mistaken for the DSH settings allow-list.
    PdshRoute.Egress ->
        "本机 App 的出网规则（不是 DSH 设置里的白名单）"

    is PdshRoute.Workbench ->
        "本宿主未实现文件内容读取；预览保持待读"

    // 命令 has a real snapshot now (the HELLO's accelerators): when there is one
    // the page shows the run form, and when there is none its own 还没接上命令 body
    // is the honest state. A route-wide line would be a second, weaker version.
    PdshRoute.Tools -> null

    PdshRoute.Export ->
        "本宿主没有导出诊断的命令，页面只显示它读到的状态"

    // §1's files page is read-only here: the page itself reports what it could and
    // could not read, so a route note would only repeat its own line.
    is PdshRoute.Files -> null

    // 文件预览 (L29) reads the materialized workspace through the same seam the
    // files page does, and prints its own four honest states (正在读取… / 无法预览 +
    // 原因 + 重试 / 暂时不能预览 + 原因 + 分享 / the body). A host-wide line would be a
    // second, weaker version of the page's own disclosure.
    is PdshRoute.Preview -> null

    // 对话 is live now (L69): the transcript comes from the Worker's own events,
    // the composer sends a real prompt and 停止 cancels the turn, so there is
    // nothing read-only to disclose.
    PdshRoute.Chat -> null

    // 会话 has a real host read (`HostSessionsScreen`), handed to the route through
    // `PdshNavHost(sessions = …)`: no disclosure is needed, and a read-only line
    // here would now be false.
    PdshRoute.Sessions -> null

    // The three device routes read the `:domain` connector's in-memory double: a
    // page full of data that is not a real pairing must say so, or the demo reads
    // as a working transport.
    PdshRoute.DeviceConnection ->
        "演示数据：客厅网关来自内存连接器，本宿主没有真实设备通道"

    is PdshRoute.DeviceSession ->
        "演示数据：记录来自内存传输，不是真实设备会话"

    // 本 session 产物 is not demo data any more (L81): the page lists the real
    // materialized workspace and its 本 session rows come from the host's own
    // per-turn write measurement. The page prints its own read states (暂无工作区 +
    // 重试, 无法读取产物 + 重试, the two sections), so a route-wide line would be a
    // second, weaker version of its disclosure — the same reason the files and
    // preview routes have none.
    is PdshRoute.SessionArtifacts -> null

    // The settings family's reference sheets render their own state: the route
    // hands each page the host's facts (聊天外观, 手机权限 — whose rows are the
    // host's own permission read, so an unread row prints no status line while the
    // audit card says 宿主没有报告使用审计) or an empty snapshot that the page prints
    // as 未知/读取不到 (配置文件, 快捷键), and the plugin page is a local matrix. A
    // host-wide line here would be a second, weaker version of the page's own
    // disclosure. None of them is a drawer row; they are opened from the settings
    // index.
    PdshRoute.AgentPresets,
    PdshRoute.PluginInventory,
    PdshRoute.PhonePermissions,
    PdshRoute.ChatPreferences,
    PdshRoute.SettingsDocument,
    PdshRoute.Shortcuts,
    -> null

    // L24: the chat family's three 内嵌子页 each print their own 读取不到 line when
    // this host made no read (`ChatSubpageFacts` stays at its "not reported"
    // default), so a route-wide note would be a second, weaker version of the
    // page's own disclosure — the same reason the settings sheets above have none.
    PdshRoute.CommandResult,
    PdshRoute.SessionJobs,
    PdshRoute.SessionSchedules,
    -> null

    PdshRoute.Home, PdshRoute.Settings, PdshRoute.Runtime, PdshRoute.WebSurface -> null

    // PR #60's 我的 / 设置 / 发现: the settings pages print their own read states as
    // the sheet does, and 发现 is a fixed list of entries into pages that do.
    PdshRoute.MeTab, PdshRoute.SettingsMore, PdshRoute.Discover -> null
}

/** The person-facing name of one settings write the host cannot persist. */
private fun settingsWriteLabel(write: SettingsWrite): String = when (write) {
    is SettingsWrite.BackgroundKeepAlive -> "后台运行开关"
    is SettingsWrite.BusyEnter -> "发送消息时的排队方式"
    is SettingsWrite.DefaultPermissionTier -> "新会话默认权限"
}

/**
 * The user-facing name of a preference row this host could not write.
 *
 * Only the rows the preference store really answers are wired, so the refusal is
 * the store's own `false` — this label exists so a future row cannot be handed
 * back as a bare id.
 */
private fun preferenceRowLabel(rowId: String): String = when (rowId) {
    SettingsScreenState.LANGUAGE_ROW_ID -> "语言"
    SettingsScreenState.APPEARANCE_ROW_ID -> "外观"
    SettingsScreenState.FONT_SIZE_ROW_ID -> "字号大小"
    SettingsScreenState.TRANSCRIPT_VIEW_ROW_ID -> "工作步骤展示"
    SettingsScreenState.COLLAPSE_TIMING_ROW_ID -> "工作步骤收起时机"
    SettingsScreenState.PERFORMANCE_ROW_ID -> "性能与用量"
    SettingsScreenState.TEXT_FONT_SIZE_ROW_ID,
    SettingsScreenState.CODE_FONT_SIZE_ROW_ID,
    SettingsScreenState.TERMINAL_FONT_SIZE_ROW_ID -> "字号大小"
    else -> rowId
}

/** One host-owned line above the page: a disclosure, then a gesture's outcome. */
@Composable
private fun HostNoteBar(text: String) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(tokens.colors.code)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.geometry.bannerInsetV,
            ),
    ) {
        BasicText(
            text = text,
            style = type.caption.copy(color = tokens.colors.secondary),
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        )
    }
}

/**
 * The engine's one WebView, attached as the Web surface — or the honest notice
 * that replaces it.
 *
 * The view is owned by the engine; [key] on the instance is what makes a
 * renderer-death rebuild attach the fresh view instead of the destroyed one.
 *
 * A failed engine, or a kernel whose runtime probe says the worker cannot run
 * there, must not be rendered as the WebView: an attached blank WebView is
 * indistinguishable from a hang, and the plan's §6.2/§6.3 rule is a fail-loud
 * report instead. The notice names the reason the host actually measured (the
 * engine's failure reason, or the missing feature ids) — it is not a generic
 * "something went wrong".
 */
@Composable
private fun EngineWebSurface(engine: ProbeEngineViewModel, state: EngineState) {
    val kernel = engine.kernelReport()
    val failure = (state as? EngineHostState.Failed)?.reason
    val unsupportedKernel = kernel?.verdict == KernelVerdict.UNSUPPORTED
    if (failure != null || unsupportedKernel) {
        EngineUnavailableNotice(
            title = if (unsupportedKernel) {
                UiStrings.RUNTIME_WEBVIEW_GATE_MISSING
            } else {
                UiStrings.RUNTIME_SECTION_ENGINE + "不可用"
            },
            reason = failure,
            detail = kernel?.featureGateDetail(),
        )
        return
    }
    val view: View? = engine.currentWebView()
    if (view == null) {
        Box(Modifier.fillMaxSize())
        return
    }
    key(view) {
        AndroidView(factory = { view }, modifier = Modifier.fillMaxSize())
    }
}

/**
 * The page the host renders when the engine cannot be the page.
 *
 * Same tokens and type as every other host-owned line, so it looks like part of
 * the app rather than a debug dump; the technical detail stays on its own line
 * and is allowed to be English because it is evidence (feature ids, provider).
 */
@Composable
private fun EngineUnavailableNotice(title: String, reason: String?, detail: String?) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(tokens.colors.background)
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(tokens.geometry.pageOuterMarginH),
        contentAlignment = Alignment.Center,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(tokens.geometry.bannerGap)) {
            BasicText(text = title, style = type.body.copy(color = tokens.colors.primary))
            if (reason != null) {
                BasicText(text = reason, style = type.caption.copy(color = tokens.colors.secondary))
            }
            if (detail != null) {
                BasicText(text = detail, style = type.caption.copy(color = tokens.colors.tertiary))
            }
        }
    }
}

/** The host's navigation log tag; only stable action labels are written to it. */
private const val TAG_NAV: String = "PDSHNav"

/** How long a gesture's outcome line stays on screen (four seconds). */
private const val NOTICE_MILLIS: Long = 4_000L
