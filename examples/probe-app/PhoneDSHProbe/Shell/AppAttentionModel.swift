// SPDX-License-Identifier: MIT

import Observation
import ProbeKit

@MainActor
@Observable
final class AppAttentionModel {
    private(set) var chatItems: [AttentionItem] = []
    private(set) var dshItems: [AttentionItem] = []
    private(set) var discoverItems: [AttentionItem] = []
    private var tasks: [Task<Void, Never>] = []

    func items(for owner: AttentionOwner) -> [AttentionItem] {
        switch owner {
        case .chat: chatItems
        case .dsh: dshItems
        case .discover: discoverItems
        }
    }

    func start(sources: [any AttentionSource]) {
        stop()
        for source in sources {
            let task = Task { @MainActor in
                for await batch in source.items() {
                    guard !Task.isCancelled else { return }
                    switch source.owner {
                    case .chat: chatItems = batch
                    case .dsh: dshItems = batch
                    case .discover: discoverItems = batch
                    }
                }
            }
            tasks.append(task)
        }
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

}
