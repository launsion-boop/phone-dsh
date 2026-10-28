// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: handoff replication client.
//
// PLAN §2.5 (D15) and spec/v1/handoff.md §1–§6. ``HandoffClient``
// performs the phone -> remote sequence over TLS: fence CAS, streamed snapshot,
// contiguous WAL tail and remote admission confirmation; ``reclaim(token:)``
// is the return path. Every request carries the DSH Remote Bearer credential
// obtained from the injected ``CredentialProvider`` (never the model
// credential), and a non-https endpoint is refused before any bytes are built.

import Foundation
import PhoneDSHAgentCore
import PhoneDSHLog
import PhoneDSHWire

/// Configuration of the handoff client (handoff.md §1).
public struct HandoffClientConfiguration: Equatable, Sendable {
    /// Base URL of the remote DSH host; must be `https`.
    public var endpoint: URL
    /// Credential scope of the DSH Remote Bearer token.
    public var credentialService: String

    public init(endpoint: URL, credentialService: String = "dsh-remote") {
        self.endpoint = endpoint
        self.credentialService = credentialService
    }

    /// Validates the endpoint before any request or local intent is written.
    ///
    /// The remote credential travels in the `Authorization` header, so a URL
    /// userinfo, query or fragment is never allowed: those components could
    /// carry a secret into `handoff-intent.json`, a log or a replica. A base
    /// path is legal because a deployment may be mounted below `/`.
    func validateEndpoint() throws {
        guard endpoint.scheme?.lowercased() == "https",
              endpoint.host?.isEmpty == false else {
            throw HandoffError.cleartextEndpoint
        }
        guard let components = URLComponents(url: endpoint,
                                             resolvingAgainstBaseURL: false) else {
            throw HandoffError.invalidEndpoint("the endpoint is not a valid URL")
        }
        guard components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw HandoffError.invalidEndpoint(
                "the endpoint must not carry userinfo, a query or a fragment")
        }
    }

    /// The non-secret endpoint identity persisted with the authority intent.
    /// It is validated first, so a URL credential or query can never be
    /// written to the workspace.
    func endpointIdentity() throws -> String {
        try validateEndpoint()
        return endpoint.absoluteString
    }
}

/// One validated reclaim response: metadata plus the tar already on disk.
public struct HandoffReclaimDownload: Sendable {
    public var metadata: HandoffReclaimMetadata
    public var payloadURL: URL
    public var payloadBytes: Int
    public var payloadSHA256: String
    private var removeWhenDone: Bool

    public init(metadata: HandoffReclaimMetadata, payloadURL: URL,
                payloadBytes: Int, payloadSHA256: String,
                removeWhenDone: Bool = true) {
        self.metadata = metadata
        self.payloadURL = payloadURL
        self.payloadBytes = payloadBytes
        self.payloadSHA256 = payloadSHA256
        self.removeWhenDone = removeWhenDone
    }

    public func cleanup() {
        guard removeWhenDone else { return }
        try? FileManager.default.removeItem(at: payloadURL)
    }
}

/// The client of `/v1/handoff/*` (handoff.md §2–§6).
public struct HandoffClient: Sendable {
    public let configuration: HandoffClientConfiguration
    private let transport: any HandoffHTTPTransport
    private let credentialProvider: any CredentialProvider

    /// - Throws: ``HandoffError/cleartextEndpoint`` when the endpoint is not
    ///   `https`, or ``HandoffError/invalidEndpoint(_:)`` when it carries
    ///   userinfo, a query or a fragment.
    public init(configuration: HandoffClientConfiguration,
                transport: any HandoffHTTPTransport,
                credentialProvider: any CredentialProvider) throws {
        try configuration.validateEndpoint()
        self.configuration = configuration
        self.transport = transport
        self.credentialProvider = credentialProvider
    }

    private var scope: CredentialScope {
        CredentialScope(service: configuration.credentialService)
    }

    // MARK: - Fence (§2)

