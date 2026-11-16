// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

/// G-1/G-4 skill roots for the phone host. The VFS `/dsh/workspace` and
/// `/dsh/home` are the two materialized mounts; project skills live under the
/// per-Bot root, so the producer and the rechecker must classify by
/// `(source, owner)` rather than a single host directory.
struct BotSkillRoots: Sendable {
    let workspaceRoot: URL

    func skillsRoot(source: String, ownerBotID: String?) -> URL? {
        switch source {
        case "user-dsh", "user-agents":
            return workspaceRoot
                .appendingPathComponent("materialized/home/skills", isDirectory: true)
        case "project-dsh":
            guard let ownerBotID, !ownerBotID.isEmpty else { return nil }
            let botRoot = BotWorkspaceLayout.botRoot(
                botId: ownerBotID,
                dataDirectory: BotWorkspaceLayout.defaultBotDataDirectory)
            let prefix = "/dsh/workspace/"
            guard botRoot.hasPrefix(prefix) else { return nil }
            let relative = String(botRoot.dropFirst(prefix.count))
            return workspaceRoot
                .appendingPathComponent("materialized/workspace", isDirectory: true)
                .appendingPathComponent(relative, isDirectory: true)
                .appendingPathComponent(".dsh/skills", isDirectory: true)
        case "project-agents":
            guard let ownerBotID, !ownerBotID.isEmpty else { return nil }
            let botRoot = BotWorkspaceLayout.botRoot(
                botId: ownerBotID,
                dataDirectory: BotWorkspaceLayout.defaultBotDataDirectory)
            let prefix = "/dsh/workspace/"
            guard botRoot.hasPrefix(prefix) else { return nil }
            let relative = String(botRoot.dropFirst(prefix.count))
            return workspaceRoot
                .appendingPathComponent("materialized/workspace", isDirectory: true)
                .appendingPathComponent(relative, isDirectory: true)
                .appendingPathComponent(".agents/skills", isDirectory: true)
        default:
            return nil
        }
    }
}


extension BotSkillRoots: BotSkillRootResolving {
    func root(for source: BotSkillSource, ownerBotID: String?) -> URL? {
        skillsRoot(source: source.rawValue, ownerBotID: ownerBotID)
    }
}
