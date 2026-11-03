// SPDX-License-Identifier: MIT

import Foundation

public extension GmailOAuthConfiguration {
    static let clientIDInfoKey = "PDSHGmailOAuthClientID"
    static let redirectURIInfoKey = "PDSHGmailOAuthRedirectURI"

    static func loadFromInfoBundle(_ bundle: Bundle = .main,
                                   scopes: [String] = [GmailScope.readOnly]) -> GmailOAuthConfiguration? {
        guard let clientID = bundle.object(forInfoDictionaryKey: clientIDInfoKey) as? String,
              !clientID.isEmpty,
              let redirect = bundle.object(forInfoDictionaryKey: redirectURIInfoKey) as? String,
              let redirectURI = URL(string: redirect), redirectURI.scheme != nil else { return nil }
        return GmailOAuthConfiguration(clientID: clientID, redirectURI: redirectURI, scopes: scopes)
    }
}
