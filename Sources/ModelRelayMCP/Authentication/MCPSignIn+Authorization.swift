import CryptoKit
import Foundation
import ModelRelay
import ModelRelayHTTP

extension MCPSignIn {
    /// The page to open for one sign-in, with a fresh PKCE verifier and state.
    public static func start(_ plan: Plan, client: Client, redirectURI: String) -> Attempt {
        let verifier = randomString(bytes: 32)
        let state = randomString(bytes: 16)

        var components = URLComponents(url: plan.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: plan.resource),
        ]
        if !plan.scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: plan.scopes.joined(separator: " "))) }
        components.queryItems = items

        return Attempt(url: components.url!, verifier: verifier, state: state)
    }

    /// Reads the page's redirect back to the app and trades its code for tokens.
    public static func finish(
        _ attempt: Attempt,
        callback: URL,
        plan: Plan,
        client: Client,
        redirectURI: String,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) async throws -> Tokens {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = item("error") { throw Failure.denied(item("error_description") ?? error) }
        guard item("state") == attempt.state, let code = item("code") else { throw Failure.cancelledOrWrongState }

        return try await token(plan, client: client, session: session, form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "code_verifier": attempt.verifier,
        ])
    }

    /// New tokens from a refresh token. Servers that don't send a new
    /// refresh token keep the old one valid.
    public static func refresh(
        _ tokens: Tokens,
        plan: Plan,
        client: Client,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) async throws -> Tokens {
        guard let refreshToken = tokens.refresh else { throw Failure.tokenRefused("there's no refresh token") }

        var refreshed = try await token(plan, client: client, session: session, form: [
            "grant_type": "refresh_token", "refresh_token": refreshToken,
        ])
        if refreshed.refresh == nil { refreshed.refresh = refreshToken }

        return refreshed
    }

    private static func token(_ plan: Plan, client: Client, session: URLSession, form: [String: String]) async throws -> Tokens {
        var fields = form
        fields["client_id"] = client.id
        fields["resource"] = plan.resource
        if let secret = client.secret { fields["client_secret"] = secret }

        var request = URLRequest(url: plan.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&").utf8)

        let (data, response) = try await session.data(for: request)

        guard let reply = HTTPResponse(data: data, response: response) else {
            throw Failure.tokenRefused("not an HTTP response")
        }
        let object: [String: Any]? = reply.jsonObject
        let refusal: String? = object.flatMap { HTTPResponse.errorMessage(in: $0, keys: ["error_description", "error"]) }

        try reply.validateSuccess(or: Failure.tokenRefused(refusal ?? "HTTP \(reply.status)"))

        guard let object else { throw Failure.tokenRefused("invalid JSON response") }
        guard let access = object["access_token"] as? String, !access.isEmpty else { throw Failure.tokenRefused(refusal ?? "no access token") }

        let lifetime = (object["expires_in"] as? NSNumber)?.doubleValue
        return Tokens(
            access: access,
            refresh: object["refresh_token"] as? String,
            expiresAt: lifetime.map { Date().addingTimeInterval($0) }
        )
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomString(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0 ..< bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
