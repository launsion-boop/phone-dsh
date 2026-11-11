// SPDX-License-Identifier: MIT

import GoogleSignIn
import UIKit

@MainActor
enum GmailSignIn {
    static let readScope = "https://www.googleapis.com/auth/gmail.readonly"

    enum Failure: Error {
        case notAuthorized
        case readPermissionRequired
        case cannotPresent
    }

    static var isConfigured: Bool { callbackScheme != nil }

    private static var callbackScheme: String? {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              clientID.hasSuffix(".apps.googleusercontent.com"),
              clientID.split(separator: ".").count == 4,
              let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        else { return nil }
        let scheme = clientID.split(separator: ".").reversed().joined(separator: ".")
        return urlTypes.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains(scheme) == true } ? scheme : nil
    }

    static func handleCallback(_ url: URL) {
        guard let callbackScheme, url.scheme == callbackScheme else { return }
        _ = GIDSignIn.sharedInstance.handle(url)
    }

    static func restore() async throws -> Bool {
        let signIn = GIDSignIn.sharedInstance
        if signIn.currentUser == nil {
            guard signIn.hasPreviousSignIn() else { return false }
            _ = try await signIn.restorePreviousSignIn()
        }
        return signIn.currentUser != nil
    }

    static func connect() async throws {
        let signIn = GIDSignIn.sharedInstance
        guard let controller = presenter() else { throw Failure.cannotPresent }
        if let user = signIn.currentUser {
            if user.grantedScopes?.contains(readScope) != true {
                _ = try await user.addScopes([readScope], presenting: controller)
            }
        } else {
            _ = try await signIn.signIn(withPresenting: controller, hint: nil, additionalScopes: [readScope])
        }
    }

    static func accessToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else { throw Failure.notAuthorized }
        let refreshedUser = try await user.refreshTokensIfNeeded()
        if let grantedScopes = refreshedUser.grantedScopes, !grantedScopes.contains(readScope) {
            throw Failure.readPermissionRequired
        }
        return refreshedUser.accessToken.tokenString
    }

    static func disconnect() async -> Bool {
        let signIn = GIDSignIn.sharedInstance
        do {
            try await signIn.disconnect()
            return true
        } catch {
            signIn.signOut()
            return false
        }
    }

    static func signOut() { GIDSignIn.sharedInstance.signOut() }

    static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == kGIDSignInErrorDomain && error.code == -5
    }

    static func isInvalidGrant(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "org.openid.appauth.oauth_token" && error.code == -10
    }

    private static func presenter() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .compactMap(\.keyWindow)
            .first
        guard var controller = window?.rootViewController else { return nil }
        while let next = controller.presentedViewController { controller = next }
        return controller
    }
}
