// SPDX-License-Identifier: MIT

#if canImport(ProbeKit)
import ProbeKit
#endif
import PhoneDSHBot
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BotChatPage: View {
    @ObservedObject var model: BotChatModel
    var cardActions: BotCardActions
    var onOpenInfo: () -> Void
    var onOpenInfoSection: (BotInfoSection) -> Void
    var hasOnlineDevices: Bool
    var onConnectDevice: () -> Void
    var externalDocumentAction: ((BotUIRow) -> Void)?
    let isMainBot: Bool
    let onSelectBot: (String) -> Void
    let peerAppearance: (String) -> BotFishAppearance?
    let peerIsMainBot: (String) -> Bool
    let peerReaction: (String) -> BotFishReaction?
    let handleExternalDeepLink: (URL) -> Bool
    let openDrawer: (() -> Void)?
    /// Capture/test entry: focus the composer once so the keyboard-open layout
    /// can be reproduced without an XCUITest tap. Production pages leave this
    /// false; the interaction test still taps the field like a user.
    let initialComposerFocus: Bool
    /// Capture fixture: start with a multi-line draft so the composer is
    /// already at its grown height when the keyboard opens.
    let initialComposerText: String
    /// Fixture-only row-body counter; production pages pass nil.
    let transcriptProbe: BotTranscriptRenderProbe?
    private let initialAttachments: [BotDraftAttachment]
    private let initialAttachmentNotice: String?

    @State private var sourceRow: BotUIRow?
    @State private var documentRow: BotUIRow?
    /// The attachment card's native preview. A path the host cannot resolve
    /// never reaches this state: `canOpenPath` hides the button instead.
    @State private var previewTarget: PreviewTarget?
    @State private var preservingHistoryPosition = false
    /// Height of the composer dock (notices + attachments + capsule), used to
    /// keep the newest transcript row above it on iOS 17.
    @State private var composerDockHeight: CGFloat = 0
    /// Bumped by the send button so the transcript can scroll after layout.
    @State private var sendScrollTick = 0
    /// A haptic turn is one this page sent; opening history must stay quiet.
    @State private var hapticTurnActive = false
    /// One coalesced autoscroll at a time. A streamed answer changes its
    /// height on every delta; calling `scrollTo` synchronously from every
    /// `onChange` keeps the stack re-measuring while the keyboard is also
    /// changing the viewport.
    @State private var transcriptScrollTask: Task<Void, Never>?
    /// The newest requested scroll target. A running task reads this box
    /// instead of cancelling and restarting for every delta; cancelling the
    /// previous 120ms sleep on each token starved the scroll until the stream
    /// paused, so a late Markdown/code/card height was never corrected.
    @State private var transcriptScrollRequest = BotTranscriptScrollRequest()
    /// Eager mode renders a bounded suffix of the loaded rows; this expands
    /// when the reader asks for older loaded rows.
    @State private var eagerRowLimit = 40
    /// Scroll metrics live in a plain class: the tail probe runs during layout
    /// and must not dirty the graph with `@State` writes on every scroll frame.
    @State private var scrollMetrics = BotTranscriptScrollMetrics()
    /// Only follow new content while the reader is at the tail. A drag away
    /// stops the autoscroll; coming back re-enables it.
    @State private var followsTail = true
    @State private var userScrolling = false
    /// In an eager stack the history loader is always mounted, so `onAppear`
    /// no longer means "the reader reached the top". A one-shot visibility
    /// check restores the old auto-page without paging off-screen history.
    @State private var historyAutoLoadScheduled = false
    /// The composer owns the draft, but the transcript's tap-to-dismiss needs
    /// to clear the same focus flag; otherwise the field can believe it is
    /// focused after the responder resigned and not reopen on the next tap.
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: BotChatModel, isMainBot: Bool = false,
         cardActions: BotCardActions = BotCardActions(),
         onOpenInfo: @escaping () -> Void = {},
         onOpenInfoSection: @escaping (BotInfoSection) -> Void = { _ in },
         onSelectBot: @escaping (String) -> Void = { _ in },
         peerAppearance: @escaping (String) -> BotFishAppearance? = { _ in nil },
         peerIsMainBot: @escaping (String) -> Bool = { _ in false },
         initialComposerFocus: Bool = false,
         initialComposerText: String = "",
         transcriptProbe: BotTranscriptRenderProbe? = nil,
         peerReaction: @escaping (String) -> BotFishReaction? = { _ in nil },
         openDrawer: (() -> Void)? = nil,
         hasOnlineDevices: Bool = false,
         onConnectDevice: @escaping () -> Void = {},
         handleExternalDeepLink: @escaping (URL) -> Bool = { _ in false },
         openDocument: ((BotUIRow) -> Void)? = nil,
         initialAttachments: [BotDraftAttachment] = [],
         initialAttachmentNotice: String? = nil) {
        self.model = model
        self.cardActions = cardActions
        self.onOpenInfo = onOpenInfo
        self.onOpenInfoSection = onOpenInfoSection
        self.hasOnlineDevices = hasOnlineDevices
        self.onConnectDevice = onConnectDevice
        self.externalDocumentAction = openDocument
        self.isMainBot = isMainBot
        self.onSelectBot = onSelectBot
        self.initialComposerFocus = initialComposerFocus
        self.initialComposerText = initialComposerText
        self.transcriptProbe = transcriptProbe
        self.initialAttachments = initialAttachments
        self.initialAttachmentNotice = initialAttachmentNotice
        self.peerAppearance = peerAppearance
        self.peerIsMainBot = peerIsMainBot
        self.peerReaction = peerReaction
        self.handleExternalDeepLink = handleExternalDeepLink
        self.openDrawer = openDrawer
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
                .overlay(alignment: .top) { headerStatus }
            composerDock
        }
        .background(HomeSpec.page.ignoresSafeArea())
        .onPreferenceChange(BotComposerDockHeightKey.self) { height in
            composerDockHeight = height
        }
        .sheet(item: $sourceRow) { row in
            BotSourceSheet(row: row)
        }
        .sheet(item: $documentRow) { row in
            BotDocumentPreview(row: row)
        }
        .sheet(item: $previewTarget) { target in
            BotFilePreviewSheet(target: target)
        }
        .alert("无法定位消息", isPresented: Binding(
            get: { model.deepLinkError != nil },
            set: { if !$0 { model.deepLinkError = nil } }
        )) {
            Button("好", role: .cancel) { model.deepLinkError = nil }
        } message: {
            Text(model.deepLinkError ?? "")
        }
        .onOpenURL { url in
            if !model.openDeepLink(url), handleExternalDeepLink(url) {
                model.deepLinkError = nil
            }
        }
        .onAppear { model.noteInteraction() }
    }

    /// Grok-style Bot header: one centered avatar+name capsule, and the DSH
    /// page's own 92×44 device/menu capsule on the trailing side. The leading
    /// spacer mirrors the trailing capsule so the Bot capsule is centered on
    /// the screen and can never grow under the menu.
    private var header: some View {
        HStack(spacing: 0) {
            if let openDrawer {
                Button(action: openDrawer) {
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().frame(width: 18, height: 2.4)
                        Capsule().frame(width: 12, height: 2.4)
                    }
                    .foregroundStyle(HomeSpec.primaryButton)
                    .frame(width: HomeSpec.navButton, height: HomeSpec.navButton)
                    .background(HomeSpec.surface, in: Circle())
                    .homeFloatingShadow()
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开 Bot 列表")
                .accessibilityIdentifier("bot.drawer.open")
                Color.clear
                    .frame(width: HomeSpec.navPillWidth - HomeSpec.navButton, height: 1)
                    .accessibilityHidden(true)
            } else {
                Color.clear
                    .frame(width: HomeSpec.navPillWidth, height: 1)
                    .accessibilityHidden(true)
            }
            Button {
                model.noteInteraction()
                onOpenInfo()
            } label: {
                HStack(spacing: 8) {
                    // The only avatar on screen: its state, motion profile
                    // and work style come from the same header lifecycle as
                    // the status line under it.
                    BotFishView(state: presence.fishState, size: 32, appearance: model.appearance,
                                crowned: isMainBot, reaction: model.reaction,
                                motionProfile: presence.motion,
                                workStyle: presence.workStyle)
                    Text(model.botName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 6)
                .padding(.trailing, 14)
                .frame(height: HomeSpec.navButton)
                .background(HomeSpec.surface, in: Capsule())
                .homeFloatingShadow()
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Bot 信息")
            .accessibilityIdentifier("bot.info.open")
            .frame(maxWidth: .infinity)

            HeaderActionPill(hasOnlineDevices: hasOnlineDevices,
                             connectIdentifier: "bot.connect-device",
                             menuIdentifier: "bot.header.menu",
                             showsMenuActivityDot: false,
                             onConnect: {
                                 model.noteInteraction()
                                 onConnectDevice()
                             }) {
                headerMenuItems
            }
        }
        .padding(.horizontal, HomeSpec.chromeInset)
        .padding(.top, HomeSpec.navTop)
        .frame(height: HomeSpec.navTop + HomeSpec.navButton)
        .background(HomeSpec.page)
        .accessibilityElement(children: .contain)
    }

    /// One lifecycle for the whole header: fish state, motion and the status
    /// line all read this value, so they always change together.
    private var presence: BotHeaderPresence {
        BotHeaderPresence.resolve(turnActive: model.showsActivityLine,
                                  lineActivity: model.lineActivity,
                                  pendingApprovals: model.pendingApprovalCount,
                                  fishState: model.fishState,
                                  problem: model.runtimeNotice)
    }

    /// One centered status line right under the header capsule. It floats
    /// over the top of the transcript on a page-colored fade instead of
    /// taking layout space, so showing or hiding it never moves a message.
    private var headerStatus: some View {
        ZStack(alignment: .top) {
            if let activity = presence.line {
                BotActivityLine(activity: activity, quiet: presence.lineIsQuiet,
                                problem: presence.lineIsProblem)
                    .padding(.top, 4)
                    .padding(.bottom, 14)
                    .background(alignment: .top) {
                        LinearGradient(
                            stops: [
                                .init(color: HomeSpec.page, location: 0),
                                .init(color: HomeSpec.page, location: 0.55),
                                .init(color: HomeSpec.page.opacity(0), location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom)
                    }
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.25), value: presence.line != nil)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var headerMenuItems: some View {
        Text("跟进中 \(model.followingCount) · 需要你处理 \(model.needsAttentionCount)")
        Divider()
        Button("Bot 信息与设置", systemImage: "person.crop.circle") {
            openInfo(nil)
        }
        Button("记忆", systemImage: "brain") {
            openInfo(.memory)
        }
        Button("例行任务", systemImage: "repeat") {
            openInfo(.routines)
        }
        Button("审批记录", systemImage: "checkmark.shield") {
            openInfo(.approvals)
        }
    }

    private func openInfo(_ section: BotInfoSection?) {
        model.noteInteraction()
        if let section {
            onOpenInfoSection(section)
        } else {
            onOpenInfo()
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                transcriptStack(proxy: proxy)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(
                                key: BotTranscriptContentHeightPreference.self,
                                value: content.size.height)
                        }
                    }
                    // Room for the header status line, reserved at all times
                    // so the floating line never shifts the transcript when
                    // it shows or hides (#132).
                    .padding(.top, HomeSpec.blockGap + 14)
                    .padding(.bottom, 16)
            }
            .coordinateSpace(name: "bot-transcript")
            // A short transcript (first send, a one-line reply) must sit at
            // the bottom like the main chat, not at the top with a huge blank
            // band between it and the composer. This is the layout half of
            // the "message pushed up / empty page" report; the short-content
            // scroll guard above is the other half.
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .modifier(BotTranscriptViewportReader(metrics: scrollMetrics) { height in
                // The keyboard is the dominant viewport change: it does not
                // alter the composer dock's own height, so the dock trigger
                // alone left the newest card under the keyboard. Follow the
                // tail when the visible transcript grows or shrinks.
                guard height > 0 else { return }
                followNewestContent(proxy: proxy)
            })
            .modifier(BotTranscriptScrollPhaseObserver { phase in
                switch phase {
                case .userDriven:
                    userScrolling = true
                case .settled:
                    // `onScrollPhaseChange` reports `.idle` for programmatic
                    // `scrollTo` too. Treating that as a user scroll away from
                    // the tail turned following off after the page's own
                    // scroll (e.g. to a question card), so the *next* card —
                    // the approval card — was never brought above the
                    // keyboard. Only a real gesture may move the flag.
                    let wasUserDriven = userScrolling
                    userScrolling = false
                    if wasUserDriven { updateFollowsTail(userDriven: true) }
                case .other:
                    break
                }
            })
            .onPreferenceChange(BotTranscriptContentHeightPreference.self) { height in
                guard height.isFinite, height >= 0,
                      abs(scrollMetrics.contentHeight - height) > 0.5 else { return }
                scrollMetrics.contentHeight = height
                // A card/list that changes height without a row id change still
                // needs to re-evaluate the short-transcript guard and follow.
                if followsTail { followNewestContent(proxy: proxy) }
            }
            .onPreferenceChange(BotTranscriptTailPreference.self) { tailY in
                guard tailY.isFinite else { return }
                scrollMetrics.tailY = tailY
                if userScrolling {
                    updateFollowsTail(userDriven: true)
                } else if !followsTail,
                          BotTranscriptLayoutSupport.isNearTail(
                              tailY: tailY,
                              viewportHeight: scrollMetrics.viewportHeight,
                              tolerance: 24) {
                    // A programmatic scroll can land on the tail without a
                    // user-driven settle. Re-arm following when the transcript
                    // is actually at the bottom again; otherwise a single
                    // stale false would silently stop all future streaming
                    // scrolls (the Bot page has no "back to latest" pill).
                    followsTail = true
                } else if followsTail, tailY < -1 {
                    // The viewport is past the content tail: the page is
                    // blank and the rows were pushed up. Re-anchor once the
                    // real content height is known, with a small retry cap so
                    // an unmeasured/unscrollable page cannot spin.
                    if abs(scrollMetrics.blankCorrectionContentHeight
                           - scrollMetrics.contentHeight) > 0.5 {
                        scrollMetrics.blankCorrectionContentHeight = scrollMetrics.contentHeight
                        scrollMetrics.blankCorrectionAttempts = 0
                    }
                    if scrollMetrics.blankCorrectionAttempts < 2,
                       Date().timeIntervalSince(scrollMetrics.lastBlankCorrectionAt) > 0.25 {
                        scrollMetrics.blankCorrectionAttempts += 1
                        scrollMetrics.lastBlankCorrectionAt = Date()
                        if BotTranscriptLayoutSupport.shouldScrollToTail(
                            contentHeight: scrollMetrics.contentHeight,
                            viewportHeight: scrollMetrics.viewportHeight) {
                            proxy.scrollTo("bot-transcript-tail", anchor: .bottom)
                        } else if let first = model.displayRows.first?.id {
                            proxy.scrollTo(first, anchor: .top)
                        }
                    }
                } else if tailY >= -1 {
                    scrollMetrics.blankCorrectionAttempts = 0
                    scrollMetrics.blankCorrectionContentHeight = 0
                }
            }
            .onChange(of: model.visibleRows.last?.id) { _, last in
                guard !preservingHistoryPosition, model.scrollRequestID == nil,
                      last != nil else { return }
                followNewestContent(proxy: proxy)
            }
            .onChange(of: liveScrollKey) { _, key in
                guard key != nil else { return }
                followNewestContent(proxy: proxy)
            }
            .onChange(of: model.streamingText) { _, value in
                guard let value, !value.isEmpty else { return }
                followNewestContent(proxy: proxy)
            }
            // #132's two extra keep-the-newest-row triggers run through the
            // same tail guard and 120ms coalescing as the streaming path:
            // the composer growing and the send echo both scroll once.
            .onChange(of: composerDockHeight, initial: true) { _, _ in
                followNewestContent(proxy: proxy)
            }
            .onChange(of: sendScrollTick) { _, _ in
                // A send is an explicit "show me the new turn": re-arm the
                // tail even if a previous tap/drag had turned following off.
                followsTail = true
                hapticTurnActive = true
                PhoneHaptics.thinking()
                followNewestContent(proxy: proxy)
            }
            .onChange(of: model.runningTurnID) { _, running in
                if running != nil, hapticTurnActive {
                    // The send cue may have fired a moment earlier; the
                    // generator debounces it. If the send path missed, this
                    // turn-start observer is the reliable cue.
                    PhoneHaptics.thinking()
                } else if running == nil, hapticTurnActive {
                    hapticTurnActive = false
                    PhoneHaptics.completed()
                }
            }
            .onChange(of: model.pendingApprovalCount) { _, count in
                if count > 0 { PhoneHaptics.approval() }
            }
            // #132 settled cards: once a handled card collapses into its
            // one-line summary (or an older card is skipped by the next user
            // message) the content gets shorter. Wait for the 0.25s collapse
            // animation, then give the shorter transcript one more scroll
            // through the same coalesced tail path. The status line floats
            // over the transcript and reserves its 14pt at all times, so its
            // show/hide is deliberately not a scroll trigger.
            .onChange(of: model.settledRowIDs) { _, _ in
                followNewestContent(proxy: proxy,
                                    delay: reduceMotion ? 0 : 300_000_000)
            }
            .onChange(of: model.scrollRequestID) { _, rowID in
                guard let rowID else { return }
                followsTail = true
                withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(rowID, anchor: .center) }
                model.scrollRequestID = nil
            }
            .onChange(of: model.hasMoreHistory) { _, hasMore in
                if !hasMore { historyAutoLoadScheduled = false }
            }
        }
        // Same as DSH: a tap anywhere in the transcript, blank space
        // included, hands the keyboard back and wakes an idle fish.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            model.noteInteraction()
            composerFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
        })
        .accessibilityIdentifier("bot.chat.transcript")
        .onDisappear {
            transcriptScrollTask?.cancel()
            transcriptScrollTask = nil
        }
    }

    /// The default is an eager stack: exact row heights, no lazy estimate /
    /// placement feedback. `PDSH_BOT_TRANSCRIPT_STACK=lazy` keeps the old
    /// container for a same-build A/B sample.
    @ViewBuilder
    private func transcriptStack(proxy: ScrollViewProxy) -> some View {
        switch BotTranscriptStackMode.current {
        case .eager:
            VStack(spacing: 0) { transcriptContent(proxy: proxy) }
        case .lazy:
            LazyVStack(spacing: 0) { transcriptContent(proxy: proxy) }
        }
    }

    @ViewBuilder
    private func transcriptContent(proxy: ScrollViewProxy) -> some View {
        let window = transcriptWindow
        if window.hidden > 0 {
            historySentinel(proxy: proxy, expandWindow: true, anchor: window.rows.first?.id)
        } else if model.hasMoreHistory {
            // A passive top sentinel, not a button. It only pages when the
            // reader actually reaches the top; the eager VStack mounts it on
            // every launch, so visibility is the trigger, not `onAppear`.
            historySentinel(proxy: proxy, expandWindow: false,
                            anchor: model.visibleRows.first?.id)
        }
        if isEmpty {
            // The old outer `GeometryReader` made the whole transcript subtree
            // depend on the keyboard/safe-area height just for this empty
            // state. `containerRelativeFrame` measures the container without
            // wrapping the scroll view in a geometry-invalidating layer.
            emptyState
                .containerRelativeFrame(.vertical) { height, _ in
                    max(0, height - HomeSpec.blockGap - 16)
                }
                .accessibilityIdentifier("bot.chat.empty")
        }
        // #126: the transcript only shows user messages, answers, cards and
        // agent-comm rows. Finished process rows and live tool rows are gone;
        // the activity line above the composer carries the running phase.
        ForEach(window.rows) { row in
            transcriptRow(row)
                .id(row.id)
        }
        if let live = model.live {
            BotLiveTurnView(live: live)
            Color.clear.frame(height: 1).id("bot-live-tail")
        }
        if let streaming = model.streamingText {
            BotStreamingRow(text: streaming)
                .id("bot-live-stream")
        }
        // One-point tail probe: its minY in the scroll container's coordinate
        // space tells the page whether the reader is still at the tail. It
        // writes a plain value in the preference callback, never view state.
        Color.clear
            .frame(height: 1)
            .id("bot-transcript-tail")
            .background {
                GeometryReader { tail in
                    Color.clear.preference(
                        key: BotTranscriptTailPreference.self,
                        value: tail.frame(in: .named("bot-transcript")).minY)
                }
            }
    }

    /// Eager mode is bounded: render the most recent loaded rows. Older loaded
    /// rows are still in the model, and the runtime paging (`hasMoreHistory`)
    /// is untouched; both stay reachable through the top affordance.
    private var transcriptWindow: (rows: [BotUIRow], hidden: Int) {
        BotTranscriptLayoutSupport.window(model.displayRows, limit: eagerRowLimit,
                                          eager: BotTranscriptStackMode.current == .eager)
    }

    /// Top sentinel. Scrolling it into view expands the rendered window or
    /// asks the runtime for one more history page; the user never has to tap
    /// a "load earlier" button. A batch stays bounded (40 rendered / 50
    /// runtime rows) so opening a long Bot session does not build the whole
    /// transcript.
    private func historySentinel(proxy: ScrollViewProxy, expandWindow: Bool,
                                 anchor: String?) -> some View {
        HStack(spacing: 6) {
            if model.loadingHistory || historyAutoLoadScheduled {
                ProgressView().controlSize(.mini)
            }
            Text(expandWindow ? "正在加载更早消息" : "正在加载历史")
                .botCaptionFont()
                .foregroundStyle(HomeSpec.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 36)
        .accessibilityIdentifier("bot.history.loader")
        .onGeometryChange(for: CGFloat.self, of: { row in
            row.frame(in: .named("bot-transcript")).maxY
        }) { maxY in
            historyTopFrameChanged(maxY, proxy: proxy,
                                   expandWindow: expandWindow, anchor: anchor)
        }
    }

    /// Bring the newest *actionable* row (a pending approval or a question
    /// card) above the keyboard. The same turn's streamed text is mounted after
    /// the durable rows, so a plain tail scroll would cover the card with text
    /// that arrived before it. Only when there is no such card does the tail
    /// win.
    private func followNewestContent(proxy: ScrollViewProxy,
                                     delay: UInt64 = 120_000_000) {
        if let card = model.newestActionableCard {
            scheduleTranscriptScroll(proxy: proxy, to: AnyHashable(card.id),
                                     anchor: .bottom, delay: delay)
        } else {
            scheduleTranscriptScroll(proxy: proxy, to: AnyHashable("bot-transcript-tail"),
                                     anchor: .bottom, delay: delay)
        }
    }

    /// Coalesce live-height changes into at most one scroll per UI turn, and
    /// only while the reader is at the tail. The live key includes the buffer
    /// length, so without this every streamed character would start another
    /// placement pass; with the keyboard open that was enough to keep the
    /// transcript busy indefinitely. `delay` lets the settled-card collapse
    /// animation finish before the one post-collapse scroll.
    private func scheduleTranscriptScroll(proxy: ScrollViewProxy, to id: AnyHashable,
                                          anchor: UnitPoint,
                                          delay: UInt64 = 120_000_000) {
        guard followsTail, !preservingHistoryPosition, model.scrollRequestID == nil else { return }
        // A short transcript has nothing to scroll to: a bottom-anchored
        // scroll on it pushes the rows up under a blank band. This is the Bug
        // where sending the first message (or a short new turn) made the page
        // look empty. Wait until the content actually overflows.
        guard BotTranscriptLayoutSupport.shouldScrollToTail(
            contentHeight: scrollMetrics.contentHeight,
            viewportHeight: scrollMetrics.viewportHeight,
            hasRows: !model.displayRows.isEmpty || model.streamingText != nil || model.live != nil)
        else { return }
        // The newest trigger replaces the target, but it must not restart the
        // pending sleep. The run below reads this box on every pass, so a
        // continuous stream gets one scroll per settle window instead of a
        // sleep that is cancelled before it can fire.
        transcriptScrollRequest.target = id
        transcriptScrollRequest.anchor = anchor
        transcriptScrollRequest.generation &+= 1
        guard transcriptScrollTask == nil else { return }
        transcriptScrollTask = Task { @MainActor in
            defer { transcriptScrollTask = nil }
            var arrivedGeneration: UInt64 = 0
            var corrected = false
            var first = true
            while !Task.isCancelled {
                let wait = first ? delay : 180_000_000
                first = false
                if wait > 0 { try? await Task.sleep(nanoseconds: wait) }
                guard !Task.isCancelled, followsTail, !preservingHistoryPosition,
                      model.scrollRequestID == nil else { return }
                let generation = transcriptScrollRequest.generation
                if generation == arrivedGeneration {
                    // The last pass already covered this content. One more
                    // settle window catches a Markdown/code/card height that
                    // lands after the scroll; then stop until new content.
                    if corrected { return }
                    corrected = true
                } else {
                    arrivedGeneration = generation
                    corrected = false
                }
                proxy.scrollTo(transcriptScrollRequest.target,
                               anchor: transcriptScrollRequest.anchor)
            }
        }
    }

    /// Near means the tail probe sits at or just above the viewport bottom.
    /// The value is only applied on user-driven scroll transitions, so a
    /// keyboard/composer resize cannot turn following off.
    private func updateFollowsTail(userDriven: Bool) {
        guard let next = BotTranscriptLayoutSupport.updatedFollowsTail(
            current: followsTail,
            userDriven: userDriven,
            tailY: scrollMetrics.tailY,
            viewportHeight: scrollMetrics.viewportHeight
        ) else { return }
        if next != followsTail { followsTail = next }
    }

    private var isEmpty: Bool {
        model.displayRows.isEmpty && model.streamingText == nil && model.live == nil
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            BotFishView(state: model.fishState, size: 96, appearance: model.appearance,
                        crowned: isMainBot, allowsPoke: true, reaction: model.reaction)
            Text("嗨，我是 \(model.botName)")
                .botFont(size: 15, lineHeight: 22, weight: .semibold, style: .body)
                .foregroundStyle(HomeSpec.textPrimary)
            Text("我可以处理任务、整理文件和查找资料。\n想让我帮你做什么？")
                .botFont(size: 13, lineHeight: 18, style: .body)
                .foregroundStyle(HomeSpec.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, HomeSpec.contentInset)
        .padding(.vertical, 24)
    }

    private var resolvedCardActions: BotCardActions {
        var actions = cardActions
        actions.openDocument = externalDocumentAction ?? { row in documentRow = row }
        // An injected handler owns a path only when it also declares the
        // capability. Otherwise the host's native preview is the fallback, and
        // a path it cannot resolve stays unrepresented instead of becoming a
        // dead button.
        let externalCanOpen = cardActions.canOpenPath
        let externalOpenPath = cardActions.openPath
        actions.canOpenPath = { path in
            externalCanOpen(path) || BotCardFileAccess.canOpen(path)
        }
        actions.openPath = { path in
            if externalCanOpen(path) {
                externalOpenPath(path)
            } else if BotCardFileAccess.canOpen(path) {
                previewTarget = .workspaceFile(path)
            }
        }
        return actions
    }

    private var composerDock: some View {
        BotComposerDock(model: model,
                        focus: $composerFocused,
                        initialComposerFocus: initialComposerFocus,
                        initialComposerText: initialComposerText,
                        initialAttachments: initialAttachments,
                        initialAttachmentNotice: initialAttachmentNotice,
                        onSend: { sendScrollTick &+= 1 })
    }

    private var liveScrollKey: String? {
        model.live.map { live in
            "\(live.segments.count):\(live.buffer.count):\(live.ended)"
        }
    }

    private func transcriptRow(_ row: BotUIRow) -> some View {
        BotTranscriptRow(row: row, model: model, actions: resolvedCardActions,
                         sourceRow: $sourceRow, onSelectBot: onSelectBot,
                         peerAppearance: peerAppearance,
                         peerIsMainBot: peerIsMainBot,
                         peerReaction: peerReaction,
                         renderProbe: transcriptProbe)
    }

    /// One auto-page per top arrival. The small defer lets the viewport
    /// report its first height; the load itself runs outside layout. After a
    /// page/window step the old anchor is put back at the top, which moves the
    /// sentinel above the viewport and prevents a same-frame loop.
    private func historyTopFrameChanged(_ maxY: CGFloat, proxy: ScrollViewProxy,
                                        expandWindow: Bool, anchor: String?) {
        guard model.hasMoreHistory || expandWindow,
              !historyAutoLoadScheduled, !model.loadingHistory,
              maxY.isFinite, maxY >= -1,
              maxY <= scrollMetrics.viewportHeight + 1 else { return }
        historyAutoLoadScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard historyAutoLoadScheduled else { return }
            guard !model.loadingHistory else {
                historyAutoLoadScheduled = false
                return
            }
            if expandWindow {
                eagerRowLimit += 40
                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
            } else {
                await model.loadHistory()
                // Let the prepended rows mount before re-anchoring the old
                // first row; otherwise the lazy placement can jump.
                try? await Task.sleep(nanoseconds: 30_000_000)
                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
            historyAutoLoadScheduled = false
        }
    }

}

