import Foundation
import Security
import CryptoKit
import BaseChatInference

public protocol MCPOAuthRedirectListener: Sendable {
    func authorize(
        authorizationURL: URL,
        callbackURLScheme: String,
        prefersEphemeralSession: Bool
    ) async throws -> URL
}

public struct MCPOAuthTokens: Sendable, Codable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]
    public let tokenType: String
    public let issuer: URL
    public let subjectIdentifier: String?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        scopes: [String],
        tokenType: String = "Bearer",
        issuer: URL,
        subjectIdentifier: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.tokenType = tokenType
        self.issuer = issuer
        self.subjectIdentifier = subjectIdentifier
    }
}

public struct MCPOAuthTokenStore: Sendable {
    public typealias Read = @Sendable (UUID) async throws -> MCPOAuthTokens?
    public typealias Write = @Sendable (MCPOAuthTokens, UUID) async throws -> Void
    public typealias Delete = @Sendable (UUID) async throws -> Void

    public let read: Read
    public let write: Write
    public let delete: Delete

    public init(read: @escaping Read, write: @escaping Write, delete: @escaping Delete) {
        self.read = read
        self.write = write
        self.delete = delete
    }

    public static let keychain = MCPOAuthTokenStore.inMemory()

    public static func inMemory() -> MCPOAuthTokenStore {
        actor Storage {
            var values: [UUID: MCPOAuthTokens] = [:]
            func read(_ id: UUID) -> MCPOAuthTokens? { values[id] }
            func write(_ tokens: MCPOAuthTokens, _ id: UUID) { values[id] = tokens }
            func delete(_ id: UUID) { values.removeValue(forKey: id) }
        }
        let storage = Storage()
        return .init(
            read: { id in await storage.read(id) },
            write: { tokens, id in await storage.write(tokens, id) },
            delete: { id in await storage.delete(id) }
        )
    }

    public static func custom(
        read: @escaping Read,
        write: @escaping Write,
        delete: @escaping Delete
    ) -> MCPOAuthTokenStore {
        .init(read: read, write: write, delete: delete)
    }
}

private struct OAuthProtectedResourceMetadata: Decodable {
    let authorizationServers: [URL]?

    private enum CodingKeys: String, CodingKey {
        case authorizationServers = "authorization_servers"
    }
}

private struct OAuthAuthorizationServerMetadata: Decodable {
    let issuer: URL
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let registrationEndpoint: URL?

    private enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
    }
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?
    let scope: String?
    let tokenType: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }
}

private struct OAuthTokenErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private struct OAuthDynamicClientRegistrationResponse: Decodable {
    let clientID: String

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
    }
}

