// SPDX-License-Identifier: MIT

import Foundation

public enum ToolNameCodecError: Error, Equatable, Sendable, LocalizedError {
    case invalidInternalName(String)
    case invalidModelName(String)
    case nameTooLong(String)
    case duplicateInternalName(String)
    case conflict(modelName: String, first: String, second: String)
    case unknownModelName(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInternalName(let name): return "invalid internal tool name: \(name)"
        case .invalidModelName(let name): return "invalid model tool name: \(name)"
        case .nameTooLong(let name): return "model tool name exceeds 64 bytes: \(name)"
        case .duplicateInternalName(let name): return "duplicate internal tool name: \(name)"
        case .conflict(let modelName, let first, let second):
            return "tool name conflict: \(first) and \(second) both map to \(modelName)"
        case .unknownModelName(let name): return "unknown model tool name: \(name)"
        }
    }
}

public struct ToolNameCodec: Sendable {
    public static let maximumModelNameBytes = 64

    private let internalByModel: [String: String]
    private let modelByInternal: [String: String]
    private let descriptorsByInternal: [String: ConnectorToolDescriptor]

    public init(descriptors: [ConnectorToolDescriptor] = []) throws {
        var internalByModel: [String: String] = [:]
        var modelByInternal: [String: String] = [:]
        var descriptorsByInternal: [String: ConnectorToolDescriptor] = [:]
        for descriptor in descriptors {
            let internalName = descriptor.internalName
            guard modelByInternal[internalName] == nil else {
                throw ToolNameCodecError.duplicateInternalName(internalName)
            }
            let modelName = try Self.encode(internalName)
            if let existing = internalByModel[modelName] {
                throw ToolNameCodecError.conflict(modelName: modelName,
                                                  first: existing, second: internalName)
            }
            internalByModel[modelName] = internalName
            modelByInternal[internalName] = modelName
            descriptorsByInternal[internalName] = descriptor
        }
        self.internalByModel = internalByModel
        self.modelByInternal = modelByInternal
        self.descriptorsByInternal = descriptorsByInternal
    }

    public static func encode(_ internalName: String) throws -> String {
        try validateInternal(internalName)
        var encoded = ""
        for scalar in internalName.unicodeScalars {
            switch scalar {
            case ".": encoded.append("_")
            case "_": encoded.append("__")
            default: encoded.unicodeScalars.append(scalar)
            }
        }
        guard encoded.utf8.count <= maximumModelNameBytes else {
            throw ToolNameCodecError.nameTooLong(internalName)
        }
        return encoded
    }

    public static func decode(_ modelName: String) throws -> String {
        guard !modelName.isEmpty, modelName.utf8.count <= maximumModelNameBytes,
              modelName.unicodeScalars.allSatisfy(Self.isModelScalar) else {
            throw ToolNameCodecError.invalidModelName(modelName)
        }
        var decoded = ""
        var index = modelName.startIndex
        while index < modelName.endIndex {
            if modelName[index] != "_" {
                decoded.append(modelName[index])
                index = modelName.index(after: index)
                continue
            }
            let next = modelName.index(after: index)
            if next < modelName.endIndex, modelName[next] == "_" {
                decoded.append("_")
                index = modelName.index(after: next)
            } else {
                decoded.append(".")
                index = next
            }
        }
        guard try encode(decoded) == modelName else {
            throw ToolNameCodecError.invalidModelName(modelName)
        }
        return decoded
    }

    public func modelName(for internalName: String) throws -> String {
        if let mapped = modelByInternal[internalName] { return mapped }
        return try Self.encode(internalName)
    }

    public func internalName(forModelName modelName: String) throws -> String {
        let decoded = try Self.decode(modelName)
        guard let internalName = internalByModel[modelName], internalName == decoded else {
            throw ToolNameCodecError.unknownModelName(modelName)
        }
        return internalName
    }

    public func descriptor(internalName: String) -> ConnectorToolDescriptor? {
        descriptorsByInternal[internalName]
    }

    public var anthropicTools: [AnthropicTool] {
        descriptorsByInternal.values.sorted { $0.internalName < $1.internalName }.map { descriptor in
            AnthropicTool(name: modelByInternal[descriptor.internalName] ?? descriptor.internalName,
                          description: descriptor.summary,
                          inputSchemaJSON: descriptor.inputSchemaJSON)
        }
    }

    private static func validateInternal(_ name: String) throws {
        guard !name.isEmpty,
              name.unicodeScalars.allSatisfy({ isModelScalar($0) || $0 == "." }) else {
            throw ToolNameCodecError.invalidInternalName(name)
        }
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty }) else {
            throw ToolNameCodecError.invalidInternalName(name)
        }
    }

    private static func isModelScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 95, 97...122, 45:
            return true
        default:
            return false
        }
    }
}
