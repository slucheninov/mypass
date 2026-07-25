import Foundation

/// Injects the loopback auth token into an outgoing request on ChromeHost's
/// behalf, so the token never has to be known by, or pass through, the
/// browser extension itself (background.js/content.js/popup.js never see it) —
/// an extra security property beyond what the design spec strictly requires.
public enum RelayTokenInjector {
    public enum RelayTokenInjectorError: Error {
        case invalidJSON
    }

    public static func injectToken(into requestJSON: Data, token: String) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: requestJSON) as? [String: Any] else {
            throw RelayTokenInjectorError.invalidJSON
        }
        object["token"] = token
        return try JSONSerialization.data(withJSONObject: object)
    }
}
