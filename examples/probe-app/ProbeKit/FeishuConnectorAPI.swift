// SPDX-License-Identifier: MIT

import Foundation

public enum FeishuConnectorError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden
    case rateLimited
    case invalidResponse
    case serviceUnavailable
}

/// The two read-only Feishu OpenAPI calls the connector page needs. The user
/// access token is sent as a bearer token and is never logged, stored or put in
/// a URL; the App Secret never reaches the phone at all.
public struct FeishuConnectorAPI: Sendable {
    public struct Account: Equatable, Sendable {
        public let name: String
        public let openID: String
    }

    public struct File: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let type: String
        public let url: URL?

        /// The Feishu file type, in the page's own words.
        public var typeLabel: String {
            switch type {
            case "doc": return "旧版文档"
            case "docx": return "文档"
            case "sheet": return "表格"
            case "bitable": return "多维表格"
            case "mindnote": return "思维导图"
            case "folder": return "文件夹"
            case "shortcut": return "快捷方式"
            case "file": return "文件"
            default: return type
            }
        }
    }

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// A Feishu user_access_token is an opaque bearer value: printable ASCII
    /// without spaces, at least eight characters and well under 4 KiB. The
    /// shape is checked before it can be sent anywhere.
    public static func isValidToken(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        guard (8...4096).contains(bytes.count) else { return false }
        return bytes.allSatisfy { (33...126).contains($0) }
    }

    public func account(token: String) async throws -> Account {
        let data = try await get("authen/v1/user_info", query: [], token: token)
        let payload: UserInfoPayload = try decode(UserInfoPayload.self, from: data)
        guard !payload.data.name.isEmpty else { throw FeishuConnectorError.invalidResponse }
        return Account(name: payload.data.name, openID: payload.data.openID)
    }

    /// The root of the user's own cloud space. Feishu documents that a request
    /// without `folder_token` returns the whole root listing and does not
    /// paginate, so there is no page token to carry.
    public func files(token: String) async throws -> [File] {
        let query = [
            URLQueryItem(name: "page_size", value: "200"),
            URLQueryItem(name: "order_by", value: "EditedTime"),
            URLQueryItem(name: "direction", value: "DESC"),
        ]
        let data = try await get("drive/v1/files", query: query, token: token)
        let payload: FilesPayload = try decode(FilesPayload.self, from: data)
        return payload.data.files.map { raw in
            File(
                id: raw.token,
                name: raw.name,
                type: raw.type,
                url: raw.url.flatMap { value in
                    guard let url = URL(string: value), url.scheme?.lowercased() == "https" else {
                        return nil
                    }
                    return url
                }
            )
        }
    }

    private func get(
        _ path: String, query: [URLQueryItem], token: String
    ) async throws -> Data {
        guard Self.isValidToken(token) else { throw FeishuConnectorError.unauthorized }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "open.feishu.cn"
        components.path = "/open-apis/" + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw FeishuConnectorError.invalidResponse }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("phone-dsh", forHTTPHeaderField: "User-Agent")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (received, response) = try await session.data(for: request)
            guard let value = response as? HTTPURLResponse else {
                throw FeishuConnectorError.invalidResponse
            }
            data = received
            http = value
        } catch let error as FeishuConnectorError {
            throw error
        } catch is CancellationError {
            throw FeishuConnectorError.serviceUnavailable
        } catch {
            throw FeishuConnectorError.serviceUnavailable
        }

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw FeishuConnectorError.unauthorized
        case 403:
            throw FeishuConnectorError.forbidden
        case 429:
            throw FeishuConnectorError.rateLimited
        case 500...599:
            throw FeishuConnectorError.serviceUnavailable
        default:
            throw FeishuConnectorError.invalidResponse
        }

        // Feishu reports business failures as HTTP 200 with a non-zero code.
        let envelope: Envelope = try decode(Envelope.self, from: data)
        switch envelope.code {
        case 0:
            return data
        case 99991663, 99991661, 20005, 1061005:
            throw FeishuConnectorError.unauthorized
        case 99991672, 99991679, 1061004:
            throw FeishuConnectorError.forbidden
        case 99991400:
            throw FeishuConnectorError.rateLimited
        default:
            throw FeishuConnectorError.invalidResponse
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw FeishuConnectorError.invalidResponse
        }
    }

    private struct Envelope: Decodable {
        let code: Int
    }

    private struct UserInfoPayload: Decodable {
        struct Data: Decodable {
            let name: String
            let openID: String

            enum CodingKeys: String, CodingKey {
                case name
                case openID = "open_id"
            }
        }

        let data: Data
    }

    private struct FilesPayload: Decodable {
        struct Data: Decodable {
            let files: [RawFile]
        }

        struct RawFile: Decodable {
            let token: String
            let name: String
            let type: String
            let url: String?
        }

        let data: Data
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? { nil }
    }
}
