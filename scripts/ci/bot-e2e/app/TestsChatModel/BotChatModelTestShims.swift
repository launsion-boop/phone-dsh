// SPDX-License-Identifier: MIT

// The BotChatModelTests target compiles the real chat model, live-turn and
// presentation state machines, but not the page/ProbeKit view layer. These
// declarations only give `BotLiveTurn` the DSH transcript item shape it
// consumes; the model-visibility tests below never assert tool rows.
import Foundation
import PhoneDSHAgentCore

struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case toolCall
        case toolResult
        case other
    }

    let id: String
    let kind: Kind
    var toolName: String?
    var callID: String?
}

enum NativeTranscriptProjector {
    static func items(from records: [JSONValue], sessionID: String) -> [ChatItem] { [] }
}

enum NativeTurnProcessState: Equatable {
    case running

    static func resolve(endReasonKind: String, elapsed: TimeInterval?) -> NativeTurnProcessState {
        .running
    }
}
