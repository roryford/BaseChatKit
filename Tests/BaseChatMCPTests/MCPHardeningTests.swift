import Foundation
import XCTest
@testable import BaseChatMCP
import BaseChatTestSupport

final class MCPHardeningTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func test_connectRejectsSSRFBlockedTransportEndpoint() async {
        let client = MCPClient()
        let descriptor = MCPServerDescriptor(
            displayName: "Blocked",
            transport: .streamableHTTP(endpoint: URL(string: "https://169.254.169.254/mcp")!, headers: [:]),
            dataDisclosure: "test"
        )

        do {
            _ = try await client.connect(descriptor)
            XCTFail("Expected SSRF rejection")
        } catch let error as MCPError {
            guard case .ssrfBlocked(let blockedURL) = error else {
                XCTFail("Expected ssrfBlocked, got \(error)")
                return
            }
            XCTAssertEqual(blockedURL.absoluteString, "https://169.254.169.254/mcp")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_oauthDiscoveryRejectsSSRFBlockedAuthorizationIssuer() async {
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let resourceMetadataURL = URL(string: "https://resource.example.com/.well-known/oauth-protected-resource")!
        MockURLProtocol.stub(url: resourceMetadataURL, response: .immediate(data: Data(
            """
            { "authorization_servers": ["https://169.254.169.254"] }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))

        let authorization = MCPOAuthAuthorization(
            descriptor: makeDescriptor(issuer: nil),
            serverID: UUID(),
            resourceURL: resourceURL,
            redirectListener: RedirectListenerMock { _ in
                XCTFail("OAuth browser flow should not begin when issuer is blocked")
                return URL(string: "basechat://oauth/callback?code=unused&state=unused")!
            },
            tokenStore: .inMemory(),
            session: makeSession()
        )

        await XCTAssertThrowsErrorAsync(try await authorization.authorizationHeader(for: resourceURL)) { error in
            guard case .ssrfBlocked(let blockedURL) = error as? MCPError else {
                XCTFail("Expected ssrfBlocked, got \(error)")
                return
            }
            XCTAssertEqual(blockedURL.absoluteString, "https://169.254.169.254")
        }
    }

    func test_oauthDiscoveryRejectsSSRFBlockedTokenEndpoint() async throws {
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let issuer = URL(string: "https://auth.example.com")!
        let metadataURL = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!
        MockURLProtocol.stub(url: metadataURL, response: .immediate(data: Data(
            """
            {
              "issuer": "https://auth.example.com",
              "authorization_endpoint": "https://auth.example.com/authorize",
              "token_endpoint": "https://169.254.169.254/token"
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))

        let tokenStore = MCPOAuthTokenStore.inMemory()
        try await tokenStore.write(
            MCPOAuthTokens(
                accessToken: "expired",
                refreshToken: "refresh-token",
                expiresAt: Date().addingTimeInterval(-10),
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
                XCTFail("OAuth browser flow should not begin when token endpoint is blocked")
                return URL(string: "basechat://oauth/callback?code=unused&state=unused")!
            },
            tokenStore: tokenStore,
            session: makeSession()
        )

        await XCTAssertThrowsErrorAsync(try await authorization.authorizationHeader(for: resourceURL)) { error in
            guard case .ssrfBlocked(let blockedURL) = error as? MCPError else {
                XCTFail("Expected ssrfBlocked, got \(error)")
                return
            }
            XCTAssertEqual(blockedURL.absoluteString, "https://169.254.169.254/token")
        }
    }

    func test_networkAndLifecycleObserversPlumbIntoConnectionState() async {
        let networkObserver = TestNetworkPathObserver()
        let lifecycleObserver = TestLifecycleObserver()
        let client = MCPClient(configuration: .init(
            networkPathObserver: networkObserver,
            lifecycleObserver: lifecycleObserver
        ))

        var iterator = client.connectionState.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, .idle)

        networkObserver.emit(.satisfied)
        let afterPath = await iterator.next()
        XCTAssertEqual(afterPath, .idle)

        lifecycleObserver.emit(.willEnterForeground)
        let afterForeground = await iterator.next()
        XCTAssertEqual(afterForeground, .idle)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeDescriptor(issuer: URL?) -> MCPAuthorizationDescriptor.OAuthDescriptor {
        MCPAuthorizationDescriptor.OAuthDescriptor(
            clientName: "BaseChatKit",
            scopes: ["tools:read"],
            redirectURI: URL(string: "basechat://oauth/callback")!,
            authorizationServerIssuer: issuer
        )
    }
}

private final class TestNetworkPathObserver: MCPNetworkPathObserver, @unchecked Sendable {
    let pathUpdates: AsyncStream<MCPNetworkPathStatus>
    private let continuation: AsyncStream<MCPNetworkPathStatus>.Continuation

    init() {
        var streamContinuation: AsyncStream<MCPNetworkPathStatus>.Continuation!
        self.pathUpdates = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func emit(_ status: MCPNetworkPathStatus) {
        continuation.yield(status)
    }
}

private final class TestLifecycleObserver: MCPLifecycleEventObserver, @unchecked Sendable {
    let events: AsyncStream<MCPLifecycleEvent>
    private let continuation: AsyncStream<MCPLifecycleEvent>.Continuation

    init() {
        var streamContinuation: AsyncStream<MCPLifecycleEvent>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func emit(_ event: MCPLifecycleEvent) {
        continuation.yield(event)
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