    /// `POST /v1/handoff/fence`: generation CAS and the reclaim token.
    public func fence(expectedGeneration: UInt64,
                      walSeq: UInt64) async throws -> HandoffFenceResponse {
        let request = HandoffFenceRequest(expectedGeneration: expectedGeneration,
                                          walSeq: walSeq)
        let data = try HandoffJSON.encode(request)
        let response = try await post(path: "v1/handoff/fence", body: .data(data),
                                      contentType: "application/json")
        let decoded: HandoffFenceResponse = try decode(response)
        try decoded.validate(expectedGeneration: expectedGeneration, walSeq: walSeq)
        return decoded
    }

    // MARK: - Snapshot (§3)

    /// `POST /v1/handoff/snapshot`: the full uncompressed tar, streamed from
    /// the source file.
    public func uploadSnapshot(_ upload: HandoffPreparedUpload,
                               generation: UInt64) async throws -> HandoffSnapshotResponse {
        try upload.validate()
        try verifyPayloadSize(upload.snapshotURL, expected: upload.snapshotBytes)
        let metadata = HandoffSnapshotMetadata(
            generation: generation,
            materializedUptoMseq: upload.baseMseq,
            walSeq: upload.walSeq,
            payloadBytes: UInt64(upload.snapshotBytes),
            payloadSha256: upload.snapshotSHA256)
        try metadata.validate()
        let metaData = try HandoffJSON.encode(metadata)
        let response = try await postFramed(path: "v1/handoff/snapshot",
                                            metadata: metaData,
                                            payloadFile: upload.snapshotURL)
        let decoded: HandoffSnapshotResponse = try decode(response)
        guard decoded.materializedUptoMseq == upload.baseMseq else {
            throw HandoffError.invalidResponse("snapshot response changed the base")
        }
        guard decoded.snapshotSha256 == upload.snapshotSHA256 else {
            throw HandoffError.invalidResponse("snapshot response changed the hash")
        }
        guard decoded.fence.owner == HandoffLimits.remoteOwner,
              decoded.fence.generation == generation,
              decoded.fence.walSeq == upload.walSeq else {
            throw HandoffError.invalidResponse("snapshot response names another fence")
        }
        return decoded
    }

    // MARK: - Segments (§4)

    /// `POST /v1/handoff/segments`: the complete segment files covering
    /// `(upload.baseMseq, upload.walSeq]`, and the remote admission
    /// confirmation. A closed admission is a failed handoff.
    public func uploadSegments(_ upload: HandoffPreparedUpload,
                               generation: UInt64) async throws -> HandoffSegmentsResponse {
        try upload.validate()
        try verifyPayloadSize(upload.segmentsURL, expected: upload.segmentsBytes)
        let metadata = HandoffSegmentsMetadata(
            generation: generation,
            baseMseq: upload.baseMseq,
            walSeq: upload.walSeq,
            segments: upload.segments,
            payloadBytes: UInt64(upload.segmentsBytes),
            payloadSha256: upload.segmentsSHA256)
        try metadata.validate()
        let metaData = try HandoffJSON.encode(metadata)
        let response = try await postFramed(path: "v1/handoff/segments",
                                            metadata: metaData,
                                            payloadFile: upload.segmentsURL)
        let decoded: HandoffSegmentsResponse = try decode(response)
        try decoded.validate(expectedBase: upload.baseMseq,
                             expectedWalSeq: upload.walSeq)
        guard decoded.admission == .open else {
            throw HandoffError.applyFailed(
                "the remote did not open admission after the segments")
        }
        return decoded
    }

    // MARK: - Reclaim (§5)

    /// `POST /v1/handoff/reclaim`: returns the metadata and streams the
    /// returned segment tar to a temporary file.
    public func reclaim(token: String) async throws -> HandoffReclaimDownload {
        guard HandoffHex.isLowercaseHex(token, count: 32) else {
            throw HandoffError.unauthorized
        }
        let request = HandoffReclaimRequest(reclaimToken: token)
        let data = try HandoffJSON.encode(request)
        let credential = try await bearerCredential()
        let http = makeRequest(path: "v1/handoff/reclaim",
                               method: "POST",
                               body: .data(data),
                               contentType: "application/json",
                               credential: credential)
        let first: HandoffHTTPDownload
        do {
            first = try await transport.download(http)
        } catch let error as HandoffError {
            throw error
        } catch {
            throw HandoffError.transport("reclaim request failed")
        }
        var download = first
        if download.status == 401 {
            download.cleanup()
            await credentialProvider.invalidate(credential, for: scope)
            let refreshed = try await bearerCredential()
            let retry = makeRequest(path: "v1/handoff/reclaim",
                                    method: "POST",
                                    body: .data(data),
                                    contentType: "application/json",
                                    credential: refreshed)
            do {
                download = try await transport.download(retry)
            } catch let error as HandoffError {
                throw error
            } catch {
                throw HandoffError.transport("reclaim request failed")
            }
        }
        guard (200..<300).contains(download.status) else {
            let error = mapDownloadError(download)
            download.cleanup()
            throw error
        }
        return try extractReclaim(download)
    }

