// SPDX-License-Identifier: MIT

import Observation
import PhoneDSHAgentCore
import ProbeKit
import SwiftUI

@MainActor
@Observable
final class NativeDeviceSessionModel {
    let mapping: DeviceSessionMapping
    private(set) var durableItems: [DeviceTranscriptItem] = []
    private var liveItems: [DeviceTranscriptItem] = []
    var items: [DeviceTranscriptItem] { durableItems + liveItems }
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var isLoadingEarlier = false
    private(set) var hasMore = false

    @ObservationIgnored private var transport: ReadOnlyDeviceSessionTransport?
    @ObservationIgnored private var records: [Int: JSONValue] = [:]
    @ObservationIgnored private var throughSeq: Int?
    @ObservationIgnored private var beforeSeq: Int?
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var lastEventSeq: UInt64?
    @ObservationIgnored private var activeTurn: Int?
    @ObservationIgnored private var activeStep: Int?

    init(mapping: DeviceSessionMapping) {
        self.mapping = mapping
    }

    func start() async {
        guard pumpTask == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let readOnly = ReadOnlyDeviceSessionTransport(
                transport: try await ChatModel.shared.transportForManagement())
            transport = readOnly
            let snapshot = try await Self.readHistory(sessionID: mapping.sessionID, transport: readOnly)
            guard !Task.isCancelled else { return }
            apply(snapshot, resetting: true)
            lastEventSeq = snapshot.after
            let harness = DSHRemoteHarness(transport: readOnly)
            startPump(harness: harness)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func stopMonitoring() {
        pumpTask?.cancel()
        pumpTask = nil
        transport = nil
    }

    func loadEarlier() async {
        guard hasMore, !isLoadingEarlier, let transport, let throughSeq, let beforeSeq else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        do {
            let page = try await transport.call("session/page", args: .object(["request": .object([
                "address": .object(["kind": .string("session"), "sessionId": .string(mapping.sessionID)]),
                "throughSeq": .number(Double(throughSeq)),
                "beforeSeq": .number(Double(beforeSeq)),
                "maxMessages": .number(60),
            ])]))
            let events = (page["records"]?.arrayValue ?? []).compactMap { $0["event"] }
            guard let nextBefore = events.compactMap({ $0["seq"]?.intValue }).min(),
                  nextBefore < beforeSeq else {
                hasMore = false
                throw NativeDeviceSessionModelError.historyDidNotAdvance(beforeSeq)
            }
            merge(events)
            self.beforeSeq = nextBefore
            hasMore = page["hasMore"]?.boolValue ?? false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startPump(harness: DSHRemoteHarness) {
        pumpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    for try await event in harness.events(sessionID: self.mapping.sessionID,
                                                          after: self.lastEventSeq) {
                        guard !Task.isCancelled else { return }
                        if let seq = event.seq { self.lastEventSeq = seq }
                        self.errorMessage = nil
                        self.apply(event)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.errorMessage = error.localizedDescription
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func apply(_ event: HarnessEvent) {
        switch event.kind {
        case .reasoningDelta(let text):
            if let index = liveItems.indices.last, liveItems[index].kind == .reasoning,
               liveItems[index].streaming {
                liveItems[index].text += text
            } else {
                finishStreamingReasoning()
                var item = DeviceTranscriptItem(id: eventItemID(event), kind: .reasoning,
                                    title: "思考", text: text, streaming: true)
                item.timestamp = event.time
                item.turn = activeTurn
                item.step = activeStep
                liveItems.append(item)
            }
        case .assistantDelta(let text):
            finishStreamingReasoning()
            if let index = liveItems.indices.last, liveItems[index].kind == .assistant,
               liveItems[index].streaming {
                liveItems[index].text += text
            } else {
                var item = DeviceTranscriptItem(id: eventItemID(event), kind: .assistant,
                                    title: "Assistant", text: text, streaming: true)
                item.timestamp = event.time
                item.turn = activeTurn
                item.step = activeStep
                liveItems.append(item)
            }
        case .assistantMessage(let text):
            finishStreamingReasoning()
            if let index = liveItems.indices.last, liveItems[index].kind == .assistant,
               liveItems[index].streaming {
                if !text.isEmpty { liveItems[index].text = text }
                liveItems[index].streaming = false
            } else if !text.isEmpty {
                var item = DeviceTranscriptItem(id: eventItemID(event), kind: .assistant,
                                    title: "Assistant", text: text)
                item.timestamp = event.time
                item.turn = activeTurn
                item.step = activeStep
                liveItems.append(item)
            }
        case .userMessage(let text, _):
            var item = DeviceTranscriptItem(id: eventItemID(event), kind: .user, title: "Device", text: text)
            item.timestamp = event.time
            item.turn = activeTurn
            liveItems.append(item)
        case .toolCall(let callID, let name, let arguments):
            finishStreamingAssistant()
            finishStreamingReasoning()
            var item = DeviceTranscriptItem(id: eventItemID(event), kind: .toolCall,
                                title: "Tool call: \(name)", text: Self.render(arguments))
            item.timestamp = event.time
            item.turn = activeTurn
            item.step = activeStep
            item.callID = callID
            item.toolName = name
            item.arguments = arguments
            item.argumentsRaw = deviceJSON(arguments)
            item.toolState = .running
            liveItems.append(item)
        case .toolResult(let callID, let isError, let summary):
            let detail = event.toolResultDetail?.text ?? summary
            if let index = liveItems.indices.last(where: {
                liveItems[$0].callID == callID && liveItems[$0].kind == .toolCall
            }) {
                liveItems[index].toolOutput = detail
                liveItems[index].toolState = isError ? .error : .ok
            } else if let index = durableItems.indices.last(where: {
                durableItems[$0].callID == callID && durableItems[$0].kind == .toolCall
            }) {
                durableItems[index].toolOutput = detail
                durableItems[index].toolState = isError ? .error : .ok
            } else {
                var item = DeviceTranscriptItem(id: eventItemID(event), kind: .toolResult(isError: isError),
                                    title: isError ? "Tool error" : "Tool result", text: detail)
                item.timestamp = event.time
                item.turn = activeTurn
                item.step = activeStep
                item.callID = callID
                item.toolOutput = detail
                item.toolState = isError ? .error : .ok
                liveItems.append(item)
            }
        case .turnStarted(let turnID):
            activeTurn = Int(turnID)
            activeStep = nil
        case .turnEnded:
            finishStreamingAssistant()
            finishStreamingReasoning()
        case .progress(let phase, let step, _):
            if phase == "step" { activeStep = step }
        case .usage:
            break
        case .permissionRequested, .questionRequested, .inboxSpliced, .compaction, .sessionStatus, .exited:
            break
        }
    }

    private func finishStreamingAssistant() {
        if let index = liveItems.indices.last, liveItems[index].kind == .assistant,
           liveItems[index].streaming {
            liveItems[index].streaming = false
        }
    }

    private func finishStreamingReasoning() {
        for index in liveItems.indices where liveItems[index].kind == .reasoning && liveItems[index].streaming {
            liveItems[index].streaming = false
        }
    }

    private func eventItemID(_ event: HarnessEvent) -> String {
        guard let seq = event.seq else { return UUID().uuidString }
        let position = DSHEventMapper.position(of: seq)
        return "\(mapping.sessionID):\(position.dshSeq):part-\(position.part)"
    }

    private static func render(_ arguments: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(arguments), let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "\(arguments)"
    }

    private func apply(_ snapshot: HistorySnapshot, resetting: Bool) {
        if resetting {
            records = [:]
            beforeSeq = snapshot.beforeSeq
            hasMore = snapshot.hasMore
        }
        merge(snapshot.records)
        throughSeq = snapshot.throughSeq
    }

    private func merge(_ newRecords: [JSONValue]) {
        for record in newRecords {
            guard let seq = record["seq"]?.intValue else { continue }
            records[seq] = record
        }
        let ordered = records.keys.sorted().compactMap { records[$0] }
        durableItems = DeviceTranscriptProjector.items(from: ordered, sessionID: mapping.sessionID)
        if beforeSeq == nil { beforeSeq = ordered.compactMap { $0["seq"]?.intValue }.min() }
    }

    private struct HistorySnapshot {
        var records: [JSONValue]
        var after: UInt64?
        var hasMore: Bool
        var beforeSeq: Int?
        var throughSeq: Int?
    }

    private static func readHistory(sessionID: String,
                                    transport: ReadOnlyDeviceSessionTransport) async throws -> HistorySnapshot {
        let cursor = try await readCursor(sessionID: sessionID, transport: transport)
        var records: [JSONValue] = []
        var hasMore = false
        if cursor >= 0 {
            let page = try await transport.call("session/page", args: .object(["request": .object([
                "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                "throughSeq": .number(Double(cursor)),
                "maxMessages": .number(60),
            ])]))
            records = (page["records"]?.arrayValue ?? []).compactMap { $0["event"] }
            hasMore = page["hasMore"]?.boolValue ?? false
        }
        let after = cursor >= 0
            ? UInt64(cursor + 1) * DSHEventMapper.partsPerEvent - 1
            : nil
        return HistorySnapshot(records: records, after: after, hasMore: hasMore,
                               beforeSeq: records.compactMap { $0["seq"]?.intValue }.min(),
                               throughSeq: cursor >= 0 ? cursor : nil)
    }

    private static func readCursor(sessionID: String,
                                   transport: ReadOnlyDeviceSessionTransport) async throws -> Int {
        let mux = try await transport.openMux()
        let streamID = "device-monitor-history-\(UUID().uuidString)"
        do {
            try await mux.send(.object([
                "type": .string("open"),
                "streamId": .string(streamID),
                "endpoint": .string("session/follow"),
                "payload": .object(["args": .object(["request": .object([
                    "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                    "maxMessages": .number(1),
                    "assistantStream": .bool(false),
                ])])]),
            ]))
            let cursor = try await receiveCursor(from: mux, streamID: streamID)
            await mux.close()
            return cursor
        } catch {
            await mux.close()
            throw error
        }
    }

    private static func receiveCursor(from mux: any DSHMuxConnection, streamID: String) async throws -> Int {
        try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    guard let frame = try await mux.receive() else {
                        throw ProviderError.unavailable(retryAfter: nil)
                    }
                    guard frame["streamId"]?.stringValue == streamID else { continue }
                    switch frame["type"]?.stringValue {
                    case "error":
                        throw ProviderError.invalidResponse(
                            frame["error"]?["message"]?.stringValue ?? "session/follow failed")
                    case "end":
                        throw ProviderError.invalidResponse("session/follow ended before its history cursor")
                    case "item":
                        let value = frame["value"] ?? .null
                        if value["type"]?.stringValue == "snapshot" {
                            guard let cursor = value["cursor"]?.intValue else {
                                throw ProviderError.invalidResponse("session/follow snapshot has no cursor")
                            }
                            return cursor
                        }
                    default:
                        continue
                    }
                }
                throw ProviderError.cancelled
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                await mux.close()
                throw ProviderError.unavailable(retryAfter: nil)
            }
            guard let cursor = try await group.next() else {
                throw ProviderError.invalidResponse("session/follow did not publish a history cursor")
            }
            group.cancelAll()
            return cursor
        }
    }
}

private enum NativeDeviceSessionModelError: LocalizedError {
    case historyDidNotAdvance(Int)

    var errorDescription: String? {
        switch self {
        case .historyDidNotAdvance(let seq):
            return "设备会话历史没有前进到 seq \(seq) 之前。"
        }
    }
}

struct NativeDeviceSessionPage: View {
    @State private var model: NativeDeviceSessionModel

    init(mapping: DeviceSessionMapping) {
        _model = State(initialValue: NativeDeviceSessionModel(mapping: mapping))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "eye")
                Text("设备会话 · 只读监视")
                Spacer()
                Text(model.mapping.sessionID.prefix(8))
                    .monospaced()
            }
            .font(.system(size: 12))
            .foregroundStyle(ChatPage.inkSecondary)
            .padding(.horizontal, 16)
            .frame(height: 36)

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(ChatPage.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(ChatPage.danger.opacity(0.06))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.hasMore {
                        Button {
                            Task { await model.loadEarlier() }
                        } label: {
                            HStack {
                                if model.isLoadingEarlier { ProgressView().controlSize(.small) }
                                Text(model.isLoadingEarlier ? "正在读取…" : "读取更早消息")
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isLoadingEarlier)
                    }
                    if model.items.isEmpty {
                        if model.isLoading {
                            ProgressView("正在读取设备会话…")
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
                        } else if model.errorMessage == nil {
                            ContentUnavailableView("还没有交互记录", systemImage: "bubble.left.and.bubble.right",
                                                   description: Text("设备与这个固定 Session 的真实交互会显示在这里。"))
                                .padding(.top, 60)
                        }
                    }
                    ForEach(model.items) { item in
                        DeviceReadOnlyRow(item: item)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .defaultScrollAnchor(.bottom)
        }
        .background(Color(.systemBackground))
        .navigationTitle(model.mapping.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Label("只读监视，请在设备上处理输入与确认", systemImage: "lock.display")
                .font(.system(size: 12))
                .foregroundStyle(ChatPage.inkSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.bar)
        }
        .task { await model.start() }
        .onDisappear { model.stopMonitoring() }
    }
}
