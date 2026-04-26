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

    // MARK: - Fix 1: RFC 9207 iss parameter validation

    func test_callback_iss_validated_when_advertised() async throws {
        // Sabotage check: remove the iss param from the callback URL and the test
        // must fail with authorizationFailed("RFC 9207: iss parameter required but not present").
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let issuer = URL(string: "https://auth.example.com")!
        let resourceMetadataURL = URL(string: "https://resource.example.com/.well-known/oauth-protected-resource")!
        let authMetadataURL = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!
        let tokenEndpoint = URL(string: "https://auth.example.com/token")!

        MockURLProtocol.stub(url: resourceMetadataURL, response: .immediate(data: Data(
            """
            { "authorization_servers": ["https://auth.example.com"] }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))
        // AS advertises RFC 9207 support.
        MockURLProtocol.stub(url: authMetadataURL, response: .immediate(data: Data(
            """
            {
              "issuer": "https://auth.example.com",
              "authorization_endpoint": "https://auth.example.com/authorize",
              "token_endpoint": "https://auth.example.com/token",
              "authorization_response_iss_parameter_supported": true
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))
        MockURLProtocol.stub(url: tokenEndpoint, response: .immediate(data: Data(
            """
            { "access_token": "iss-token", "expires_in": 3600, "token_type": "Bearer" }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))

        let descriptor = makeDescriptor(issuer: nil)
        let listener = RedirectListenerMock { authorizationURL in
            let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first(where: { $0.name == "state" })?.value ?? ""
            // iss present and matching → should succeed.
            return URL(string: "basechat://oauth/callback?code=abc&state=\(state)&iss=https://auth.example.com")!
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
        XCTAssertEqual(header, "Bearer iss-token")
    }

    func test_callback_iss_mutated_rejected() async throws {
        // Sabotage check: change the guard in parseAuthorizationCode so isSameIssuer
        // always returns true — this test must then pass (no throw), confirming the
        // guard is what makes it fail here.
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let resourceMetadataURL = URL(string: "https://resource.example.com/.well-known/oauth-protected-resource")!
        let authMetadataURL = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!

        MockURLProtocol.stub(url: resourceMetadataURL, response: .immediate(data: Data(
            """
            { "authorization_servers": ["https://auth.example.com"] }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))
        MockURLProtocol.stub(url: authMetadataURL, response: .immediate(data: Data(
            """
            {
              "issuer": "https://auth.example.com",
              "authorization_endpoint": "https://auth.example.com/authorize",
              "token_endpoint": "https://auth.example.com/token",
              "authorization_response_iss_parameter_supported": true
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))

        let descriptor = makeDescriptor(issuer: nil)
        let listener = RedirectListenerMock { authorizationURL in
            let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first(where: { $0.name == "state" })?.value ?? ""
            // iss present but wrong — attacker substituted their own issuer.
            return URL(string: "basechat://oauth/callback?code=abc&state=\(state)&iss=https://attacker.example.com")!
        }

        let authorization = MCPOAuthAuthorization(
            descriptor: descriptor,
            serverID: serverID,
            resourceURL: resourceURL,
            redirectListener: listener,
            tokenStore: .inMemory(),
            session: makeSession()
        )

        await XCTAssertThrowsErrorAsync(try await authorization.authorizationHeader(for: resourceURL)) { error in
            guard case let MCPError.issuerMismatch(expected, actual) = error else {
                XCTFail("Expected issuerMismatch, got \(error)")
                return
            }
            XCTAssertEqual(expected.host, "auth.example.com")
            XCTAssertEqual(actual.host, "attacker.example.com")
        }
    }

    func test_callback_iss_missing_when_advertised_rejected() async throws {
        // Sabotage check: set authorizationResponseIssParameterSupported to false
        // in the stub — the test should then pass (no throw), confirming the guard
        // is what produces the error here.
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let resourceMetadataURL = URL(string: "https://resource.example.com/.well-known/oauth-protected-resource")!
        let authMetadataURL = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!

        MockURLProtocol.stub(url: resourceMetadataURL, response: .immediate(data: Data(
            """
            { "authorization_servers": ["https://auth.example.com"] }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))
        MockURLProtocol.stub(url: authMetadataURL, response: .immediate(data: Data(
            """
            {
              "issuer": "https://auth.example.com",
              "authorization_endpoint": "https://auth.example.com/authorize",
              "token_endpoint": "https://auth.example.com/token",
              "authorization_response_iss_parameter_supported": true
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))

        let descriptor = makeDescriptor(issuer: nil)
        let listener = RedirectListenerMock { authorizationURL in
            let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first(where: { $0.name == "state" })?.value ?? ""
            // No iss param — absent when AS advertises support.
            return URL(string: "basechat://oauth/callback?code=abc&state=\(state)")!
        }

        let authorization = MCPOAuthAuthorization(
            descriptor: descriptor,
            serverID: serverID,
            resourceURL: resourceURL,
            redirectListener: listener,
            tokenStore: .inMemory(),
            session: makeSession()
        )

        await XCTAssertThrowsErrorAsync(try await authorization.authorizationHeader(for: resourceURL)) { error in
            guard case .authorizationFailed(let message) = error as? MCPError else {
                XCTFail("Expected authorizationFailed, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("iss parameter required"), "Message was: \(message)")
        }
    }

    func test_callback_iss_absent_when_not_advertised_accepted() async throws {
        // Sabotage check: add authorization_response_iss_parameter_supported: true
        // to the stub — the test should then fail with authorizationFailed, confirming
        // the absence of the flag is what lets the flow succeed here.
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let resourceMetadataURL = URL(string: "https://resource.example.com/.well-known/oauth-protected-resource")!
        let authMetadataURL = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!
        let tokenEndpoint = URL(string: "https://auth.example.com/token")!

        MockURLProtocol.stub(url: resourceMetadataURL, response: .immediate(data: Data(
            """
            { "authorization_servers": ["https://auth.example.com"] }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))
        // AS does not advertise RFC 9207 — iss is optional.
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
            { "access_token": "no-iss-token", "expires_in": 3600, "token_type": "Bearer" }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))

        let descriptor = makeDescriptor(issuer: nil)
        let listener = RedirectListenerMock { authorizationURL in
            let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first(where: { $0.name == "state" })?.value ?? ""
            // No iss param and AS didn't advertise it — must succeed.
            return URL(string: "basechat://oauth/callback?code=abc&state=\(state)")!
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
        XCTAssertEqual(header, "Bearer no-iss-token")
    }

    // MARK: - Fix 2: Multi-account Keychain key

    func test_multiAccount_isolation() async throws {
        // Sabotage check: remove subjectIdentifier from the init — both tokens
        // map to nil key and the second overwrite should be detected by checking
        // that the first token is gone.
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let issuer = URL(string: "https://auth.example.com")!
        let store = MCPOAuthTokenStore.inMemory()

        // Two server UUIDs mirroring two different account subs.
        let serverA = UUID()
        let serverB = UUID()

        let tokenA = MCPOAuthTokens(
            accessToken: "token-account-a",
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600),
            scopes: ["tools:read"],
            issuer: issuer,
            subjectIdentifier: "sub-a"
        )
        let tokenB = MCPOAuthTokens(
            accessToken: "token-account-b",
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600),
            scopes: ["tools:read"],
            issuer: issuer,
            subjectIdentifier: "sub-b"
        )

        try await store.write(tokenA, serverA)
        try await store.write(tokenB, serverB)

        // Neither write should clobber the other.
        let readA = try await store.read(serverA)
        let readB = try await store.read(serverB)
        XCTAssertEqual(readA?.subjectIdentifier, "sub-a")
        XCTAssertEqual(readB?.subjectIdentifier, "sub-b")
        XCTAssertNotEqual(readA?.subjectIdentifier, readB?.subjectIdentifier)
    }

    func test_subjectIdentifierExtracted_fromTokenResponse_sub() {
        // Sabotage check: rename the "sub" key to "foo" — result becomes nil.
        let response: [String: Any] = ["sub": "user-123", "access_token": "tok"]
        let sub = MCPOAuthTokenStore.subjectIdentifier(from: response)
        XCTAssertEqual(sub, "user-123")
    }

    func test_subjectIdentifierExtracted_fromTokenResponse_botID() {
        // Sabotage check: remove "bot_id" check from subjectIdentifier — result becomes nil.
        let response: [String: Any] = ["bot_id": "bot-456", "access_token": "tok"]
        let sub = MCPOAuthTokenStore.subjectIdentifier(from: response)
        XCTAssertEqual(sub, "bot-456")
    }

    // MARK: - Fix 4: Single-flight refresh

    func test_refresh_singleFlight_concurrentCallersShareResult() async throws {
        // Sabotage check: remove the inflightRefresh guard — with two concurrent
        // callers and one refresh slot, both fire and the token endpoint is hit twice.
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
            { "access_token": "single-flight-token", "expires_in": 3600, "token_type": "Bearer" }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))

        let tokenStore = MCPOAuthTokenStore.inMemory()
        try await tokenStore.write(
            MCPOAuthTokens(
                accessToken: "expired",
                refreshToken: "refresh-sf",
                expiresAt: Date().addingTimeInterval(-60),
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
                XCTFail("Redirect listener should not be used for refresh")
                return URL(string: "basechat://oauth/callback?code=unused&state=unused")!
            },
            tokenStore: tokenStore,
            session: makeSession()
        )

        // Fire two concurrent refreshes against the same authorization actor.
        async let h1 = authorization.authorizationHeader(for: resourceURL)
        async let h2 = authorization.authorizationHeader(for: resourceURL)
        let (header1, header2) = try await (h1, h2)

        XCTAssertEqual(header1, "Bearer single-flight-token")
        XCTAssertEqual(header2, "Bearer single-flight-token")

        // Only one refresh request should have reached the token endpoint.
        let tokenRequests = MockURLProtocol.capturedRequests.filter { $0.url == tokenEndpoint }
        XCTAssertEqual(tokenRequests.count, 1, "Expected exactly one refresh request; got \(tokenRequests.count)")
    }

    func test_dcr_registration_managementTokenPersisted() async throws {
        // Sabotage check: remove the registration_access_token parsing block —
        // disconnect() will silently skip the DELETE because managementToken is nil.
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let resourceMetadataURL = URL(string: "https://resource.example.com/.well-known/oauth-protected-resource")!
        let authMetadataURL = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!
        let registrationEndpoint = URL(string: "https://auth.example.com/register")!
        let tokenEndpoint = URL(string: "https://auth.example.com/token")!

        MockURLProtocol.stub(url: resourceMetadataURL, response: .immediate(data: Data(
            """
            { "authorization_servers": ["https://auth.example.com"] }
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
        // DCR response includes RFC 7592 management credentials.
        MockURLProtocol.stub(url: registrationEndpoint, response: .immediate(data: Data(
            """
            {
              "client_id": "dcr-managed-client",
              "registration_access_token": "mgmt-token-xyz",
              "registration_client_uri": "https://auth.example.com/register/dcr-managed-client"
            }
            """.utf8
        ), statusCode: 201, headers: ["Content-Type": "application/json"]))
        MockURLProtocol.stub(url: tokenEndpoint, response: .immediate(data: Data(
            """
            { "access_token": "dcr-tok", "expires_in": 3600, "token_type": "Bearer" }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))

        let descriptor = MCPAuthorizationDescriptor.OAuthDescriptor(
            clientName: "BaseChatKit",
            scopes: ["tools:read"],
            redirectURI: URL(string: "basechat://oauth/callback")!,
            authorizationServerIssuer: nil,
            softwareID: "basechat-client",
            allowDynamicClientRegistration: true,
            publicClient: true
        )

        let managementEndpoint = URL(string: "https://auth.example.com/register/dcr-managed-client")!
        MockURLProtocol.stub(url: managementEndpoint, response: .immediate(data: Data(), statusCode: 204, headers: [:]))

        let listener = RedirectListenerMock { authorizationURL in
            let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first(where: { $0.name == "state" })?.value ?? ""
            return URL(string: "basechat://oauth/callback?code=code&state=\(state)")!
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

        // Disconnect should fire a DELETE to the management URI.
        await authorization.disconnect()

        let deleteRequests = MockURLProtocol.capturedRequests.filter {
            $0.url == managementEndpoint && $0.httpMethod == "DELETE"
        }
        XCTAssertEqual(deleteRequests.count, 1, "Expected one DELETE to management URI")
        let authHeader = deleteRequests.first?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(authHeader, "Bearer mgmt-token-xyz")
    }

    func test_disconnect_deregistersDynamicClient_bestEffort() async throws {
        // Sabotage check: make the management DELETE stub return 500 — disconnect()
        // must not throw despite the server error.
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let resourceMetadataURL = URL(string: "https://resource.example.com/.well-known/oauth-protected-resource")!
        let authMetadataURL = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!
        let registrationEndpoint = URL(string: "https://auth.example.com/register")!
        let tokenEndpoint = URL(string: "https://auth.example.com/token")!
        let managementEndpoint = URL(string: "https://auth.example.com/register/client-err")!

        MockURLProtocol.stub(url: resourceMetadataURL, response: .immediate(data: Data(
            """
            { "authorization_servers": ["https://auth.example.com"] }
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
              "client_id": "client-err",
              "registration_access_token": "mgmt-tok",
              "registration_client_uri": "https://auth.example.com/register/client-err"
            }
            """.utf8
        ), statusCode: 201, headers: ["Content-Type": "application/json"]))
        MockURLProtocol.stub(url: tokenEndpoint, response: .immediate(data: Data(
            """
            { "access_token": "tok-err", "expires_in": 3600, "token_type": "Bearer" }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))
        // Server returns an error for the deregistration DELETE.
        MockURLProtocol.stub(url: managementEndpoint, response: .immediate(data: Data(), statusCode: 500, headers: [:]))

        let descriptor = MCPAuthorizationDescriptor.OAuthDescriptor(
            clientName: "BaseChatKit",
            scopes: ["tools:read"],
            redirectURI: URL(string: "basechat://oauth/callback")!,
            authorizationServerIssuer: nil,
            softwareID: "basechat-client",
            allowDynamicClientRegistration: true,
            publicClient: true
        )

        let listener = RedirectListenerMock { authorizationURL in
            let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first(where: { $0.name == "state" })?.value ?? ""
            return URL(string: "basechat://oauth/callback?code=code&state=\(state)")!
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
        // Must not throw even when the server returns 500.
        await authorization.disconnect()
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
