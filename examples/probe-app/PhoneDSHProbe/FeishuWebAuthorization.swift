// SPDX-License-Identifier: MIT

import AuthenticationServices
import ProbeKit
import UIKit

enum FeishuWebAuthorizationError: Error, Equatable {
    /// The person dismissed Feishu's sheet or the alert that shares the
    /// existing Feishu login. This is not a connection failure.
    case cancelled
    /// No eligible window or another system-side presentation failure.
    case unavailable
}

@MainActor
final class FeishuWebAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
    private struct Attempt {
        enum Transport {
            case native
            case web(ASWebAuthenticationSession)
        }

        let id: UUID
        let expectedState: String
        let continuation: CheckedContinuation<FeishuOAuthCallback, Error>
        var transport: Transport
    }

    private var attempt: Attempt?

    func start(url: URL, appLink: URL?, expectedState: String) async throws -> FeishuOAuthCallback {
        cancel()

        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let attempt = Attempt(
                id: UUID(),
                expectedState: expectedState,
                continuation: continuation,
                transport: .native
            )
            self.attempt = attempt

            guard let appLink else {
                self.startWebSession(url: url, attemptID: attempt.id)
                return
            }
            let attemptID = attempt.id
            UIApplication.shared.open(appLink, options: [.universalLinksOnly: true]) { [weak self] opened in
                guard !opened else { return }
                Task { @MainActor [weak self] in
                    self?.startWebSession(url: url, attemptID: attemptID)
                }
            }
        }
    }

    func handleCallback(_ url: URL) {
        guard let attempt,
              case .native = attempt.transport,
              let callback = try? FeishuOAuthCallbackValidator.validate(
                  url, expectedState: attempt.expectedState
              )
        else { return }

        resolve(.success(callback), attemptID: attempt.id)
    }

    func cancel() {
        guard let attempt = self.attempt else { return }
        self.attempt = nil
        if case .web(let session) = attempt.transport {
            session.cancel()
        }
        attempt.continuation.resume(throwing: FeishuWebAuthorizationError.cancelled)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScenes = scenes.filter { $0.activationState == .foregroundActive }
        let windows = (activeScenes.isEmpty ? scenes : activeScenes).flatMap(\.windows)
        return windows.first(where: { $0.isKeyWindow })
            ?? windows.first
            ?? ASPresentationAnchor()
    }

    private func startWebSession(url: URL, attemptID: UUID) {
        guard var attempt = self.attempt,
              attempt.id == attemptID,
              case .native = attempt.transport
        else { return }

        let session = ASWebAuthenticationSession(
            url: url, callbackURLScheme: FeishuOAuthConfiguration.callbackScheme
        ) { [weak self] callbackURL, error in
            Task { @MainActor [weak self] in
                guard let self, self.attempt?.id == attemptID else { return }
                self.finishWebSession(callbackURL: callbackURL, error: error)
            }
        }
        session.presentationContextProvider = self
        attempt.transport = .web(session)
        self.attempt = attempt

        if !session.start() {
            resolve(.failure(FeishuWebAuthorizationError.unavailable), attemptID: attemptID)
        }
    }

    private func finishWebSession(callbackURL: URL?, error: Error?) {
        guard let attempt = self.attempt else { return }

        if let error {
            resolve(
                .failure(Self.isUserCancellation(error)
                    ? FeishuWebAuthorizationError.cancelled
                    : FeishuWebAuthorizationError.unavailable),
                attemptID: attempt.id
            )
            return
        }
        guard let callbackURL else {
            resolve(.failure(FeishuWebAuthorizationError.unavailable), attemptID: attempt.id)
            return
        }
        do {
            let callback = try FeishuOAuthCallbackValidator.validate(
                callbackURL, expectedState: attempt.expectedState
            )
            resolve(.success(callback), attemptID: attempt.id)
        } catch {
            resolve(.failure(error), attemptID: attempt.id)
        }
    }

    private func resolve(_ result: Result<FeishuOAuthCallback, Error>, attemptID: UUID) {
        guard let attempt = self.attempt, attempt.id == attemptID else { return }
        self.attempt = nil
        attempt.continuation.resume(with: result)
    }

    private static func isUserCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == ASWebAuthenticationSessionErrorDomain
            && error.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
    }
}