public actor MCPOAuthAuthorization: MCPAuthorization {
    private let descriptor: MCPAuthorizationDescriptor.OAuthDescriptor
    private let serverID: UUID
    private let resourceURL: URL
    private let redirectListener: any MCPOAuthRedirectListener
    private let tokenStore: MCPOAuthTokenStore
    private let random: @Sendable () -> Data
    private let session: URLSession
    private let currentDate: @Sendable () -> Date

    private var cachedAuthorizationMetadata: OAuthAuthorizationServerMetadata?
    private var cachedResourceMetadataURL: URL?
    private var cachedRegisteredClientID: String?

    public init(
        descriptor: MCPAuthorizationDescriptor.OAuthDescriptor,
        serverID: UUID,
        resourceURL: URL,
        redirectListener: any MCPOAuthRedirectListener,
        tokenStore: MCPOAuthTokenStore = .keychain,
        clock: any Clock<Duration> = ContinuousClock(),
        random: @escaping @Sendable () -> Data = { Data() },
        session: URLSession = .shared,
        currentDate: @escaping @Sendable () -> Date = Date.init
    ) {
        self.descriptor = descriptor
        self.serverID = serverID
        self.resourceURL = resourceURL
        self.redirectListener = redirectListener
        self.tokenStore = tokenStore
        self.random = random
        self.session = session
        self.currentDate = currentDate
        _ = clock
    }

    public func authorizationHeader(for requestURL: URL) async throws -> String? {
        try MCPSSRFPolicy.validateOAuthURL(requestURL, label: "oauth request")
        guard Self.isSameOrigin(lhs: requestURL, rhs: resourceURL) else {
            return nil
        }

        let tokens = try await activeTokens()
        try validateBearerTransmission(tokens)
        return "\(tokens.tokenType) \(tokens.accessToken)"
    }

    public func handleUnauthorized(statusCode: Int, body: Data) async throws -> AuthRetryDecision {
        _ = body
        try MCPSSRFPolicy.validateOAuthURL(resourceURL, label: "resource")
        guard statusCode == 401 || statusCode == 403 else {
            return .fail(.authorizationFailed("unexpected status \(statusCode)"))
        }

        guard let existing = try await tokenStore.read(serverID) else {
            return .fail(.authorizationRequired(buildAuthorizationRequest()))
        }
        guard let refreshToken = existing.refreshToken else {
            return .fail(.authorizationRequired(buildAuthorizationRequest()))
        }

        do {
            let metadata = try await discoverAuthorizationMetadata()
            let refreshed = try await exchangeRefreshToken(
                refreshToken,
                metadata: metadata,
                existing: existing
            )
            try await tokenStore.write(refreshed, serverID)
            return .retry
        } catch let error as MCPError {
            if case .authorizationRequired = error {
                do {
                    try await tokenStore.delete(serverID)
                } catch {
                    Log.inference.warning("MCPOAuthAuthorization: failed to clear token store after invalid_grant")
                }
            }
            return .fail(error)
        } catch {
            return .fail(.authorizationFailed(error.localizedDescription))
        }
    }

    private func activeTokens() async throws -> MCPOAuthTokens {
        if let stored = try await tokenStore.read(serverID) {
            try verifyIssuer(stored.issuer)
            if !isExpired(stored) {
                try validateBearerTransmission(stored)
                return stored
            }

            if let refreshToken = stored.refreshToken {
                do {
                    let metadata = try await discoverAuthorizationMetadata()
                    let refreshed = try await exchangeRefreshToken(
                        refreshToken,
                        metadata: metadata,
                        existing: stored
                    )
                    try await tokenStore.write(refreshed, serverID)
                    try validateBearerTransmission(refreshed)
                    return refreshed
                } catch {
                    try await tokenStore.delete(serverID)
                    Log.inference.warning("MCPOAuthAuthorization: refresh failed, forcing full OAuth authorization")
                }
            }
        }

        let metadata = try await discoverAuthorizationMetadata()
        let codeResponse = try await performAuthorizationCodeFlow(metadata: metadata)
        try await tokenStore.write(codeResponse, serverID)
        try validateBearerTransmission(codeResponse)
        return codeResponse
    }

    private func performAuthorizationCodeFlow(metadata: OAuthAuthorizationServerMetadata) async throws -> MCPOAuthTokens {
        let state = randomBase64URL(byteCount: 32)
        let verifier = randomBase64URL(byteCount: 48)
        let challenge = Self.pkceChallenge(for: verifier)
        let clientID = try await resolveClientIdentifier(metadata: metadata)

        let callbackScheme = try callbackScheme()
        let authorizationURL = try buildAuthorizationURL(
            endpoint: metadata.authorizationEndpoint,
            clientID: clientID,
            state: state,
            verifierChallenge: challenge
        )
        let callbackURL = try await redirectListener.authorize(
            authorizationURL: authorizationURL,
            callbackURLScheme: callbackScheme,
            prefersEphemeralSession: true
        )

        let code = try parseAuthorizationCode(callbackURL: callbackURL, expectedState: state)
        return try await exchangeAuthorizationCode(
            code: code,
            verifier: verifier,
            clientID: clientID,
            metadata: metadata
        )
    }

    private func discoverAuthorizationMetadata() async throws -> OAuthAuthorizationServerMetadata {
        if let cachedAuthorizationMetadata {
            return cachedAuthorizationMetadata
        }

        let decoder = JSONDecoder()
        let issuer: URL
        if let explicitIssuer = descriptor.authorizationServerIssuer {
            issuer = explicitIssuer
            try enforceHTTPS(issuer, label: "authorization issuer")
        } else {
            let resourceMetadataURL = Self.resourceMetadataURL(for: resourceURL)
            try enforceHTTPS(resourceMetadataURL, label: "resource metadata")
            let (data, response) = try await session.data(for: URLRequest(url: resourceMetadataURL))
            try requireSuccess(response: response, body: data, operation: "resource metadata discovery")
            let resourceMetadata = try decoder.decode(OAuthProtectedResourceMetadata.self, from: data)
            guard let candidateIssuers = resourceMetadata.authorizationServers, candidateIssuers.isEmpty == false else {
                throw MCPError.malformedMetadata("Missing authorization_servers in resource metadata")
            }
            var discoveredIssuer: URL?
            var lastValidationError: Error?
            for candidate in candidateIssuers {
                do {
                    try enforceHTTPS(candidate, label: "authorization issuer")
                    discoveredIssuer = candidate
                    break
                } catch {
                    lastValidationError = error
                }
            }
            guard let discoveredIssuer else {
                if let lastValidationError {
                    throw lastValidationError
                }
                throw MCPError.malformedMetadata("Missing valid authorization server issuer")
            }
            issuer = discoveredIssuer
            cachedResourceMetadataURL = resourceMetadataURL
        }

        let metadataURL = Self.authorizationMetadataURL(for: issuer)
        try enforceHTTPS(metadataURL, label: "authorization metadata")
        let (metadataData, metadataResponse) = try await session.data(for: URLRequest(url: metadataURL))
        try requireSuccess(response: metadataResponse, body: metadataData, operation: "authorization metadata discovery")
        let metadata = try decoder.decode(OAuthAuthorizationServerMetadata.self, from: metadataData)
        try enforceHTTPS(metadata.authorizationEndpoint, label: "authorization endpoint")
        try enforceHTTPS(metadata.tokenEndpoint, label: "token endpoint")

        if Self.isSameIssuer(metadata.issuer, issuer) == false {
            throw MCPError.issuerMismatch(expected: issuer, actual: metadata.issuer)
        }
        if let expectedIssuer = descriptor.authorizationServerIssuer,
           Self.isSameIssuer(metadata.issuer, expectedIssuer) == false {
            throw MCPError.issuerMismatch(expected: expectedIssuer, actual: metadata.issuer)
        }

        cachedAuthorizationMetadata = metadata
        return metadata
    }

    private func exchangeAuthorizationCode(
        code: String,
        verifier: String,
        clientID: String,
        metadata: OAuthAuthorizationServerMetadata
    ) async throws -> MCPOAuthTokens {
        var parameters: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": descriptor.redirectURI.absoluteString,
            "code_verifier": verifier,
            "client_id": clientID,
        ]
        parameters["resource"] = resourceURL.absoluteString
        return try await tokenExchange(parameters: parameters, metadata: metadata)
    }

    private func exchangeRefreshToken(
        _ refreshToken: String,
        metadata: OAuthAuthorizationServerMetadata,
        existing: MCPOAuthTokens
    ) async throws -> MCPOAuthTokens {
        let clientID = try await resolveClientIdentifier(metadata: metadata)
        var parameters: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        parameters["resource"] = resourceURL.absoluteString
        let refreshed = try await tokenExchange(parameters: parameters, metadata: metadata)
        return MCPOAuthTokens(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? existing.refreshToken,
            expiresAt: refreshed.expiresAt,
            scopes: refreshed.scopes,
            tokenType: refreshed.tokenType,
            issuer: refreshed.issuer,
            subjectIdentifier: refreshed.subjectIdentifier ?? existing.subjectIdentifier
        )
    }

    private func tokenExchange(
        parameters: [String: String],
        metadata: OAuthAuthorizationServerMetadata
    ) async throws -> MCPOAuthTokens {
        try enforceHTTPS(metadata.tokenEndpoint, label: "token endpoint")
        var request = URLRequest(url: metadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formURLEncoded(parameters).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.transportFailure("Missing HTTP response during token exchange")
        }
        if (200...299).contains(http.statusCode) == false {
            throw parseTokenExchangeFailure(statusCode: http.statusCode, body: data)
        }

        let decoder = JSONDecoder()
        let parsed = try decoder.decode(OAuthTokenResponse.self, from: data)
        let scopes = parsed.scope?.split(separator: " ").map(String.init) ?? descriptor.scopes
        let expiresAt = parsed.expiresIn.map { currentDate().addingTimeInterval($0) }
        return MCPOAuthTokens(
            accessToken: parsed.accessToken,
            refreshToken: parsed.refreshToken,
            expiresAt: expiresAt,
            scopes: scopes,
            tokenType: parsed.tokenType ?? "Bearer",
            issuer: metadata.issuer
        )
    }

    private func buildAuthorizationURL(
        endpoint: URL,
        clientID: String,
        state: String,
        verifierChallenge: String
    ) throws -> URL {
        try enforceHTTPS(endpoint, label: "authorization endpoint")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: descriptor.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: descriptor.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: verifierChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: resourceURL.absoluteString),
        ])
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw MCPError.malformedMetadata("Could not build authorization URL")
        }
        return url
    }

    private func callbackScheme() throws -> String {
        guard let scheme = descriptor.redirectURI.scheme, !scheme.isEmpty else {
            throw MCPError.malformedMetadata("OAuth redirect URI must include a callback scheme")
        }
        return scheme
    }

    private func parseAuthorizationCode(callbackURL: URL, expectedState: String) throws -> String {
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        if let errorValue = queryItems.first(where: { $0.name == "error" })?.value {
            throw MCPError.authorizationFailed(errorValue)
        }

        let state = queryItems.first(where: { $0.name == "state" })?.value
        guard state == expectedState else {
            throw MCPError.authorizationFailed("OAuth state mismatch")
        }
        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw MCPError.authorizationFailed("Missing authorization code in callback")
        }
        return code
    }

    private func verifyIssuer(_ issuer: URL) throws {
        if let expected = descriptor.authorizationServerIssuer,
           Self.isSameIssuer(expected, issuer) == false {
            throw MCPError.issuerMismatch(expected: expected, actual: issuer)
        }
    }

    private func isExpired(_ token: MCPOAuthTokens) -> Bool {
        guard let expiresAt = token.expiresAt else { return false }
        return expiresAt <= currentDate().addingTimeInterval(30)
    }

    private func randomBase64URL(byteCount: Int) -> String {
        let generated = random()
        let randomData = generated.isEmpty ? Self.secureRandomData(length: byteCount) : generated
        return Self.base64URL(randomData)
    }

    private func resolveClientIdentifier(metadata: OAuthAuthorizationServerMetadata) async throws -> String {
        if let cachedRegisteredClientID {
            return cachedRegisteredClientID
        }

        let fallbackClientID = clientIdentifier()
        guard descriptor.allowDynamicClientRegistration else {
            return fallbackClientID
        }
        guard let registrationEndpoint = metadata.registrationEndpoint else {
            return fallbackClientID
        }

        do {
            try enforceHTTPS(registrationEndpoint, label: "registration endpoint")
            var request = URLRequest(url: registrationEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            var payload: [String: Any] = [
                "client_name": descriptor.clientName,
                "redirect_uris": [descriptor.redirectURI.absoluteString],
                "grant_types": ["authorization_code", "refresh_token"],
                "scope": descriptor.scopes.joined(separator: " ")
            ]
            if let softwareID = descriptor.softwareID, softwareID.isEmpty == false {
                payload["software_id"] = softwareID
            }
            if descriptor.publicClient {
                payload["token_endpoint_auth_method"] = "none"
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

            let (data, response) = try await session.data(for: request)
            try requireSuccess(response: response, body: data, operation: "dynamic client registration")
            let parsed = try JSONDecoder().decode(OAuthDynamicClientRegistrationResponse.self, from: data)
            guard parsed.clientID.isEmpty == false else {
                throw MCPError.dcrFailed("dynamic client registration did not return client_id")
            }
            cachedRegisteredClientID = parsed.clientID
            return parsed.clientID
        } catch {
            if descriptor.publicClient {
                Log.inference.warning("MCPOAuthAuthorization: DCR unavailable, falling back to static public client identifier")
                return fallbackClientID
            }
            throw MCPError.dcrFailed(error.localizedDescription)
        }
    }

    private func parseTokenExchangeFailure(statusCode: Int, body: Data) -> MCPError {
        do {
            let oauthError = try JSONDecoder().decode(OAuthTokenErrorResponse.self, from: body)
            if oauthError.error == "invalid_grant" {
                return .authorizationRequired(buildAuthorizationRequest())
            }
            let description = oauthError.errorDescription ?? oauthError.error
            return .authorizationFailed("token exchange failed (\(statusCode)): \(description)")
        } catch {
            let message = String(data: body, encoding: .utf8) ?? "HTTP \(statusCode)"
            return .authorizationFailed("token exchange failed (\(statusCode)): \(message)")
        }
    }

    private func validateBearerTransmission(_ tokens: MCPOAuthTokens) throws {
        guard tokens.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw MCPError.authorizationFailed("Unsupported token type for Authorization header")
        }
        guard tokens.accessToken.isEmpty == false else {
            throw MCPError.authorizationFailed("Missing access token")
        }
        let invalidScalars = CharacterSet.controlCharacters
            .union(.newlines)
            .union(.whitespacesAndNewlines)
        if tokens.accessToken.unicodeScalars.contains(where: { invalidScalars.contains($0) }) {
            throw MCPError.authorizationFailed("Access token contains invalid bearer characters")
        }
    }

    private func buildAuthorizationRequest() -> MCPAuthorizationRequest {
        let metadataURL = cachedResourceMetadataURL ?? Self.resourceMetadataURL(for: resourceURL)
        let safeMetadataURL: URL?
        do {
            try MCPSSRFPolicy.validateOAuthURL(metadataURL, label: "resource metadata")
            safeMetadataURL = metadataURL
        } catch {
            safeMetadataURL = nil
            Log.inference.warning("MCPOAuthAuthorization: omitted unsafe resource metadata URL from auth request")
        }

        let safeAuthorizationURL: URL?
        if let issuer = descriptor.authorizationServerIssuer {
            do {
                try MCPSSRFPolicy.validateOAuthURL(issuer, label: "authorization issuer")
                safeAuthorizationURL = issuer
            } catch {
                safeAuthorizationURL = nil
                Log.inference.warning("MCPOAuthAuthorization: omitted unsafe authorization issuer URL from auth request")
            }
        } else {
            safeAuthorizationURL = nil
        }

        return MCPAuthorizationRequest(
            serverID: serverID,
            resourceMetadataURL: safeMetadataURL,
            authorizationServerURL: safeAuthorizationURL,
            requiredScopes: descriptor.scopes
        )
    }

    private func enforceHTTPS(_ url: URL, label: String) throws {
        try MCPSSRFPolicy.validateOAuthURL(url, label: label)
    }

    private func requireSuccess(response: URLResponse, body: Data, operation: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.transportFailure("Missing HTTP response during \(operation)")
        }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: body, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw MCPError.authorizationFailed("\(operation) failed: \(message)")
        }
    }

    private func clientIdentifier() -> String {
        descriptor.softwareID ?? descriptor.clientName
    }

    private static func authorizationMetadataURL(for issuer: URL) -> URL {
        let trimmedPath = issuer.path == "/" ? "" : issuer.path
        var components = URLComponents()
        components.scheme = issuer.scheme
        components.host = issuer.host
        components.port = issuer.port
        components.path = "/.well-known/oauth-authorization-server\(trimmedPath)"
        return components.url ?? issuer.appendingPathComponent(".well-known/oauth-authorization-server")
    }

    private static func resourceMetadataURL(for resourceURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = resourceURL.scheme
        components.host = resourceURL.host
        components.port = resourceURL.port
        components.path = "/.well-known/oauth-protected-resource"
        return components.url ?? resourceURL
    }

    private static func isSameOrigin(lhs: URL, rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? defaultPort(for: lhs)) == (rhs.port ?? defaultPort(for: rhs))
    }

    private static func isSameIssuer(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedIssuerString(lhs) == normalizedIssuerString(rhs)
    }

    private static func normalizedIssuerString(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        var path = components.path
        if path == "/" { path = "" }
        if path.hasSuffix("/") && path.count > 1 {
            path.removeLast()
        }
        components.path = path

        if components.port == defaultPort(for: url) {
            components.port = nil
        }

        components.query = nil
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    private static func defaultPort(for url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private static func formURLEncoded(_ values: [String: String]) -> String {
        values
            .sorted { $0.key < $1.key }
            .map { key, value in "\(urlEncode(key))=\(urlEncode(value))" }
            .joined(separator: "&")
    }

    private static func urlEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func pkceChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func secureRandomData(length: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes)
        }
        return Data(UUID().uuidString.utf8)
    }
}

internal enum MCPSSRFPolicy {
    static func validateTransportURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw MCPError.transportFailure("MCP transport endpoint must use http(s)")
        }
        if PrivateIPClassifier.isLocalhostURL(url) {
            return
        }
        guard scheme == "https" else {
            throw MCPError.transportFailure("MCP transport endpoint must use HTTPS outside localhost")
        }
        try validateHostNotBlocked(url, wrap: { .transportFailure($0) })
    }

    static func validateOAuthURL(_ url: URL, label: String) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw MCPError.authorizationFailed("Expected HTTPS \(label) URL")
        }
        try validateHostNotBlocked(url, wrap: { _ in .authorizationFailed("Expected host in \(label) URL") })
    }

    private static func validateHostNotBlocked(
        _ url: URL,
        wrap: (String) -> MCPError
    ) throws {
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw wrap("missing host")
        }
        let normalizedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        if PrivateIPClassifier.classifyIPLiteral(normalizedHost) != nil {
            if PrivateIPClassifier.isLocalhostURL(url) == false {
                throw MCPError.ssrfBlocked(url)
            }
        }
    }
}