/// The composer owns the draft, the focus and the attachment tray. Keeping
/// those in their own view is what stops a keystroke (and the field growing
/// from one to five lines) from re-evaluating the whole transcript subtree:
/// the field changes at typing speed, and the dense card rows are exactly the
/// work the page must not repeat per character.
private struct BotComposerDock: View {
    @ObservedObject var model: BotChatModel
    var focus: FocusState<Bool>.Binding
    let initialComposerFocus: Bool
    /// Main's #126 scroll contract: after a send, let the local echo and the
    /// activity line lay out, then scroll the transcript once.
    var onSend: () -> Void = {}

    @State private var draft: String
    @State private var pendingAttachments: [BotDraftAttachment]
    @State private var attachmentNotice: String?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false

    init(model: BotChatModel, focus: FocusState<Bool>.Binding,
         initialComposerFocus: Bool, initialComposerText: String,
         initialAttachments: [BotDraftAttachment], initialAttachmentNotice: String?,
         onSend: @escaping () -> Void = {}) {
        self.model = model
        self.focus = focus
        self.initialComposerFocus = initialComposerFocus
        self.onSend = onSend
        _draft = State(initialValue: initialComposerText)
        _pendingAttachments = State(initialValue: initialAttachments)
        _attachmentNotice = State(initialValue: initialAttachmentNotice)
    }

