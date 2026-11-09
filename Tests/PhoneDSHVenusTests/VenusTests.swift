// SPDX-License-Identifier: MIT
import XCTest
import Foundation
import CoreGraphics
import ImageIO
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHADB
import PhoneDSHLoopback
@testable import PhoneDSHVenus

private final class VisionSecrets: ModelProviderSecretStore, @unchecked Sendable {
    var value: String?
    func secret(for reference: String) throws -> String? { value }
    func setSecret(_ secret: String, for reference: String) throws { value = secret }
    func deleteSecret(for reference: String) throws { value = nil }
}
private final class VisionHTTP: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var code = 200
    static var content = "<action>Click(point=(500,750))</action>"
    static var finish = "stop"
    static var calls = 0
    static var last: URLRequest?
    static var body = Data()
    static func reset(code: Int = 200, content: String = "<action>Click(point=(500,750))</action>", finish: String = "stop") {
        lock.withLock { self.code = code; self.content = content; self.finish = finish; calls = 0; last = nil }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request.httpBody ?? Data()
        if captured.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count); if count <= 0 { break }; captured.append(contentsOf:buffer.prefix(count)) }
        }
        Self.lock.withLock { Self.body = captured }
        let (code, content, finish) = Self.lock.withLock { Self.calls += 1; Self.last = request; return (Self.code, Self.content, Self.finish) }
        let object: [String: Any] = request.url!.path.hasSuffix("/models") ? ["data":VisionModels.supported.map { ["id":$0] }] : ["choices":[["finish_reason":finish,"message":["content":content]]], "usage":["prompt_tokens":100,"completion_tokens":20]]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private actor VisionADB: ADBCommandExecuting {
    var images: [Data]
    var commands: [String] = []
    init(_ images: [Data]) { self.images = images }
    func shell(endpoint: ADBEndpoint, command: String, timeout: TimeInterval, outputLimit: Int) async throws -> ADBShellResult {
        commands.append(command)
        return ADBShellResult(stdout: images.count > 1 ? images.removeFirst() : images[0])
    }
}
private actor VisionFallback: NativeMCPServing {
    var requests: [LoopbackRequest] = []
    func handle(_ request: LoopbackRequest) async -> NativeMCPResponse {
        requests.append(request)
        let data = try! JSONSerialization.jsonObject(with: request.body) as! [String: Any]
        let method = data["method"] as? String
        let result: [String: Any] = method == "tools/list" ? ["tools":[]] : ["content":[["type":"text","text":"submitted"]],"isError":false]
        return NativeMCPResponse(body: try! JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0","id":data["id"] ?? 1,"result":result]))
    }
}
final class PhoneDSHVenusTests: XCTestCase {
    private func png(width: UInt32 = 1200, height: UInt32 = 2400) -> Data {
        var data = Data([137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82])
        for value in [width,height] { data.append(contentsOf: [UInt8(value >> 24),UInt8((value >> 16) & 255),UInt8((value >> 8) & 255),UInt8(value & 255)]) }
        data.append(Data(repeating: 0, count: 9)); return data
    }
    private func fixture() throws -> (VenusSettings, VenusClient) {
        let settings = VenusSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: VisionSecrets())
        try settings.save(VenusConfiguration(baseURL: "https://vision.example/v1"), key: "vision-fixture-key")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [VisionHTTP.self]
        return (settings, VenusClient(settings: settings, session: URLSession(configuration: config)))
    }
    private func rpc(_ name: String, _ args: [String: Any] = [:], key: String? = nil) throws -> LoopbackRequest {
        LoopbackRequest(method:"POST", path:"/mcp/native", headers:key.map { ["X-PDSH-Idempotency-Key":$0] } ?? [:], body:try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":name,"arguments":args]]))
    }
    private func result(_ response: NativeMCPResponse) throws -> [String: Any] { (try JSONSerialization.jsonObject(with: response.body) as! [String: Any])["result"] as! [String: Any] }
    private func text(_ response: NativeMCPResponse) throws -> String { (try result(response)["content"] as! [[String: Any]])[0]["text"] as! String }
    func testActionCoordinatesAndLiteralText() throws {
        let click = try VenusAction.parse("<think>hidden</think><action>Click(point=(500,999))</action>", width:1200,height:2400)
        XCTAssertEqual(click.tool,"android_tap"); XCTAssertEqual(click.arguments,["x":.number(600),"y":.number(2397)])
        let swipe = try VenusAction.parse("<action>Swipe(start=[0,500],end=(999,500))</action>",width:1000,height:2000)
        XCTAssertEqual(swipe.arguments["endX"],.number(999)); XCTAssertEqual(swipe.arguments["y"],.number(1000))
        let type = try VenusAction.parse("<action>Type(content='a\\\'b; $(test)')</action>",width:1,height:1)
        XCTAssertEqual(type.arguments["text"],.string("a'b; $(test)"))
    }
    func testRejectsCodeMalformedCoordinatesAndMultipleActions() {
        for value in ["Click(point=(500,500))", "<action>Click(point=(500,500)</action>", "<action>Click(point=(1000,500))</action>", "<action>Click(point=(-1,500))</action>", "<action>Click(point=(True,2))</action>", "<action>Click(point=__import__('os'))</action>", "<action>Click(point=(1,2)); PressHome()</action>", "<action>Click(point=(1,2),point=(3,4))</action>", "<action>PressHome()</action><action>PressBack()</action>", "<action>Type(content='中文')</action>"] {
            XCTAssertThrowsError(try VenusAction.parse(value,width:100,height:200),value)
        }
    }
    func testCompletionHasNoExecutableTool() throws {
        for name in ["Finished", "Answer", "CallUser"] {
            let proposal = try VenusAction.parse("<action>\(name)(content='done')</action>",width:1,height:1)
            XCTAssertNil(proposal.tool); XCTAssertEqual(proposal.message,"done")
        }
        XCTAssertNil(try VenusAction.parse("<action>Wait()</action>",width:1,height:1).tool)
    }
    func testCredentialsScopedAndNeverInPreferences() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = VenusSettings(defaults: defaults,secrets:VisionSecrets())
        XCTAssertThrowsError(try settings.key())
        XCTAssertThrowsError(try settings.save(VenusConfiguration(baseURL:"http://vision.example/v1"),key:"key"))
        try settings.save(VenusConfiguration(baseURL:"https://vision.example/v1"),key:"fixture-private-key")
        XCTAssertThrowsError(try settings.save(VenusConfiguration(baseURL:"https://other.example/v1"),key:nil))
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { String(describing:$0).contains("fixture-private-key") })
    }
    func testImageLimits() throws {
        XCTAssertEqual(try VenusClient.dimensions(png()).width,1200)
        XCTAssertThrowsError(try VenusClient.dimensions(Data()))
        XCTAssertThrowsError(try VenusClient.dimensions(png(width:0)))
        XCTAssertThrowsError(try VenusClient.dimensions(png(width:32768,height:32768)))
    }
    func testRequestOneImageNoToolsAndColdTimeout() async throws {
        VisionHTTP.reset(); let (_,client) = try fixture()
        let answer = try await client.query(question:"Tap Continue",png:png(width:120,height:240),planning:true)
        XCTAssertEqual(answer.inputTokens,100)
        let request = VisionHTTP.last!
        XCTAssertEqual(request.timeoutInterval,600)
        XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer vision-fixture-key")
        let body = try JSONSerialization.jsonObject(with:VisionHTTP.body) as! [String:Any]
        XCTAssertNil(body["tools"]); XCTAssertEqual(body["stream"] as? Bool,false)
        XCTAssertEqual((body["messages"] as! [[String:Any]]).count,2)
        XCTAssertEqual(VisionHTTP.calls,1)
    }
    func testModelCatalogIncludesSixAndOCRCannotPlan() async throws {
        VisionHTTP.reset(); let (_,client) = try fixture()
        let models = try await client.models(); XCTAssertEqual(models,VisionModels.supported)
        do { _ = try await client.query(question:"click",png:png(width:120,height:240),configuration:VenusConfiguration(baseURL:"https://vision.example/v1",model:"minicpm-ocr"),planning:true); XCTFail() }
        catch { XCTAssertEqual((error as? VenusFailure)?.code,"venus_ocr_only") }
        XCTAssertEqual(VisionHTTP.calls,1)
    }
    func testTruncatedAndHTTPFailuresNeverReplayed() async throws {
        let (_,client) = try fixture()
        VisionHTTP.reset(finish:"length")
        do { _ = try await client.query(question:"click",png:png(width:120,height:240),planning:true); XCTFail() }
        catch { XCTAssertEqual((error as? VenusFailure)?.code,"venus_incomplete") }
        XCTAssertEqual(VisionHTTP.calls,1)
        VisionHTTP.reset(code:503)
        do { _ = try await client.query(question:"click",png:png(width:120,height:240),planning:true); XCTFail() }
        catch { XCTAssertEqual((error as? VenusFailure)?.code,"venus_http_503") }
        XCTAssertEqual(VisionHTTP.calls,1)
    }
    func testReasoningAndCredentialRedaction() async throws {
        VisionHTTP.reset(content:"<think>private chain</think><action>Answer(content='vision-fixture-key')</action>")
        let (_,client) = try fixture()
        let answer = try await client.query(question:"read",png:png(width:120,height:240))
        XCTAssertFalse(answer.text.contains("private chain")); XCTAssertFalse(answer.text.contains("vision-fixture-key")); XCTAssertTrue(answer.text.contains("[redacted]"))
    }
}

