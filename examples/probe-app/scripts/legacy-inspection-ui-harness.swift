// SPDX-License-Identifier: MIT
import Foundation
import Observation
import PhoneDSHDeviceTasks

private typealias Result = DeviceTaskLegacyInspection
private let firstIncomplete = Result(status: .incomplete, entries: [], cancelled: false, reasons: [.rootUnreadable])
private let firstCancelled = Result(status: .incomplete, entries: [], cancelled: true, reasons: [.cancelled])
private let firstBusy = Result(status: .busy, entries: [], cancelled: false, reasons: [])
private let secondIncomplete = Result(status: .incomplete, entries: [], cancelled: false, reasons: [.byteBudget])
private let incompleteWithClaims = Result(
    status: .incomplete,
    entries: [.init(id: "ble-ops/receipt%25.json", label: "ble-ops/receipt%25.json", kind: .observed,
                    claims: .init(deviceID: "ble%3Aold", taskID: "task%2F1", phase: "complete", outcomeKind: "unknown")),
              .init(id: "opaque", label: "opaque", kind: .unexamined, claims: nil)],
    cancelled: false, reasons: [.ioError, .byteBudget])

private struct Fixture: Decodable {
    let name: String
    let scenario: String
    let watch: String
    let inspectCalls: Int
    let pausedInspecting: Bool?
    let pausedCancellationRequested: Bool?
    let cancellationObserved: Bool
    let finalResult: String
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private actor InspectorGate {
    let busyFirst: Bool
    let forcedFirst: Result?
    private var calls = 0
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var running: Set<Int> = []
    private var cancellation: [Int: Bool] = [:]
    private var overlapped = false

    init(busyFirst: Bool = false, forcedFirst: Result? = nil) {
        self.busyFirst = busyFirst; self.forcedFirst = forcedFirst
    }

    func inspect() async -> Result {
        calls += 1
        let number = calls
        if !running.isEmpty { overlapped = true }
        running.insert(number)
        await withCheckedContinuation { waiting[number] = $0 }
        let cancelled = Task.isCancelled
        cancellation[number] = cancelled
        running.remove(number)
        if number == 1, let forcedFirst { return forcedFirst }
        if cancelled { return firstCancelled }
        if number == 1 { return busyFirst ? firstBusy : firstIncomplete }
        return secondIncomplete
    }

    func release(_ number: Int) throws {
        guard let continuation = waiting.removeValue(forKey: number) else {
            throw Failure(description: "inspector \(number) was not paused")
        }
        continuation.resume()
    }
    func snapshot() -> (calls: Int, waiting: Set<Int>, cancellation: [Int: Bool], overlapped: Bool) {
        (calls, Set(waiting.keys), cancellation, overlapped)
    }
}

@MainActor private final class Tracker {
    var callbacks = 0
    var actions = 0
    var excess = false
    var clearCounts: (beforeFirst: Int, afterFirst: Int, beforeSecond: Int, afterSecond: Int, freshAfterSecond: Int)?
    func fire(_ action: () -> Void) {
        callbacks += 1
        // Only the first callback injects events. Nested notifications are
        // counted, never allowed to cause unbounded recursive test actions.
        if callbacks == 1 { actions += 1; action() }
        if callbacks > 8 { excess = true }
    }
}

@MainActor private func track(_ property: String, model: LegacyTaskInspectionModel,
                              tracker: Tracker, action: @escaping @MainActor () -> Void) throws {
    switch property {
    case "none": return
    case "isInspecting":
        withObservationTracking { _ = model.isInspecting } onChange: {
            MainActor.assumeIsolated { tracker.fire(action) }
        }
    case "result":
        withObservationTracking { _ = model.result } onChange: {
            MainActor.assumeIsolated { tracker.fire(action) }
        }
    case "cancellationRequested":
        withObservationTracking { _ = model.cancellationRequested } onChange: {
            MainActor.assumeIsolated { tracker.fire(action) }
        }
    default: throw Failure(description: "unknown watch \(property)")
    }
}

@MainActor private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(description: message) }
}

