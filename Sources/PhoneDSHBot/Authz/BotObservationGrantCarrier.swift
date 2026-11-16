// SPDX-License-Identifier: MIT

import Foundation

/// G-1 r20 carrier enrichment shared by the real tool-result writer and its
/// integration test. It only attaches a grant the authorizer actually
/// evaluated for this call; no grant or an ambiguous set leaves the carrier
/// untouched.
public enum BotObservationGrantCarrier {
    public static func enrich(_ data: BotJSONValue,
                              callId: String?,
                              attribution: BotGrantAttributionStore) async -> BotJSONValue {
        guard let callId,
              let grantId = await attribution.grantId(callId: callId),
              case .object(var object) = data else { return data }
        object["grant_id"] = .string(grantId)
        return .object(object)
    }
}
