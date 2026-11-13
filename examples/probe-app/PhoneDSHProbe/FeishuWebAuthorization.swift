// SPDX-License-Identifier: MIT

import AuthenticationServices
import UIKit

enum FeishuWebAuthorizationError: Error, Equatable {
    /// The person dismissed Feishu's sheet or the alert that shares the
    /// existing Feishu login. This is not a connection failure.
    case cancelled
    /// No eligible window or another system-side presentation failure.
    case unavailable
}

/// Owns one native Feishu authorization sheet at a time and presents it on the
/// foreground window. The connector validates the returned callback itself;
/// this type only distinguishes user cancellation from a real failure.
@MainActor
final class FeishuWebAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var attemptID: UUID?

    func start(url: URL, callbackScheme: String) async throws -> URL {
        cancel()

        return try await withCheckedThrowingContinuation { continuation in
            let attemptID = UUID()
            self.attemptID = attemptID
            self.continuation = continuation

            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor [weak self] in
                    guard let self, self.attemptID == attemptID else { return }
                    self.finish(callbackURL: callbackURL, error: error)
                }
            }
            session.presentationContextProvider = self
            self.session = session

            guard session.start() else {
                self.session = nil
                self.continuation = nil
                self.attemptID = nil
                continuation.resume(throwing: FeishuWebAuthorizationError.unavailable)
                return
            }
        }
    }

    /// Dismisses a sheet that is still visible and resolves a pending `start`
    /// as cancelled. Calling this after completion is a no-op.
    func cancel() {
        let session = self.session
        self.session = nil
        self.attemptID = nil
        let continuation = self.continuation
        self.continuation = nil
        session?.cancel()
        continuation?.resume(throwing: FeishuWebAuthorizationError.cancelled)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScenes = scenes.filter { $0.activationState == .foregroundActive }
        let windows = (activeScenes.isEmpty ? scenes : activeScenes).flatMap(\.windows)
        return windows.first(where: { $0.isKeyWindow })
            ?? windows.first
            ?? ASPresentationAnchor()
    }

    private func finish(callbackURL: URL?, error: Error?) {
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        self.session = nil
        self.attemptID = nil

        if let error {
            continuation.resume(
                throwing: Self.isUserCancellation(error)
                    ? FeishuWebAuthorizationError.cancelled
                    : FeishuWebAuthorizationError.unavailable
            )
            return
        }
        guard let callbackURL else {
            continuation.resume(throwing: FeishuWebAuthorizationError.unavailable)
            return
        }
        continuation.resume(returning: callbackURL)
    }

    private static func isUserCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == ASWebAuthenticationSessionErrorDomain
            && error.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
    }
}