    // MARK: - HTTP plumbing

    private func post(path: String, body: HandoffHTTPBody,
                      contentType: String) async throws -> HandoffHTTPResponse {
        let credential = try await bearerCredential()
        do {
            let response = try await send(path: path, body: body,
                                          contentType: contentType,
                                          credential: credential)
            guard response.status == 401 else { return response }
        } catch let error as HandoffError {
            throw error
        } catch {
            throw HandoffError.transport("handoff request failed")
        }
        await credentialProvider.invalidate(credential, for: scope)
        let refreshed = try await bearerCredential()
        do {
            return try await send(path: path, body: body,
                                  contentType: contentType,
                                  credential: refreshed)
        } catch let error as HandoffError {
            throw error
        } catch {
            throw HandoffError.transport("handoff request failed")
        }
    }

    private func postFramed(path: String, metadata: Data,
                            payloadFile: URL) async throws -> HandoffHTTPResponse {
        let prefix = try HandoffFrameCodec.prefix(metadata: metadata)
        return try await post(path: path,
                              body: .framed(prefix: prefix, payloadFile: payloadFile),
                              contentType: "application/octet-stream")
    }

    private func send(path: String, body: HandoffHTTPBody, contentType: String,
                      credential: Credential) async throws -> HandoffHTTPResponse {
        let request = makeRequest(path: path, method: "POST", body: body,
                                  contentType: contentType, credential: credential)
        do {
            return try await transport.send(request)
        } catch let error as HandoffError {
            throw error
        } catch {
            throw HandoffError.transport("handoff request failed")
        }
    }

    private func makeRequest(path: String, method: String, body: HandoffHTTPBody,
                             contentType: String,
                             credential: Credential) -> HandoffHTTPRequest {
        var request = HandoffHTTPRequest(method: method,
                                         url: configuration.endpoint
                                            .appendingPathComponent(path),
                                         body: body)
        request.headers["Accept"] = "application/json"
        request.headers["Cache-Control"] = "no-store"
        request.headers["Content-Type"] = contentType
        switch credential.kind {
        case .bearer:
            request.headers["Authorization"] = "Bearer \(credential.value)"
        case .apiKey(let header):
            request.headers[header] = credential.value
        case .headers(let headers):
            for (header, value) in headers { request.headers[header] = value }
        case .none:
            break
        }
        return request
    }

    private func bearerCredential() async throws -> Credential {
        let credential: Credential
        do {
            credential = try await credentialProvider.credential(for: scope)
        } catch {
            throw HandoffError.unauthorized
        }
        guard case .bearer = credential.kind, !credential.value.isEmpty else {
            throw HandoffError.unauthorized
        }
        return credential
    }

    private func verifyPayloadSize(_ url: URL, expected: Int) throws {
        let actual = try HandoffFile.fileSize(url)
        guard actual == expected else {
            throw HandoffError.invalidResponse("payload file changed size before upload")
        }
    }

    private func decode<T: Decodable>(_ response: HandoffHTTPResponse) throws -> T {
        guard (200..<300).contains(response.status) else {
            throw mapError(response)
        }
        do {
            return try JSONDecoder().decode(T.self, from: response.bodyData)
        } catch {
            throw HandoffError.invalidResponse("malformed handoff JSON response")
        }
    }

