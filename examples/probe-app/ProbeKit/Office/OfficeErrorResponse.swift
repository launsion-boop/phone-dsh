// SPDX-License-Identifier: MIT

import Foundation

extension OfficeJSON {
    static func failure(tool: String, error: OfficeToolError) throws -> String {
        let code: String
        switch error {
        case .invalidArguments: code = "invalid_arguments"
        case .unknownTool: code = "unknown_tool"
        case .unknownArtifact: code = "unknown_file"
        case .invalidRange: code = "invalid_range"
        case .unsupported: code = "unsupported"
        case .unavailable: code = "unavailable"
        case .resultTooLarge: code = "result_too_large"
        case .cancelled: code = "cancelled"
        }
        return try string([
            "ok": false,
            "tool": tool,
            "error": ["code": code, "message": error.localizedDescription],
        ])
    }
}