extension PhoneDSHVenusTests {
    func testQuotedUITARSPointIsStillOnlyANumericLiteral() throws {
        let value = try VenusAction.parse("<action>Click(point='(500,750)')</action>",width:1200,height:2400)
        XCTAssertEqual(value.arguments,["x":.number(600),"y":.number(1800)])
        XCTAssertThrowsError(try VenusAction.parse("<action>Click(point='(500,750); evil()')</action>",width:1200,height:2400))
    }
}

extension PhoneDSHVenusTests {
    func testAutoGLMNativeActionWithoutExecutingProse() throws {
        let value = try VenusAction.parse("I should tap the button.\ndo(action=\"Tap\", element=[499,753])",width:1200,height:2000,model:"autoglm-phone-9b")
        XCTAssertEqual(value.tool,"android_tap")
        XCTAssertEqual(value.arguments["x"],.number(598))
        XCTAssertThrowsError(try VenusAction.parse("do(action=\"Tap\",element=[1,2])\ndo(action=\"Tap\",element=[3,4])",width:1200,height:2000,model:"autoglm-phone-9b"))
        let finish = try VenusAction.parse("finish(message=\"done\")",width:1200,height:2000,model:"autoglm-phone-9b")
        XCTAssertNil(finish.tool);XCTAssertEqual(finish.message,"done")
    }
    func testUITARSAbsoluteCoordinatesUseItsActualPreparedGeometry() throws {
        let value = try VenusAction.parse("Action: click(start_box='(364,903)')",width:1200,height:2000,model:"ui-tars-1.5-7b",coordinateWidth:728,coordinateHeight:1204)
        XCTAssertEqual(value.arguments,["x":.number(600),"y":.number(1500)])
        XCTAssertThrowsError(try VenusAction.parse("Action: click(start_box='(500,1300)')",width:1200,height:2000,model:"ui-tars-1.5-7b",coordinateWidth:728,coordinateHeight:1204))
        XCTAssertThrowsError(try VenusAction.parse("Action: click(start_box='(364,903)')",width:1200,height:2000,model:"ui-tars-1.5-7b"))
    }
    func testLargeScreenshotResizingAndUITARSAlignment() throws {
        let context = CGContext(data:nil,width:1200,height:2000,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:0,green:0,blue:1,alpha:1));context.fill(CGRect(x:0,y:0,width:1200,height:2000))
        let encoded = NSMutableData();let destination = CGImageDestinationCreateWithData(encoded,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
        for model in ["ui-venus-2-9b","autoglm-phone-9b","ui-tars-1.5-7b"] {
            let image = try VenusClient.prepareImage(encoded as Data,model:model)
            let size = try VenusClient.dimensions(image)
            XCTAssertLessThanOrEqual(max(size.width,size.height),1280)
            XCTAssertLessThanOrEqual(size.width*size.height,921600)
            if model == "ui-tars-1.5-7b" { XCTAssertEqual(size.width%28,0);XCTAssertEqual(size.height%28,0) }
            else { XCTAssertEqual(Double(size.width)/Double(size.height),0.6,accuracy:0.002) }
        }
    }
}

extension PhoneDSHVenusTests {
    func testNamespacedVenusThoughtAndStateAreNotReturned() async throws {
        let (_,client) = try fixture()
        VisionHTTP.reset(content:"<set:state><state>metadata</state></set:state><re:think>hidden deliberation</think>Final answer")
        let answer = try await client.query(question:"read",png:png(width:120,height:240))
        XCTAssertEqual(answer.text,"Final answer")
        VisionHTTP.reset(content:"<re:think>unfinished private deliberation")
        do { _ = try await client.query(question:"read",png:png(width:120,height:240));XCTFail() }
        catch { XCTAssertEqual((error as? VenusFailure)?.code,"venus_incomplete") }
    }
}