@MainActor private func pause() async {
    try? await Task.sleep(for: .milliseconds(10))
}

@MainActor private func awaitPaused(_ gate: InspectorGate, _ number: Int) async throws {
    for _ in 0..<200 {
        if await gate.snapshot().waiting.contains(number) { return }
        await pause()
    }
    throw Failure(description: "timed out waiting for inspector \(number)")
}

@MainActor private func awaitIdle(_ model: LegacyTaskInspectionModel) async throws {
    for _ in 0..<200 {
        if !model.isInspecting { await pause(); if !model.isInspecting { return } }
        await pause()
    }
    throw Failure(description: "timed out waiting for idle model")
}

@MainActor private func checkPaused(_ fixture: Fixture, model: LegacyTaskInspectionModel) throws {
    if let inspecting = fixture.pausedInspecting {
        try require(model.isInspecting == inspecting, "paused isInspecting expected \(inspecting), got \(model.isInspecting)")
    }
    if let cancellation = fixture.pausedCancellationRequested {
        try require(model.cancellationRequested == cancellation, "paused cancellationRequested expected \(cancellation), got \(model.cancellationRequested)")
    }
}

@MainActor private func run(_ fixture: Fixture) async throws {
    let gate = InspectorGate(busyFirst: fixture.scenario == "busy-result")
    let model = LegacyTaskInspectionModel(inspect: { await gate.inspect() })
    let tracker = Tracker()
    let clearNoOpTracker = Tracker()
    let startCases: Set<String> = ["start-reentered", "cancel-before-inspect", "clear-before-inspect", "duplicate-clear"]
    let completionCases: Set<String> = ["clear-during-result", "start-during-completion", "clear-during-completion", "clear-then-start", "start-then-clear", "start-then-cancel", "clear-start-clear"]
    let cancelCases: Set<String> = ["cancel-while-inspecting", "clear-while-inspecting", "duplicate-cancel"]
    let scenarios: Set<String> = ["ordinary", "start-reentered", "cancel-before-inspect", "clear-before-inspect", "start-while-inspecting", "cancel-while-inspecting", "clear-while-inspecting", "clear-during-result", "start-during-completion", "clear-during-completion", "duplicate-cancel", "busy-result", "clear-then-start", "start-then-clear", "start-then-cancel", "clear-start-clear", "duplicate-clear", "restart-clears-prior"]
    try require(scenarios.contains(fixture.scenario), "unknown scenario \(fixture.scenario)")

    let action: @MainActor () -> Void = {
        switch fixture.scenario {
        case "start-reentered", "start-during-completion": model.start()
        case "cancel-before-inspect", "duplicate-cancel": model.cancel()
        case "clear-before-inspect", "clear-during-result", "clear-during-completion": model.cancelAndClear()
        case "duplicate-clear":
            let beforeFirst = tracker.callbacks
            model.cancelAndClear()
            let afterFirst = tracker.callbacks
            let beforeSecond = tracker.callbacks
            // The first tracking registration may already have been consumed
            // by the effective clear. A fresh one detects a second notification.
            try! track("isInspecting", model: model, tracker: clearNoOpTracker) {}
            model.cancelAndClear()
            tracker.clearCounts = (beforeFirst, afterFirst, beforeSecond, tracker.callbacks, clearNoOpTracker.callbacks)
        case "clear-then-start": model.cancelAndClear(); model.start()
        case "start-then-clear": model.start(); model.cancelAndClear()
        case "start-then-cancel": model.start(); model.cancel()
        case "clear-start-clear": model.cancelAndClear(); model.start(); model.cancelAndClear()
        default: break
        }
    }

    if startCases.contains(fixture.scenario) {
        try track(fixture.watch, model: model, tracker: tracker, action: action)
    }
    model.start()

    if ["cancel-before-inspect", "clear-before-inspect", "duplicate-clear"].contains(fixture.scenario) {
        try await awaitIdle(model)
    } else {
        try await awaitPaused(gate, 1)
        if fixture.scenario == "start-while-inspecting" { model.start(); await pause() }
        if cancelCases.contains(fixture.scenario) {
            if fixture.scenario == "duplicate-cancel" {
                try track(fixture.watch, model: model, tracker: tracker, action: action)
            }
            if fixture.scenario == "clear-while-inspecting" { model.cancelAndClear() }
            else { model.cancel() }
            try checkPaused(fixture, model: model)
            if fixture.scenario == "duplicate-cancel" {
                // The original one-shot observation may already be consumed.
                // A fresh tracker proves the next no-op cancel emits nothing.
                let fresh = Tracker()
                try track("cancellationRequested", model: model, tracker: fresh) {}
                model.cancel()
                try require(fresh.callbacks == 0, "no-op cancel notified a fresh observer")
            }
            model.start() // Cancellation is advisory; the paused call owns the slot.
            await pause()
            let snapshot = await gate.snapshot()
            try require(snapshot.calls == 1 && snapshot.waiting == [1], "a second inspector entered before the cancelled inspector returned")
        }
        if completionCases.contains(fixture.scenario) {
            try checkPaused(fixture, model: model) // first-call checkpoint, except the two-call cases below
            try track(fixture.watch, model: model, tracker: tracker, action: action)
        } else if fixture.scenario != "restart-clears-prior" && !cancelCases.contains(fixture.scenario) {
            try checkPaused(fixture, model: model)
        }
        try await gate.release(1)

        if ["start-during-completion", "clear-then-start"].contains(fixture.scenario) {
            try await awaitPaused(gate, 2)
            try checkPaused(fixture, model: model)
            try require(model.result == nil, "retired first publication restored its result over the newer operation")
            try await gate.release(2)
        } else if fixture.scenario == "restart-clears-prior" {
            try await awaitIdle(model)
            try require(model.result == firstIncomplete, "first result not preserved before restart")
            model.start()
            try await awaitPaused(gate, 2)
            try checkPaused(fixture, model: model)
            try require(model.result == nil, "restart did not clear the prior result")
            try await gate.release(2)
        }
        try await awaitIdle(model)
    }

    let snapshot = await gate.snapshot()
    try require(snapshot.calls == fixture.inspectCalls, "inspect calls expected \(fixture.inspectCalls), got \(snapshot.calls)")
    try require(snapshot.waiting.isEmpty, "inspector still paused after final completion")
    try require(!snapshot.overlapped, "inspectors overlapped")
    try require(snapshot.cancellation.values.contains(true) == fixture.cancellationObserved,
                "cancellation observed expected \(fixture.cancellationObserved), got \(snapshot.cancellation)")
    try require(!model.isInspecting && !model.cancellationRequested, "final state is not idle")
    let expected: Result?
    switch fixture.finalResult {
    case "none": expected = nil
    case "first-incomplete": expected = firstIncomplete
    case "first-cancelled": expected = firstCancelled
    case "first-busy": expected = firstBusy
    case "second-incomplete": expected = secondIncomplete
    default: throw Failure(description: "unknown expected result \(fixture.finalResult)")
    }
    try require(model.result == expected, "full result mismatch: expected \(String(describing: expected)), got \(String(describing: model.result))")
    if fixture.watch != "none" {
        try require(tracker.actions == 1 && !tracker.excess, "observation callback did not execute exactly one bounded action")
    }
    if fixture.scenario == "duplicate-clear" {
        guard let counts = tracker.clearCounts else { throw Failure(description: "clear callbacks were not measured") }
        try require(counts.beforeFirst == 1 && counts.afterFirst >= counts.beforeFirst,
                    "first effective clear callback measurement was invalid")
        try require(counts.beforeSecond == counts.afterFirst && counts.afterSecond == counts.beforeSecond,
                    "second no-op clear notified: before=\(counts.beforeSecond), after=\(counts.afterSecond)")
        try require(counts.freshAfterSecond == 0,
                    "second no-op clear notified a fresh observer \(counts.freshAfterSecond) times")
    }
    if fixture.scenario == "duplicate-cancel" {
        try require(tracker.callbacks == 1, "no-op reentry recursively notified \(tracker.callbacks) times")
    }
}

