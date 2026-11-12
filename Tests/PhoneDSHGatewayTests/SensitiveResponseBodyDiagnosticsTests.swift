// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHGateway tests: controlled diagnostics keep the
// call kind and the status distinguishable without exposing an upstream body.

import Foundation
import XCTest
@testable import PhoneDSHGateway
import PhoneDSHAgentCore

final class SensitiveResponseBodyDiagnosticsTests: XCTestCase {
    private func decodedDiagnostic(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func message(_ data: Data) throws -> String {
        let object = try decodedDiagnostic(data)
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, SensitiveResponseBody.controlledErrorCode)
        return try XCTUnwrap(error["message"] as? String)
    }

    func testMCPDiagnosticKeepsTheGoldenBytes() {
        let data = SensitiveResponseBody.controlledDiagnostic(status: 401)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"error":{"code":-32000,"message":"MCP upstream returned HTTP 401; response body withheld"},"id":null,"jsonrpc":"2.0"}"#)
    }

    func testWebTool404NamesTargetRetrievalAndWithholdsTheBody() throws {
        let data = SensitiveResponseBody.controlledDiagnostic(status: 404, kind: .webTool)
        let text = try message(data)
        XCTAssertEqual(text,
                       "the web tool could not retrieve usable target content: "
                       + "the URL may be missing, blocked by the site, an unsupported "
                       + "content type, or have no extractable Markdown (HTTP 404). "
                       + "The upstream response body was withheld by the host.")
        XCTAssertFalse(text.contains("MCP"))
        let object = try decodedDiagnostic(data)
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertTrue(object["id"] is NSNull)
    }

    func testWebToolDiagnosticsDistinguishPolicyRateLimitAndServiceFailure() throws {
        XCTAssertTrue(try message(SensitiveResponseBody.controlledDiagnostic(
            status: 403, kind: .webTool)).contains("security policy rejected the target"))
        XCTAssertTrue(try message(SensitiveResponseBody.controlledDiagnostic(
            status: 401, kind: .webTool)).contains("rejected the saved API key"))
        XCTAssertTrue(try message(SensitiveResponseBody.controlledDiagnostic(
            status: 402, kind: .webTool)).contains("insufficient balance"))
        XCTAssertTrue(try message(SensitiveResponseBody.controlledDiagnostic(
            status: 429, kind: .webTool)).contains("rate limit was exceeded"))
        for status in [500, 502, 503, 504] {
            XCTAssertTrue(try message(SensitiveResponseBody.controlledDiagnostic(
                status: status, kind: .webTool)).contains("upstream web service failed"),
                          "HTTP \(status)")
        }
        // Every status keeps the real class and the withholding statement;
        // none of them claims to be an MCP endpoint.
        for status in [400, 401, 402, 403, 404, 408, 413, 429, 500, 504, 418] {
            let text = try message(SensitiveResponseBody.controlledDiagnostic(
                status: status, kind: .webTool))
            XCTAssertTrue(text.contains("HTTP \(status)"), "HTTP \(status): \(text)")
            XCTAssertTrue(text.contains("withheld by the host"), "HTTP \(status): \(text)")
            XCTAssertFalse(text.contains("MCP"), "HTTP \(status): \(text)")
        }
    }

    func testWebToolOversizeDiagnosticsDoNotClaimMCP() throws {
        XCTAssertTrue(try message(SensitiveResponseBody.controlledOversizeDiagnostic(
            kind: .webTool)).contains("the web tool response exceeded"))
        XCTAssertFalse(try message(SensitiveResponseBody.controlledOversizeDiagnostic(
            kind: .webTool)).contains("MCP"))
        let event = SensitiveResponseBody.controlledEventStreamOversizeEvent(kind: .webTool)
        XCTAssertTrue(String(decoding: event, as: UTF8.self).hasPrefix("data: "))
        XCTAssertFalse(String(decoding: event, as: UTF8.self).contains("MCP"))
        XCTAssertFalse(String(decoding: event, as: UTF8.self).contains("mcp"))
    }

    func testSensitiveResponseKindSelectsTheWebToolBeforeTheMCPFallback() throws {
        let webURL = try XCTUnwrap(URL(string: "https://api.deepseek.com/v1/tools/fetch"))
        let webRequest = GatewayRequest(method: "POST", url: webURL,
                                        body: Data(#"{"url":"https://example.com"}"#.utf8))
        XCTAssertEqual(ModelGateway.sensitiveResponseKind(
            webTool: true,
            request: webRequest,
            credential: Credential(kind: .bearer, value: "fixture-key"),
            admittedByMCPGrant: true), .webTool,
                       "the web route's diagnostic must not be classified as MCP")

        let mcpURL = try XCTUnwrap(URL(string: "http://127.0.0.1:9/mcp"))
        let mcpRequest = GatewayRequest(method: "POST", url: mcpURL)
        XCTAssertEqual(ModelGateway.sensitiveResponseKind(
            webTool: false,
            request: mcpRequest,
            credential: Credential(kind: .bearer, value: "mcp-token"),
            admittedByMCPGrant: true), .mcp)

        let placeholderRequest = GatewayRequest(
            method: "POST", url: mcpURL,
            headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder])
        XCTAssertEqual(ModelGateway.sensitiveResponseKind(
            webTool: false,
            request: placeholderRequest,
            credential: .none,
            admittedByMCPGrant: false), .mcp)

        let headerMap = Credential(kind: .headers(["authorization": "Bearer fixture"]),
                                   value: "")
        XCTAssertEqual(ModelGateway.sensitiveResponseKind(
            webTool: false,
            request: mcpRequest,
            credential: headerMap,
            admittedByMCPGrant: false), .mcp)

        let ordinaryURL = try XCTUnwrap(URL(string: "https://api.example.invalid/v1/models"))
        XCTAssertNil(ModelGateway.sensitiveResponseKind(
            webTool: false,
            request: GatewayRequest(method: "GET", url: ordinaryURL),
            credential: Credential(kind: .bearer, value: "fixture-key"),
            admittedByMCPGrant: false))
    }
}
