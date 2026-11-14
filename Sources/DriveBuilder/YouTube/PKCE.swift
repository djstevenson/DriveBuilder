import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636): a one-time secret the sign-in
/// starts with and the token exchange proves possession of, so a code
/// intercepted on its way back to the loopback redirect is useless alone.
struct PKCE: Sendable, Equatable {
    let verifier: String
    let challenge: String

    /// A fresh random verifier and its S256 challenge.
    init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        self.init(verifier: Self.base64URL(Data(bytes)))
    }

    init(verifier: String) {
        self.verifier = verifier
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Base64 with the URL-safe alphabet and no padding, as the RFC wants.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
