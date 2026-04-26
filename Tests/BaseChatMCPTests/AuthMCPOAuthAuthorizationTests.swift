import Foundation
import XCTest
@testable import BaseChatMCP
import BaseChatTestSupport

final class AuthMCPOAuthAuthorizationTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func test_authorizationHeaderUsesStoredTokenWhenNotExpired() async throws {
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let issuer = URL(string: "https://auth.example.com")!
        let descriptor = makeDescriptor(issuer: issuer)
        let tokenStore = MCPOAuthTokenStore.inMemory()
        try await tokenStore.write(
            MCPOAuthTokens(
                accessToken: "stored-token",
                refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(600),
                scopes: ["tools:read"],
                issuer: issuer
            ),
            serverID
        )

        let authorization = MCPOAuthAuthorization(
            descriptor: descriptor,
            serverID: serverID,
            resourceURL: resourceURL,
            redirectListener: RedirectListenerMock { _ in
                XCTFail("Redirect listener should not be used for fresh tokens")
                return URL(string: "basechat://oauth/callback?code=unused&state=unused")!
            },
            tokenStore: tokenStore,
            session: makeSession()
        )

        let header = try await authorization.authorizationHeader(for: resourceURL)
        XCTAssertEqual(header, "Bearer stored-token")
        XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty)
    }

    func test_authorizationHeaderRefreshesExpiredToken() async throws {
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let issuer = URL(string: "https://auth.example.com")!
        let metadataURL = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!
        let tokenEndpoint = URL(string: "https://auth.example.com/token")!
        MockURLProtocol.stub(url: metadataURL, response: .immediate(data: Data(
            """
            {
              "issuer": "https://auth.example.com",
              "authorization_endpoint": "https://auth.example.com/authorize",
              "token_endpoint": "https://auth.example.com/token"
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))
        MockURLProtocol.stub(url: tokenEndpoint, response: .immediate(data: Data(
            """
            {
              "access_token": "refreshed-token",
              "expires_in": 3600,
              "scope": "tools:read",
              "token_type": "Bearer"
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))

        let descriptor = makeDescriptor(issuer: issuer)
        let tokenStore = MCPOAuthTokenStore.inMemory()
        try await tokenStore.write(
            MCPOAuthTokens(
                accessToken: "expired",
                refreshToken: "refresh-123",
                expiresAt: Date().addingTimeInterval(-60),
                scopes: ["tools:read"],
                issuer: issuer
            ),
            serverID
        )

        let authorization = MCPOAuthAuthorization(
            descriptor: descriptor,
            serverID: serverID,
            resourceURL: resourceURL,
            redirectListener: RedirectListenerMock { _ in
                XCTFail("Redirect listener should not be used for refresh")
                return URL(string: "basechat://oauth/callback?code=unused&state=unused")!
            },
            tokenStore: tokenStore,
            session: makeSession()
        )

        let header = try await authorization.authorizationHeader(for: resourceURL)
        XCTAssertEqual(header, "Bearer refreshed-token")

        let stored = try await tokenStore.read(serverID)
        XCTAssertEqual(stored?.accessToken, "refreshed-token")
        XCTAssertEqual(stored?.refreshToken, "refresh-123")

        let tokenRequests = MockURLProtocol.capturedRequests.filter { $0.url == tokenEndpoint }
        XCTAssertEqual(tokenRequests.count, 1)
        let body = requestBodyString(tokenRequests[0])
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=refresh-123"))
    }

    func test_refreshTokenRotationPersistsReplacementRefreshToken() async throws {
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let issuer = URL(string: "https://auth.example.com")!
        let metadataURL = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!
        let tokenEndpoint = URL(string: "https://auth.example.com/token")!
        MockURLProtocol.stub(url: metadataURL, response: .immediate(data: Data(
            """
            {
              "issuer": "https://auth.example.com",
              "authorization_endpoint": "https://auth.example.com/authorize",
              "token_endpoint": "https://auth.example.com/token"
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))
        MockURLProtocol.stub(url: tokenEndpoint, response: .immediate(data: Data(
            """
            {
              "access_token": "refreshed-token",
              "refresh_token": "refresh-rotated",
              "expires_in": 3600,
              "scope": "tools:read",
              "token_type": "Bearer"
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))

        let descriptor = makeDescriptor(issuer: issuer)
        let tokenStore = MCPOAuthTokenStore.inMemory()
        try await tokenStore.write(
            MCPOAuthTokens(
                accessToken: "expired",
                refreshToken: "refresh-123",
                expiresAt: Date().addingTimeInterval(-60),
                scopes: ["tools:read"],
                issuer: issuer
            ),
            serverID
        )

        let authorization = MCPOAuthAuthorization(
            descriptor: descriptor,
            serverID: serverID,
            resourceURL: resourceURL,
            redirectListener: RedirectListenerMock { _ in
                XCTFail("Redirect listener should not be used for refresh")
                return URL(string: "basechat://oauth/callback?code=unused&state=unused")!
            },
            tokenStore: tokenStore,
            session: makeSession()
        )

        _ = try await authorization.authorizationHeader(for: resourceURL)
        let stored = try await tokenStore.read(serverID)
        XCTAssertEqual(stored?.refreshToken, "refresh-rotated")
    }

    func test_authorizationHeaderDiscoversMetadataAndExchangesCode() async throws {
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let resourceMetadataURL = URL(string: "https://resource.example.com/.well-known/oauth-protected-resource")!
        let authMetadataURL = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!
        let tokenEndpoint = URL(string: "https://auth.example.com/token")!

        MockURLProtocol.stub(url: resourceMetadataURL, response: .immediate(data: Data(
            """
            {
              "authorization_servers": ["https://auth.example.com"]
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))
        MockURLProtocol.stub(url: authMetadataURL, response: .immediate(data: Data(
            """
            {
              "issuer": "https://auth.example.com",
              "authorization_endpoint": "https://auth.example.com/authorize",
              "token_endpoint": "https://auth.example.com/token"
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))
        MockURLProtocol.stub(url: tokenEndpoint, response: .immediate(data: Data(
            """
            {
              "access_token": "code-token",
              "refresh_token": "refresh-from-code",
              "expires_in": 1200,
              "scope": "tools:read tools:write",
              "token_type": "Bearer"
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))

        let descriptor = makeDescriptor(issuer: nil)
        let listener = RedirectListenerMock { authorizationURL in
            let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first(where: { $0.name == "state" })?.value
            XCTAssertNotNil(state)
            XCTAssertNotNil(items.first(where: { $0.name == "code_challenge" })?.value)
            XCTAssertEqual(items.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
            return URL(string: "basechat://oauth/callback?code=auth-code&state=\(state ?? "")")!
        }

        let authorization = MCPOAuthAuthorization(
            descriptor: descriptor,
            serverID: serverID,
            resourceURL: resourceURL,
            redirectListener: listener,
            tokenStore: .inMemory(),
            session: makeSession()
        )

        let header = try await authorization.authorizationHeader(for: resourceURL)
        XCTAssertEqual(header, "Bearer code-token")

        let tokenRequest = try XCTUnwrap(MockURLProtocol.capturedRequests.first(where: { $0.url == tokenEndpoint }))
        let body = requestBodyString(tokenRequest)
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code_verifier="))
    }

    func test_handleUnauthorizedWithoutRefreshRequestsAuthorization() async throws {
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let authorization = MCPOAuthAuthorization(
            descriptor: makeDescriptor(issuer: URL(string: "https://auth.example.com")!),
            serverID: serverID,
            resourceURL: resourceURL,
            redirectListener: RedirectListenerMock { _ in
                URL(string: "basechat://oauth/callback?code=unused&state=unused")!
            },
            tokenStore: .inMemory(),
            session: makeSession()
        )

        let decision = try await authorization.handleUnauthorized(statusCode: 401, body: Data())
        switch decision {
        case .retry:
            XCTFail("Expected authorizationRequired failure")
        case .fail(let error):
            guard case .authorizationRequired(let request) = error else {
                XCTFail("Expected authorizationRequired, got \(error)")
                return
            }
            XCTAssertEqual(request.serverID, serverID)
            XCTAssertEqual(request.requiredScopes, ["tools:read", "tools:write"])
            XCTAssertEqual(request.resourceMetadataURL, URL(string: "https://resource.example.com/.well-known/oauth-protected-resource"))
        }
    }

    func test_handleUnauthorizedInvalidGrantClearsStoredTokensAndRequestsAuthorization() async throws {
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let issuer = URL(string: "https://auth.example.com")!
        let metadataURL = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!
        let tokenEndpoint = URL(string: "https://auth.example.com/token")!
        MockURLProtocol.stub(url: metadataURL, response: .immediate(data: Data(
            """
            {
              "issuer": "https://auth.example.com",
              "authorization_endpoint": "https://auth.example.com/authorize",
              "token_endpoint": "https://auth.example.com/token"
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))
        MockURLProtocol.stub(url: tokenEndpoint, response: .immediate(data: Data(
            """
            {
              "error": "invalid_grant",
              "error_description": "refresh token expired"
            }
            """.utf8
        ), statusCode: 400, headers: ["Content-Type": "application/json"]))

        let tokenStore = MCPOAuthTokenStore.inMemory()
        try await tokenStore.write(
            MCPOAuthTokens(
                accessToken: "old",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(-10),
                scopes: ["tools:read", "tools:write"],
                issuer: issuer
            ),
            serverID
        )
        let authorization = MCPOAuthAuthorization(
            descriptor: makeDescriptor(issuer: issuer),
            serverID: serverID,
            resourceURL: resourceURL,
            redirectListener: RedirectListenerMock { _ in
                XCTFail("Redirect listener should not be used for invalid_grant handling")
                return URL(string: "basechat://oauth/callback?code=unused&state=unused")!
            },
            tokenStore: tokenStore,
            session: makeSession()
        )

        let decision = try await authorization.handleUnauthorized(statusCode: 401, body: Data())
        switch decision {
        case .retry:
            XCTFail("Expected authorizationRequired after invalid_grant")
        case .fail(let error):
            guard case .authorizationRequired = error else {
                XCTFail("Expected authorizationRequired, got \(error)")
                return
            }
        }

        let stored = try await tokenStore.read(serverID)
        XCTAssertNil(stored)
    }

    func test_authorizationHeaderThrowsOnIssuerMismatch() async throws {
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let issuer = URL(string: "https://auth.example.com")!
        let metadataURL = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!
        MockURLProtocol.stub(url: metadataURL, response: .immediate(data: Data(
            """
            {
              "issuer": "https://unexpected.example.com",
              "authorization_endpoint": "https://auth.example.com/authorize",
              "token_endpoint": "https://auth.example.com/token"
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))

        let authorization = MCPOAuthAuthorization(
            descriptor: makeDescriptor(issuer: issuer),
            serverID: serverID,
            resourceURL: resourceURL,
            redirectListener: RedirectListenerMock { _ in
                URL(string: "basechat://oauth/callback?code=unused&state=unused")!
            },
            tokenStore: .inMemory(),
            session: makeSession()
        )

        await XCTAssertThrowsErrorAsync(try await authorization.authorizationHeader(for: resourceURL)) { error in
            guard case let MCPError.issuerMismatch(expected, actual) = error else {
                XCTFail("Expected issuer mismatch, got \(error)")
                return
            }
            XCTAssertEqual(expected.absoluteString, issuer.absoluteString)
            XCTAssertEqual(actual.absoluteString, "https://unexpected.example.com")
        }
    }

    func test_authorizationHeaderRejectsUnsafeAccessTokenCharacters() async throws {
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let issuer = URL(string: "https://auth.example.com")!
        let tokenStore = MCPOAuthTokenStore.inMemory()
        try await tokenStore.write(
            MCPOAuthTokens(
                accessToken: "bad token",
                refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(600),
                scopes: ["tools:read"],
                issuer: issuer
            ),
            serverID
        )

        let authorization = MCPOAuthAuthorization(
            descriptor: makeDescriptor(issuer: issuer),
            serverID: serverID,
            resourceURL: resourceURL,
            redirectListener: RedirectListenerMock { _ in
                URL(string: "basechat://oauth/callback?code=unused&state=unused")!
            },
            tokenStore: tokenStore,
            session: makeSession()
        )

        await XCTAssertThrowsErrorAsync(try await authorization.authorizationHeader(for: resourceURL)) { error in
            guard case .authorizationFailed(let message) = error as? MCPError else {
                XCTFail("Expected authorizationFailed, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("invalid bearer characters"))
        }
    }

    func test_authorizationHeaderUsesDCRClientIdentifierWhenAvailable() async throws {
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let resourceMetadataURL = URL(string: "https://resource.example.com/.well-known/oauth-protected-resource")!
        let authMetadataURL = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!
        let registrationEndpoint = URL(string: "https://auth.example.com/register")!
        let tokenEndpoint = URL(string: "https://auth.example.com/token")!

        MockURLProtocol.stub(url: resourceMetadataURL, response: .immediate(data: Data(
            """
            {
              "authorization_servers": ["http://insecure.example.com", "https://auth.example.com"]
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))
        MockURLProtocol.stub(url: authMetadataURL, response: .immediate(data: Data(
            """
            {
              "issuer": "https://auth.example.com/",
              "authorization_endpoint": "https://auth.example.com/authorize",
              "token_endpoint": "https://auth.example.com/token",
              "registration_endpoint": "https://auth.example.com/register"
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))
        MockURLProtocol.stub(url: registrationEndpoint, response: .immediate(data: Data(
            """
            {
              "client_id": "dcr-client-id"
            }
            """.utf8
        ), statusCode: 201, headers: ["Content-Type": "application/json"]))
        MockURLProtocol.stub(url: tokenEndpoint, response: .immediate(data: Data(
            """
            {
              "access_token": "code-token",
              "refresh_token": "refresh-from-code",
              "expires_in": 1200,
              "scope": "tools:read tools:write",
              "token_type": "Bearer"
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))

        let listener = RedirectListenerMock { authorizationURL in
            let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first(where: { $0.name == "state" })?.value
            XCTAssertEqual(items.first(where: { $0.name == "client_id" })?.value, "dcr-client-id")
            return URL(string: "basechat://oauth/callback?code=auth-code&state=\(state ?? "")")!
        }
        let authorization = MCPOAuthAuthorization(
            descriptor: makeDescriptor(issuer: nil),
            serverID: serverID,
            resourceURL: resourceURL,
            redirectListener: listener,
            tokenStore: .inMemory(),
            session: makeSession()
        )

        _ = try await authorization.authorizationHeader(for: resourceURL)

        let tokenRequest = try XCTUnwrap(MockURLProtocol.capturedRequests.first(where: { $0.url == tokenEndpoint }))
        let body = requestBodyString(tokenRequest)
        XCTAssertTrue(body.contains("client_id=dcr-client-id"))
    }

    func test_authorizationHeaderFallsBackWhenDCRFailsForPublicClient() async throws {
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let resourceMetadataURL = URL(string: "https://resource.example.com/.well-known/oauth-protected-resource")!
        let authMetadataURL = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!
        let registrationEndpoint = URL(string: "https://auth.example.com/register")!
        let tokenEndpoint = URL(string: "https://auth.example.com/token")!

        MockURLProtocol.stub(url: resourceMetadataURL, response: .immediate(data: Data(
            """
            {
              "authorization_servers": ["https://auth.example.com"]
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))
        MockURLProtocol.stub(url: authMetadataURL, response: .immediate(data: Data(
            """
            {
              "issuer": "https://auth.example.com",
              "authorization_endpoint": "https://auth.example.com/authorize",
              "token_endpoint": "https://auth.example.com/token",
              "registration_endpoint": "https://auth.example.com/register"
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))
        MockURLProtocol.stub(url: registrationEndpoint, response: .immediate(data: Data(
            """
            {
              "error": "registration_failed"
            }
            """.utf8
        ), statusCode: 500, headers: ["Content-Type": "application/json"]))
        MockURLProtocol.stub(url: tokenEndpoint, response: .immediate(data: Data(
            """
            {
              "access_token": "code-token",
              "refresh_token": "refresh-from-code",
              "expires_in": 1200,
              "scope": "tools:read tools:write",
              "token_type": "Bearer"
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))

        let descriptor = MCPAuthorizationDescriptor.OAuthDescriptor(
            clientName: "BaseChatKit",
            scopes: ["tools:read", "tools:write"],
            redirectURI: URL(string: "basechat://oauth/callback")!,
            authorizationServerIssuer: nil,
            softwareID: "basechat-client",
            allowDynamicClientRegistration: true,
            publicClient: true
        )

        let listener = RedirectListenerMock { authorizationURL in
            let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first(where: { $0.name == "state" })?.value
            XCTAssertEqual(items.first(where: { $0.name == "client_id" })?.value, "basechat-client")
            return URL(string: "basechat://oauth/callback?code=auth-code&state=\(state ?? "")")!
        }
        let authorization = MCPOAuthAuthorization(
            descriptor: descriptor,
            serverID: serverID,
            resourceURL: resourceURL,
            redirectListener: listener,
            tokenStore: .inMemory(),
            session: makeSession()
        )

        _ = try await authorization.authorizationHeader(for: resourceURL)
    }

    private func makeDescriptor(issuer: URL?) -> MCPAuthorizationDescriptor.OAuthDescriptor {
        MCPAuthorizationDescriptor.OAuthDescriptor(
            clientName: "BaseChatKit",
            scopes: ["tools:read", "tools:write"],
            redirectURI: URL(string: "basechat://oauth/callback")!,
            authorizationServerIssuer: issuer,
            softwareID: "basechat-client"
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func requestBodyString(_ request: URLRequest) -> String {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else {
            return ""
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private actor RedirectListenerMock: MCPOAuthRedirectListener {
    private let handler: (URL) -> URL

    init(handler: @escaping (URL) -> URL) {
        self.handler = handler
    }

    func authorize(
        authorizationURL: URL,
        callbackURLScheme: String,
        prefersEphemeralSession: Bool
    ) async throws -> URL {
        _ = callbackURLScheme
        _ = prefersEphemeralSession
        return handler(authorizationURL)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        handler(error)
    }
}
