// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHAgentCore

public struct VenusProposal: Equatable, Sendable {
    public let action: String
    public let tool: String?
    public let arguments: [String: JSONValue]
    public let message: String
}

/// Parses only literal keyword arguments, never Python/eval or arbitrary shell.
/// Coordinate conversion follows the official UI-Venus-2 mobile 0..<1000 scale.
public enum VenusAction {
    public static func parse(_ response: String, width: Int, height: Int, model: String? = nil,coordinateWidth:Int? = nil,coordinateHeight:Int? = nil) throws -> VenusProposal {
        if model == "ui-tars-1.5-7b",!response.contains("<action>") {
            return try parseUITARS(response,width:width,height:height,coordinateWidth:coordinateWidth,coordinateHeight:coordinateHeight)
        }
        if model == "autoglm-phone-9b" { return try parseAutoGLM(response,width:width,height:height) }
        guard response.utf8.count <= 65536, (1...32768).contains(width), (1...32768).contains(height),
              let start = response.range(of: "<action>"), let end = response.range(of: "</action>", range: start.upperBound..<response.endIndex),
              response.range(of: "<action>", range: start.upperBound..<response.endIndex) == nil else { throw failure() }
        let call = String(response[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        var parser = LiteralParser(call)
        let (name, args) = try parser.call()
        func keys(_ allowed: Set<String>, required: Set<String> = []) throws {
            guard Set(args.keys).isSubset(of: allowed), required.isSubset(of: Set(args.keys)) else { throw failure() }
        }
        func point(_ key: String) throws -> (Int, Int) {
            var point = args[key]
            // UI-TARS sometimes wraps its numeric tuple in a quoted literal.
            // Parse that literal with the same restricted grammar, never eval.
            if case .string(let value) = point {
                var parser = LiteralParser(value)
                point = try parser.literal(); parser.whitespace()
                guard parser.i == parser.chars.count else { throw failure() }
            }
            let boundX = model == "ui-tars-1.5-7b" ? coordinateWidth : 1000
            let boundY = model == "ui-tars-1.5-7b" ? coordinateHeight : 1000
            guard let boundX,let boundY,boundX > 0,boundY > 0,
                  case .array(let values) = point, values.count == 2,
                  case .number(let x) = values[0], case .number(let y) = values[1], x.isFinite, y.isFinite,
                  x >= 0, y >= 0, x < Double(boundX), y < Double(boundY) else { throw failure() }
            return (Int(x * Double(width) / Double(boundX)), Int(y * Double(height) / Double(boundY)))
        }
        func text(_ key: String) throws -> String {
            guard case .string(let value) = args[key], value.utf8.count <= 4000, !value.utf8.contains(0) else { throw failure() }
            return value
        }
        func proposal(_ tool: String?, _ arguments: [String: JSONValue] = [:], _ message: String = "") -> VenusProposal {
            VenusProposal(action: name, tool: tool, arguments: arguments, message: message)
        }
        switch name {
        case "Click", "LongPress":
            try keys(["point", "box"])
            guard args.count == 1 else { throw failure() }
            let (x, y) = try point(args["point"] == nil ? "box" : "point")
            if name == "Click" { return proposal("android_tap", ["x":.number(Double(x)), "y":.number(Double(y))]) }
            return proposal("android_swipe", ["x":.number(Double(x)), "y":.number(Double(y)), "endX":.number(Double(x)), "endY":.number(Double(y)), "durationMs":.number(1000)])
        case "Swipe":
            try keys(["start", "end"], required: ["start", "end"])
            let (x, y) = try point("start"); let (endX, endY) = try point("end")
            return proposal("android_swipe", ["x":.number(Double(x)), "y":.number(Double(y)), "endX":.number(Double(endX)), "endY":.number(Double(endY)), "durationMs":.number(300)])
        case "Type":
            try keys(["content"], required: ["content"])
            let value = try text("content")
            guard !value.isEmpty, value.utf8.count <= 1000, value.utf8.allSatisfy({ (32...126).contains($0) }), !value.contains("%s") else { throw VenusFailure("venus_input", "该操作需要 Unicode 输入法；当前 ADB 文本输入仅支持可打印 ASCII") }
            return proposal("android_input_text", ["text":.string(value)])
        case "PressBack", "PressHome", "PressEnter", "PressRecent":
            try keys([])
            let key = ["PressBack":"BACK", "PressHome":"HOME", "PressEnter":"ENTER", "PressRecent":"APP_SWITCH"][name]!
            return proposal("android_key", ["key":.string(key)])
        case "Wait", "GetScreenshot":
            try keys([])
            return proposal(nil, [:], name == "Wait" ? "Wait briefly, then request a fresh UI-Venus step." : "Request a fresh UI-Venus step; do not reuse screenshot coordinates.")
        case "CallUser", "Answer", "Finished":
            try keys(["content"], required: ["content"])
            return proposal(nil, [:], try text("content"))
        case "DoubleClick", "Drag", "LaunchApp":
            throw VenusFailure("venus_action_unsupported", "UI-Venus 建议了尚未支持的操作 \(name)；未执行任何动作")
        default: throw failure()
        }
    }
    private static func parseUITARS(_ response:String,width:Int,height:Int,coordinateWidth:Int?,coordinateHeight:Int?) throws -> VenusProposal {
        guard response.utf8.count <= 65536 else { throw failure() }
        let lines = response.split(separator:"\n").map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let actions = lines.filter { $0.hasPrefix("Action:") }
        guard actions.count == 1,let action = actions.first,lines.last == action else { throw failure() }
        var parser = LiteralParser(String(action.dropFirst(7)).trimmingCharacters(in:.whitespaces))
        let (name,args) = try parser.call()
        func encoded(_ key:String) throws -> String { guard let value = args[key] else { throw failure() };return String(decoding:try value.encoded(),as:UTF8.self) }
        var translated:String
        switch name {
        case "click","long_press":
            guard Set(args.keys) == ["start_box"] else { throw failure() }
            translated = (name == "click" ? "Click" : "LongPress") + "(point=" + (try encoded("start_box")) + ")"
        case "drag":
            guard Set(args.keys) == ["start_box","end_box"] else { throw failure() }
            translated = "Swipe(start=" + (try encoded("start_box")) + ",end=" + (try encoded("end_box")) + ")"
        case "type","finished","call_user":
            guard Set(args.keys) == ["content"] else { throw failure() }
            translated = ["type":"Type","finished":"Finished","call_user":"CallUser"][name]! + "(content=" + (try encoded("content")) + ")"
        case "press_home","press_back","wait":
            guard args.isEmpty else { throw failure() }
            translated = ["press_home":"PressHome()","press_back":"PressBack()","wait":"Wait()"][name]!
        default: throw failure()
        }
        return try parse("<action>"+translated+"</action>",width:width,height:height,model:"ui-tars-1.5-7b",coordinateWidth:coordinateWidth,coordinateHeight:coordinateHeight)
    }
    private static func parseAutoGLM(_ response:String,width:Int,height:Int) throws -> VenusProposal {
        guard response.utf8.count <= 65536 else { throw failure() }
        let lines = response.split(separator:"\n").map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let candidates = lines.filter { $0.hasPrefix("do(") || $0.hasPrefix("finish(") }
        guard candidates.count == 1,let call = candidates.first,lines.last == call else { throw failure() }
        var parser = LiteralParser(call);let (name,args) = try parser.call()
        func string(_ key:String) throws -> String { guard case .string(let value) = args[key] else { throw failure() };return value }
        func encoded(_ key:String) throws -> String { guard let value = args[key] else { throw failure() }; return String(decoding:try value.encoded(),as:UTF8.self) }
        var translated:String
        if name == "finish",Set(args.keys) == ["message"] { translated = "Finished(content=" + (try encoded("message")) + ")" }
        else {
            guard name == "do" else { throw failure() }
            let action = try string("action")
            switch action {
            case "Tap","Long Press":
                guard Set(args.keys) == ["action","element"] else { throw failure() }
                translated = (action == "Tap" ? "Click" : "LongPress") + "(point=" + (try encoded("element")) + ")"
            case "Swipe":
                guard Set(args.keys) == ["action","start","end"] else { throw failure() }
                translated = "Swipe(start=" + (try encoded("start")) + ",end=" + (try encoded("end")) + ")"
            case "Type":
                guard Set(args.keys) == ["action","text"] else { throw failure() }
                translated = "Type(content=" + (try encoded("text")) + ")"
            case "Back","Home","Enter":
                guard Set(args.keys) == ["action"] else { throw failure() }
                translated = ["Back":"PressBack()","Home":"PressHome()","Enter":"PressEnter()"][action]!
            case "Wait":
                guard Set(args.keys) == ["action"] else { throw failure() }
                translated = "Wait()"
            default: throw VenusFailure("venus_action_unsupported","AutoGLM 建议了尚未支持的操作；未执行")
            }
        }
        return try parse("<action>"+translated+"</action>",width:width,height:height)
    }
    private static func failure() -> VenusFailure { VenusFailure("venus_action", "UI-Venus 操作格式或坐标无效；未执行任何动作") }

    private struct LiteralParser {
        let chars: [Character]
        var i = 0
        init(_ text: String) { chars = Array(text) }
        mutating func whitespace() { while i < chars.count, chars[i].isWhitespace { i += 1 } }
        mutating func consume(_ c: Character) -> Bool { whitespace(); if i < chars.count, chars[i] == c { i += 1; return true }; return false }
        mutating func identifier() throws -> String {
            whitespace(); let start = i
            while i < chars.count, chars[i].isASCII, chars[i].isLetter || chars[i] == "_" { i += 1 }
            guard i > start else { throw failure() }; return String(chars[start..<i])
        }
        mutating func call() throws -> (String, [String: JSONValue]) {
            let name = try identifier(); guard consume("(") else { throw failure() }
            var values: [String: JSONValue] = [:]
            if !consume(")") {
                while true {
                    let key = try identifier(); guard values[key] == nil, consume("=") else { throw failure() }
                    values[key] = try literal()
                    if consume(")") { break }
                    guard consume(",") else { throw failure() }
                }
            }
            whitespace(); guard i == chars.count else { throw failure() }; return (name, values)
        }
        mutating func literal() throws -> JSONValue {
            whitespace(); guard i < chars.count else { throw failure() }
            if chars[i] == "'" || chars[i] == "\"" {
                let quote = chars[i]; i += 1; var value = ""
                while i < chars.count {
                    let c = chars[i]; i += 1
                    if c == quote { return .string(value) }
                    if c == "\\" {
                        guard i < chars.count else { throw failure() }
                        let escaped = chars[i]; i += 1
                        switch escaped {
                        case "\\", "'", "\"": value.append(escaped)
                        case "n": value.append("\n")
                        case "r": value.append("\r")
                        case "t": value.append("\t")
                        default: throw failure()
                        }
                    } else { value.append(c) }
                }
                throw failure()
            }
            if chars[i] == "(" || chars[i] == "[" {
                let close: Character = chars[i] == "(" ? ")" : "]"; i += 1
                let x = try number(); guard consume(",") else { throw failure() }
                let y = try number(); guard consume(close) else { throw failure() }
                return .array([.number(x), .number(y)])
            }
            return .number(try number())
        }
        mutating func number() throws -> Double {
            whitespace(); let start = i
            while i < chars.count, "0123456789.-+eE".contains(chars[i]) { i += 1 }
            guard i > start, let value = Double(String(chars[start..<i])), value.isFinite else { throw failure() }; return value
        }
    }
}