    var body: some View {
        VStack(spacing: 8) {
            // Failures are reported once, on the header status line; the
            // composer carries no notice of its own.
            attachmentTray
            // Grok-style composer: one white r26 rounded card with the 36pt
            // attach button leading, the growing text field in the middle,
            // and one 36pt send/stop button trailing. Unlike a Capsule, the
            // 26pt corner stays put when the field wraps to five lines, so
            // the bottom-aligned buttons never land on the curved edge. No
            // microphone and no voice mode.
            BotComposerLayout {
                Menu {
                    Button {
                        model.noteInteraction()
                        showPhotos = true
                    } label: {
                        Label("照片", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        model.noteInteraction()
                        showFiles = true
                    } label: {
                        Label("文件", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(HomeSpec.userBubble, in: Circle())
                        .contentShape(Circle())
                }
                .accessibilityLabel("添加附件")
                .accessibilityIdentifier("bot.composer.attach")

                TextField("向 \(model.botName) 提问", text: $draft, axis: .vertical)
                    .font(.system(size: HomeSpec.bodySize))
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused(focus)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("bot.composer.input")
                composerActionButton
            }
            .frame(minHeight: 52)
            .background(HomeSpec.surface,
                        in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
            .homeComposerShadow()
            .simultaneousGesture(TapGesture().onEnded { model.noteInteraction() })
        }
        .padding(.horizontal, HomeSpec.chromeInset)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(HomeSpec.page)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: BotComposerDockHeightKey.self,
                                   value: proxy.size.height)
        })
        .accessibilityElement(children: .contain)
        .onChange(of: draft) { _, _ in model.noteInteraction() }
        .task {
            // Fixture-only keyboard precondition. The capture interaction test
            // taps the field itself; this hook exists so the keyboard-open
            // layout can be sampled from a plain simctl launch as well.
            guard initialComposerFocus else { return }
            try? await Task.sleep(for: .milliseconds(350))
            focus.wrappedValue = true
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems,
                      maxSelectionCount: BotAttachmentPolicy.maxCount, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.data],
                      allowsMultipleSelection: true) { result in
            importPickedFiles(result)
        }
    }