    private func mapError(_ response: HandoffHTTPResponse) -> HandoffError {
        let envelope = try? JSONDecoder().decode(HandoffErrorEnvelope.self,
                                                 from: response.bodyData)
        let code = envelope?.error.code
        let message = envelope?.error.message ?? "HTTP \(response.status)"
        switch response.status {
        case 401:
            return .unauthorized
        case 409:
            switch code {
            case "fence_conflict": return .fenceConflict
            case "stale_generation": return .staleGeneration
            case "snapshot_conflict": return .snapshotConflict
            case "segments_gap": return .segmentsGap
            default: return .badRequest(code ?? "conflict")
            }
        case 400:
            if code == "payload_mismatch" {
                return .payloadMismatch(message)
            }
            return .badRequest(code ?? "bad_request")
        case 429, 500...599:
            return .internalFailure(message)
        default:
            return .internalFailure(message)
        }
    }

    private func mapDownloadError(_ download: HandoffHTTPDownload) -> HandoffError {
        let data = (try? Data(contentsOf: download.bodyURL)) ?? Data()
        return mapError(HandoffHTTPResponse(status: download.status,
                                            headers: download.headers,
                                            bodyData: data))
    }

    // MARK: - Framed response extraction

    private func extractReclaim(_ download: HandoffHTTPDownload) throws
        -> HandoffReclaimDownload {
        var succeeded = false
        var payloadURL: URL?
        defer {
            download.cleanup()
            if !succeeded, let payloadURL {
                try? FileManager.default.removeItem(at: payloadURL)
            }
        }
        let total = try HandoffFile.fileSize(download.bodyURL)
        guard total >= 4 else {
            throw HandoffError.invalidResponse("reclaim frame is shorter than meta_len")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: download.bodyURL)
        } catch {
            throw HandoffError.invalidResponse("reclaim frame is unreadable")
        }
        defer { try? handle.close() }

        let lengthBytes = try readExactly(handle, count: 4)
        let metaLength = Int(lengthBytes[0]) << 24 | Int(lengthBytes[1]) << 16
            | Int(lengthBytes[2]) << 8 | Int(lengthBytes[3])
        guard metaLength >= 1, metaLength <= HandoffLimits.maximumMetadataBytes else {
            throw HandoffError.invalidResponse("reclaim meta_len is outside 1...65536")
        }
        let metadataBytes = try readExactly(handle, count: metaLength)
        let payloadBytes = total - 4 - metaLength
        guard payloadBytes >= 0,
              payloadBytes <= HandoffLimits.maximumPayloadBytes else {
            throw HandoffError.payloadTooLarge(bytes: max(0, payloadBytes))
        }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-handoff-reclaim-\(UUID().uuidString).tar")
        guard FileManager.default.createFile(atPath: target.path, contents: nil),
              let writer = FileHandle(forWritingAtPath: target.path) else {
            throw HandoffError.invalidResponse("cannot buffer the reclaim payload")
        }
        payloadURL = target
        let hasher = SHA256.Hasher()
        do {
            var remaining = payloadBytes
            while remaining > 0 {
                let chunk = try readExactly(handle, count: min(remaining, 256 * 1024))
                hasher.update(chunk)
                try writer.write(contentsOf: chunk)
                remaining -= chunk.count
            }
            try writer.close()
        } catch {
            try? writer.close()
            throw error
        }
        let digest = hasher.hexDigest
        let metadata: HandoffReclaimMetadata
        do {
            metadata = try JSONDecoder().decode(HandoffReclaimMetadata.self,
                                                from: metadataBytes)
        } catch {
            throw HandoffError.invalidResponse("malformed reclaim metadata")
        }
        do {
            try metadata.validate()
        } catch let error as HandoffError {
            throw error
        } catch {
            throw HandoffError.invalidResponse("invalid reclaim metadata")
        }
        guard UInt64(payloadBytes) == metadata.payloadBytes else {
            throw HandoffError.payloadMismatch("reclaim payload length mismatch")
        }
        guard digest == metadata.payloadSha256 else {
            throw HandoffError.payloadMismatch("reclaim payload hash mismatch")
        }
        succeeded = true
        return HandoffReclaimDownload(metadata: metadata, payloadURL: target,
                                      payloadBytes: payloadBytes,
                                      payloadSHA256: digest,
                                      removeWhenDone: true)
    }

    private func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: count - data.count)
            } catch {
                throw HandoffError.invalidResponse("handoff response is unreadable")
            }
            guard let chunk, !chunk.isEmpty else {
                throw HandoffError.invalidResponse("handoff response is truncated")
            }
            data.append(chunk)
        }
        return data
    }
}