// A fresh result observer invokes a second clear during an effective clear.
@MainActor private func checkRepeatedEffectiveClear() async throws {
    let gate = InspectorGate()
    let model = LegacyTaskInspectionModel(inspect: { await gate.inspect() })
    model.start()
    try await awaitPaused(gate, 1)
    try await gate.release(1)
    try await awaitIdle(model)
    try require(model.result == firstIncomplete, "clear setup result missing")
    let tracker = Tracker()
    try track("result", model: model, tracker: tracker) { model.cancelAndClear() }
    model.cancelAndClear()
    await pause()
    try require(tracker.callbacks == 1 && tracker.actions == 1, "repeated clear recursively notified")
    try require(model.result == nil && !model.isInspecting && !model.cancellationRequested, "repeated clear did not settle")
    let snapshot = await gate.snapshot()
    try require(snapshot.calls == 1 && snapshot.waiting.isEmpty, "clear started another inspector")
}

// Cancellation is advisory: the inspector decides the actual returned value.
// Clear differs only in discarding that returned value from presentation.
@MainActor private func checkAdvisoryCancellationAndClaims() async throws {
    for (name, returned) in [("busy", firstBusy), ("incomplete with claims", incompleteWithClaims)] {
        for clear in [false, true] {
            let gate = InspectorGate(forcedFirst: returned)
            let model = LegacyTaskInspectionModel(inspect: { await gate.inspect() })
            model.start()
            try await awaitPaused(gate, 1)
            if clear { model.cancelAndClear() } else { model.cancel() }
            try require(model.isInspecting && model.cancellationRequested,
                        "\(name) clear=\(clear): cancelled inspection did not remain active")
            model.start()
            await pause()
            let paused = await gate.snapshot()
            try require(paused.calls == 1 && paused.waiting == [1],
                        "\(name) clear=\(clear): a second inspector entered before release")
            try await gate.release(1)
            try await awaitIdle(model)
            let completed = await gate.snapshot()
            try require(completed.calls == 1 && completed.waiting.isEmpty && !completed.overlapped,
                        "\(name) clear=\(clear): invalid inspector lifecycle")
            try require(completed.cancellation[1] == true,
                        "\(name) clear=\(clear): inspector did not observe cancellation")
            try require(!model.isInspecting && !model.cancellationRequested,
                        "\(name) clear=\(clear): final state is not idle")
            let expected: Result? = clear ? nil : returned
            try require(model.result == expected,
                        "\(name) clear=\(clear): actual inspector result was not preserved or discarded as requested")
        }
    }
}

@main private struct Harness {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw Failure(description: "expected fixture path") }
            let text = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
            let lines = text.split(whereSeparator: \.isNewline)
            try require(lines.count == 18, "expected 18 shared fixtures, got \(lines.count)")
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            var names = Set<String>(), scenarios = Set<String>()
            for line in lines {
                let fixture = try decoder.decode(Fixture.self, from: Data(line.utf8))
                try require(names.insert(fixture.name).inserted && scenarios.insert(fixture.scenario).inserted, "duplicate fixture")
                do { try await run(fixture); print("PASS \(fixture.name)") }
                catch { throw Failure(description: "\(fixture.name): \(error)") }
            }
            try await checkRepeatedEffectiveClear()
            print("PASS repeated effective clear")
            try await checkAdvisoryCancellationAndClaims()
            print("PASS advisory cancellation, clear and nonempty claims")
            print("PASS \(lines.count) shared fixtures (real model; stub inspector)")
        } catch {
            fputs("FAIL \(error)\n", stderr)
            exit(1)
        }
    }
}