    /// Chips for the files waiting to be sent, plus the one-line refusal for a
    /// file that was too large, over the count limit, or unreadable.
    @ViewBuilder
    private var attachmentTray: some View {
        if !pendingAttachments.isEmpty || attachmentNotice != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !pendingAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(pendingAttachments) { item in
                                attachmentChip(item, index: pendingAttachments.firstIndex(of: item) ?? 0)
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                    }
                    .frame(height: 46)
                }
                if let attachmentNotice {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 12))
                        Text(attachmentNotice)
                            .font(.system(size: 12))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { self.attachmentNotice = nil } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭附件提示")
                    }
                    .foregroundStyle(BotUIPalette.danger)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("bot.composer.attachment.notice")
                }
            }
        }
    }

    private func attachmentChip(_ item: BotDraftAttachment, index: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.attachment.iconName)
                .font(.system(size: 13))
                .foregroundStyle(HomeSpec.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.attachment.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(HomeSpec.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.attachment.sizeLabel) · \(item.attachment.kindLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(HomeSpec.textTertiary)
            }
            .frame(maxWidth: 150, alignment: .leading)
            Button {
                pendingAttachments.removeAll { $0.id == item.id }
                model.noteInteraction()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除附件 \(item.attachment.name)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 44)
        .background(HomeSpec.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bot.composer.attachment.\(index)")
    }

    private func importPickedFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            attachmentNotice = "无法读取所选文件：\(error.localizedDescription)"
        case .success(let urls):
            var refusals: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("phone-dsh-bot-attachments", isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(
                    "\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                } catch {
                    refusals.append("附件「\(url.lastPathComponent)」未附加：\(error.localizedDescription)")
                    continue
                }
                if let refusal = addDraftAttachment(url: destination, displayName: url.lastPathComponent) {
                    refusals.append(refusal)
                }
            }
            attachmentNotice = refusals.isEmpty ? nil : refusals.joined(separator: "\n")
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        var refusals: [String] = []
        let stamp = Int(Date().timeIntervalSince1970)
        for (offset, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                refusals.append("附件「照片 \(offset + 1)」未附加：无法读取所选照片。")
                continue
            }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let name = "photo-\(stamp)-\(offset + 1).\(ext)"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            do {
                try data.write(to: url)
            } catch {
                refusals.append("附件「\(name)」未附加：\(error.localizedDescription)")
                continue
            }
            if let refusal = addDraftAttachment(url: url, displayName: name,
                                                fallbackMIMEType: type?.preferredMIMEType) {
                refusals.append(refusal)
            }
        }
        attachmentNotice = refusals.isEmpty ? nil : refusals.joined(separator: "\n")
        photoItems = []
    }

    /// Returns a refusal message instead of appending when the count or size
    /// limit is exceeded; the message is shown immediately and the item is not
    /// added, matching the DSH Bot composer.
    private func addDraftAttachment(url: URL, displayName: String,
                                    fallbackMIMEType: String? = nil) -> String? {
        guard pendingAttachments.count < BotAttachmentPolicy.maxCount else {
            return "附件「\(displayName)」未附加：每条消息最多 \(BotAttachmentPolicy.maxCount) 个附件。"
        }
        guard let attachment = BotUIAttachment.local(url: url, fallbackMIMEType: fallbackMIMEType) else {
            return "附件「\(displayName)」未附加：文件为空或无法读取。"
        }
        guard attachment.size <= BotAttachmentPolicy.maxBytes else {
            return "附件「\(displayName)」未附加：文件超过 25 MiB（\(attachment.sizeLabel)）。"
        }
        var named = attachment
        named.name = displayName
        pendingAttachments.append(BotDraftAttachment(url: url, attachment: named))
        model.noteInteraction()
        return nil
    }

    /// Exactly one round button with three states: send (idle, disabled when
    /// empty), stop (running with an empty draft), send-and-steer (running
    /// with text). The send id is stable so the capture tests can drive it.
    @ViewBuilder
    private var composerActionButton: some View {
        if model.runningTurnID != nil && !canSend {
            Button { model.stop() } label: {
                BotComposerGlyph(systemImage: "stop.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("停止当前回合")
            .accessibilityIdentifier("bot.composer.stop")
        } else {
            Button(action: send) {
                BotComposerGlyph(systemImage: "arrow.up", enabled: canSend)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(model.runningTurnID != nil ? "发送并 steering" : "发送消息")
            .accessibilityIdentifier("bot.composer.send")
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = pendingAttachments.map(\.url)
        guard !text.isEmpty || !files.isEmpty else { return }
        draft = ""
        pendingAttachments = []
        attachmentNotice = nil
        model.send(text: text, files: files)
        onSend()
        focus.wrappedValue = true
    }
}

/// The composer dock's rendered height (notices and attachments included), so the
/// transcript can scroll when it grows or shrinks. Measured with
/// GeometryReader + PreferenceKey to stay on iOS 17.
private struct BotComposerDockHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Single-line capsule: the text field and the 36pt button share a center, so
/// the first text baseline and the button center line up. Once the field grows
/// past the 52pt capsule the button sticks to the bottom 8pt instead.
private struct BotComposerLayout: Layout {
    typealias Cache = Void

    private let inset: CGFloat = 8
    private let attachButton: CGFloat = 36
    private let gap: CGFloat = 4

    func makeCache(subviews: Subviews) -> Void {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let width = proposal.width ?? 0
        let inputWidth = max(0, width - inset - attachButton - gap - gap
                             - HomeSpec.sendButton - inset)
        let input = subviews[1].sizeThatFits(ProposedViewSize(width: inputWidth, height: nil))
        return CGSize(width: width, height: max(52, input.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        guard subviews.count == 3 else { return }
        let inputWidth = max(0, bounds.width - inset - attachButton - gap - gap
                             - HomeSpec.sendButton - inset)
        let input = subviews[1].sizeThatFits(ProposedViewSize(width: inputWidth, height: nil))
        let singleLine = input.height <= 52
        let controlY = singleLine
            ? bounds.minY + (bounds.height - attachButton) / 2
            : bounds.maxY - attachButton - inset
        let inputY = bounds.minY + max(0, (bounds.height - input.height) / 2)
        subviews[0].place(
            at: CGPoint(x: bounds.minX + inset, y: controlY),
            proposal: ProposedViewSize(width: attachButton, height: attachButton))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + inset + attachButton + gap, y: inputY),
            proposal: ProposedViewSize(width: inputWidth, height: input.height))
        subviews[2].place(
            at: CGPoint(x: bounds.maxX - inset - HomeSpec.sendButton, y: controlY),
            proposal: ProposedViewSize(width: HomeSpec.sendButton, height: HomeSpec.sendButton))
    }
}

/// One picked file waiting for the send button. `attachment` is the metadata
/// the transcript card and the import action use; `url` is the readable local
/// copy handed to `BotAttachmentImporting`.
struct BotDraftAttachment: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var attachment: BotUIAttachment

    init(id: UUID = UUID(), url: URL, attachment: BotUIAttachment) {
        self.id = id
        self.url = url
        self.attachment = attachment
    }

    static func fixture(name: String, size: Int64, mimeType: String, kind: String) -> BotDraftAttachment {
        BotDraftAttachment(
            url: URL(fileURLWithPath: "/tmp/phone-dsh-fixture/\(name)"),
            attachment: BotUIAttachment(name: name, size: size, mimeType: mimeType, kind: kind))
    }
}

private struct BotTranscriptRow: View {
    let row: BotUIRow
    @ObservedObject var model: BotChatModel
    let actions: BotCardActions
    @Binding var sourceRow: BotUIRow?
    let onSelectBot: (String) -> Void
    let peerAppearance: (String) -> BotFishAppearance?
    let peerIsMainBot: (String) -> Bool
    let peerReaction: (String) -> BotFishReaction?
    let renderProbe: BotTranscriptRenderProbe?

    var body: some View {
        let _ = renderProbe?.note(row.id)
        Group {
            if let comm = BotAgentCommRendering.presentation(for: row) {
                BotAgentCommRow(presentation: comm,
                                appearance: comm.peerID.flatMap(peerAppearance),
                                crowned: comm.peerID.map(peerIsMainBot) ?? false,
                                reaction: comm.peerID.flatMap(peerReaction),
                                onSelectBot: onSelectBot)
                    .padding(.horizontal, HomeSpec.contentInset)
                    .padding(.vertical, HomeSpec.blockGap / 2)
            } else if row.body.type == "text" {
                BotTextRow(row: row)
            } else if let card = BotUICardContent.parse(row: row) {
                BotCardView(row: row, card: card, model: model, actions: actions)
                    .padding(.horizontal, HomeSpec.contentInset)
                    .padding(.vertical, HomeSpec.blockGap / 2)
            }
        }
        .contextMenu {
            Button("复制") { UIPasteboard.general.string = BotUIRendering.copyText(row) }
            Button("查看来源") { sourceRow = row }
        }
    }
}

/// The minimal agent-comm line. Outbound/reply/inbound rows from
/// `agent.comm` collapse into one readable sentence plus a small peer avatar;
/// tapping the peer switches to that Bot. Full visuals are the sidebar wave.
private struct BotAgentCommRow: View {
    let presentation: BotAgentCommPresentation
    let appearance: BotFishAppearance?
    let crowned: Bool
    let reaction: BotFishReaction?
    let onSelectBot: (String) -> Void

    private var icon: String {
        switch presentation.tone {
        case .outbound: return "arrow.up.right"
        case .inbound: return "arrow.down.left"
        case .incoming: return "tray.and.arrow.down"
        case .reply: return "arrowshape.turn.up.left"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        presentation.tone == .failed ? BotUIPalette.danger : HomeSpec.textSecondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let appearance {
                BotFishView(state: .idle, size: 28, appearance: appearance,
                            crowned: crowned, still: true, reaction: reaction)
            } else {
                Image(systemName: "person.2")
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(HomeSpec.userBubble, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                    Text(presentation.text)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                        .lineLimit(1)
                }
                if let detail = presentation.detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(tint)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = presentation.peerID { onSelectBot(id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel([presentation.text, presentation.detail ?? ""].joined(separator: "，"))
        .accessibilityIdentifier("bot.agent-comm.row")
    }
}

private struct BotTextRow: View {
    let row: BotUIRow
    private var isUser: Bool { row.role == "user" }
    private var text: String { row.body["text"]?.string ?? "" }
    private var attachments: [BotUIAttachment] {
        isUser ? BotUIAttachment.parseList(row.body["attachments"]) : []
    }

    /// DSH message rows: the user's words in the gray bubble (80% width,
    /// top-trailing corner square), the Bot's answer as the DSH markdown body;
    /// rows sit 20pt apart. Attached files are cards under the user's words,
    /// inside the same bubble and column.
    var body: some View {
        Group {
            if isUser {
                BotAdaptiveBubbleLayout(ratio: 0.8, trailing: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !text.isEmpty {
                            Text(text)
                                .font(NativeChatTheme.bodyFont())
                                .lineSpacing(NativeChatTheme.bodyLineSpacing)
                                .foregroundStyle(HomeSpec.textPrimary)
                                .textSelection(.enabled)
                        }
                        ForEach(attachments) { attachment in
                            BotUserAttachmentCard(attachment: attachment)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(HomeSpec.userBubble, in: HomeSpec.bubbleShape)
                }
            } else {
                BotAnswerBubbleContent(text: text, streaming: false)
            }
        }
        .padding(.horizontal, HomeSpec.contentInset)
        .padding(.vertical, HomeSpec.blockGap / 2)
    }
}

/// The user row's attached-file card: name, size and kind, matching the DSH
/// Bot transcript attachment row without adding a second card style.
private struct BotUserAttachmentCard: View {
    let attachment: BotUIAttachment

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.iconName)
                .font(.system(size: 15))
                .foregroundStyle(HomeSpec.textPrimary)
                .frame(width: 32, height: 32)
                .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(HomeSpec.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(attachment.sizeLabel) · \(attachment.kindLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(HomeSpec.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(attachment.name)，\(attachment.sizeLabel)，\(attachment.kindLabel)")
        .accessibilityIdentifier("bot.message.attachment")
    }
}

/// The Bot's own words: the DSH markdown body inside a white bubble on the
/// leading side (top-leading corner square, hairline edge), capped at the same
/// 86% content width every Bot card uses.
private struct BotAnswerBubbleContent: View {
    let text: String
    let streaming: Bool

    /// An empty or whitespace-only chunk (the first delta is often just a
    /// newline) must not flash an empty bubble under the transcript.
    static func hasContent(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        BotContentWidth {
            NativeMarkdownBody(markdown: text, streaming: streaming, onOpenFile: { _ in })
                .font(NativeChatTheme.bodyFont())
                .lineSpacing(NativeChatTheme.bodyLineSpacing)
                .foregroundStyle(HomeSpec.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(HomeSpec.surface, in: HomeSpec.botBubbleShape)
                .overlay(HomeSpec.botBubbleShape.strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
        }
    }
}

/// The running turn in arrival order: committed text bubbles, then the text
/// still streaming. Tool calls are not rendered in the Bot transcript; they
/// exist only as the activity line's category/phrase.
private struct BotLiveTurnView: View {
    let live: BotLiveTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(live.segments.enumerated()), id: \.offset) { _, segment in
                if case .text(let text) = segment, BotAnswerBubbleContent.hasContent(text) {
                    BotAnswerBubbleContent(text: text, streaming: false)
                        .padding(.horizontal, HomeSpec.contentInset)
                        .padding(.vertical, HomeSpec.blockGap / 2)
                }
            }
            if BotAnswerBubbleContent.hasContent(live.buffer) {
                BotAnswerBubbleContent(text: live.buffer, streaming: true)
                    .padding(.horizontal, HomeSpec.contentInset)
                    .padding(.vertical, HomeSpec.blockGap / 2)
                    .accessibilityIdentifier("bot.streaming.text")
            }
        }
    }
}

private struct BotStreamingRow: View {
    let text: String

    var body: some View {
        BotAnswerBubbleContent(text: text, streaming: true)
            .padding(.horizontal, HomeSpec.contentInset)
            .padding(.vertical, HomeSpec.blockGap / 2)
            .accessibilityIdentifier("bot.streaming.text")
    }
}

/// The 36pt send / stop circle, as in DSH: black when it can act, the
/// bubble gray with a muted glyph when it cannot.
private struct BotComposerGlyph: View {
    let systemImage: String
    var enabled = true

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(enabled ? HomeSpec.primaryButtonInk : HomeSpec.iconMuted)
            .frame(width: HomeSpec.sendButton, height: HomeSpec.sendButton)
            .background(enabled ? HomeSpec.primaryButton : HomeSpec.userBubble, in: Circle())
            .contentShape(Circle())
    }
}

private struct BotSourceSheet: View {
    let row: BotUIRow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("行") {
                    LabeledContent("rowID", value: row.id)
                    LabeledContent("botID", value: row.botID)
                    LabeledContent("表面", value: BotUIRendering.surface(row))
                    LabeledContent("序号", value: "\(row.seq) / \(row.updatedSeq)")
                }
                Section("来源") {
                    LabeledContent("信任", value: row.provenance.trust)
                    LabeledContent("外部内容", value: row.provenance.tainted ? "是" : "否")
                    ForEach(row.provenance.eventIDs, id: \.self) { eventID in
                        Text(eventID).textSelection(.enabled)
                    }
                }
            }
            .homeGroupedList()
            .navigationTitle("消息来源")
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}

/// Scroll metrics for the transcript tail. This is a plain reference box, not
/// `@State`: the tail probe and viewport reader fire during layout, and writing
/// observable state there would dirty the graph that is measuring the rows.
private final class BotTranscriptScrollMetrics {
    var tailY: CGFloat = .greatestFiniteMagnitude
    var viewportHeight: CGFloat = 0
    /// Measured transcript height (before the page's top/bottom padding), so
    /// the follow pass can skip a bottom-anchored scroll on a short page.
    var contentHeight: CGFloat = 0
    /// Blank-viewport correction state. A tail preference change proves the
    /// viewport went past the real content; two attempts per height are enough
    /// to let layout settle without spinning forever.
    var blankCorrectionContentHeight: CGFloat = 0
    var blankCorrectionAttempts = 0
    var lastBlankCorrectionAt = Date.distantPast
}

private struct BotTranscriptTailPreference: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct BotTranscriptContentHeightPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reads the scroll viewport height without wrapping the transcript in a
/// `GeometryReader`. The action runs after a real size change (keyboard,
/// composer growth, rotation), updates the plain metrics box and lets the page
/// follow the newest content with the new viewport.
private struct BotTranscriptViewportReader: ViewModifier {
    let metrics: BotTranscriptScrollMetrics
    var onChange: (CGFloat) -> Void = { _ in }

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self, of: { proxy in
            proxy.size.height
        }) { height in
            metrics.viewportHeight = height
            onChange(height)
        }
    }
}

private enum BotTranscriptScrollPhase {
    case userDriven
    case settled
    case other
}

/// iOS 18 scroll phases distinguish a person dragging the transcript from a
/// keyboard/composer resize or a programmatic scroll. On iOS 17 this is a
/// no-op and the transcript keeps the pre-existing follow behavior.
private struct BotTranscriptScrollPhaseObserver: ViewModifier {
    let onChange: (BotTranscriptScrollPhase) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting, .decelerating, .tracking:
                    onChange(.userDriven)
                case .idle:
                    onChange(.settled)
                default:
                    onChange(.other)
                }
            }
        } else {
            content
        }
    }
}


/// Latest requested transcript scroll. Mutated only on the main actor; a
/// running coalescing task reads it each pass so a new row/card can replace
/// the target without cancelling the sleep that is already in flight.
@MainActor
private final class BotTranscriptScrollRequest {
    var target: AnyHashable = AnyHashable("bot-transcript-tail")
    var anchor: UnitPoint = .bottom
    var generation: UInt64 = 0
}
