import Foundation
import XCTest
@testable import BaseChatMCP
import BaseChatTestSupport

final class MCPStdioTransportTests: XCTestCase {
    #if os(macOS) && !targetEnvironment(macCatalyst)
    func test_sendFramesPayloadAndParsesResponse() async throws {
        let echoScript = """
        import re, sys

        header = b""
        while b"\\r\\n\\r\\n" not in header:
            chunk = sys.stdin.buffer.read(1)
            if not chunk:
                sys.exit(0)
            header += chunk

        head, rest = header.split(b"\\r\\n\\r\\n", 1)
        match = re.search(br"Content-Length:\\s*(\\d+)", head, re.IGNORECASE)
        if not match:
            sys.exit(1)
        length = int(match.group(1))

        body = rest
        while len(body) < length:
            chunk = sys.stdin.buffer.read(length - len(body))
            if not chunk:
                sys.exit(1)
            body += chunk

        framed = b"Content-Length: " + str(len(body)).encode("ascii") + b"\\r\\n\\r\\n" + body
        sys.stdout.buffer.write(framed)
        sys.stdout.buffer.flush()
        """

        let transport = MCPStdioTransport(
            command: .executable(
                at: URL(fileURLWithPath: "/usr/bin/python3"),
                args: ["-u", "-c", echoScript]
            ),
            maxMessageBytes: 4_096
        )
        let payload = Data("{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}".utf8)

        try await transport.start()
        defer { Task { await transport.close() } }
        try await transport.send(payload)

        let stream = transport.incomingMessages
        let received = try await withTimeout(.seconds(2)) {
            for try await payload in stream {
                return payload
            }
            throw MCPError.transportClosed
        }
        XCTAssertEqual(received, payload)
    }

    func test_startRejectsShellExecutable() async {
        let transport = MCPStdioTransport(
            command: .executable(at: URL(fileURLWithPath: "/bin/sh"), args: ["-c", "echo unsafe"]),
            maxMessageBytes: 4_096
        )

        do {
            try await transport.start()
            XCTFail("Expected shell executable rejection")
        } catch let error as MCPError {
            XCTAssertEqual(error, .transportFailure("stdio executable must not be a shell"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_closeTerminatesProcessDeterministically() async throws {
        let transport = MCPStdioTransport(
            command: .executable(at: URL(fileURLWithPath: "/bin/sleep"), args: ["30"]),
            maxMessageBytes: 4_096
        )

        try await transport.start()
        try await withTimeout(.seconds(2)) {
            await transport.close()
        }

        do {
            try await transport.send(Data("{}".utf8))
            XCTFail("Expected transportClosed after close")
        } catch let error as MCPError {
            XCTAssertEqual(error, .transportClosed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    #endif

    func test_environmentPolicyScrubsInheritedAndAllowsExplicitOverrides() {
        let inherited = [
            "PATH": "/usr/bin",
            "HOME": "/Users/tester",
            "SSH_AUTH_SOCK": "/private/tmp/agent.sock",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
        ]
        let explicit = [
            "CUSTOM_TOKEN": "abc123",
            "BAD\0KEY": "ignored",
            "GOOD_VALUE": "ok",
            "NULL_VALUE": "bad\0value",
        ]

        let sanitized = MCPStdioEnvironmentPolicy.sanitizedEnvironment(
            inherited: inherited,
            explicit: explicit
        )

        XCTAssertEqual(sanitized["PATH"], "/usr/bin")
        XCTAssertEqual(sanitized["HOME"], "/Users/tester")
        XCTAssertEqual(sanitized["CUSTOM_TOKEN"], "abc123")
        XCTAssertEqual(sanitized["GOOD_VALUE"], "ok")
        XCTAssertNil(sanitized["SSH_AUTH_SOCK"])
        XCTAssertNil(sanitized["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(sanitized["BAD\0KEY"])
        XCTAssertNil(sanitized["NULL_VALUE"])
    }

    func test_connectStdioUsesPlatformGating() async {
        let descriptor = MCPServerDescriptor(
            displayName: "Stdio",
            transport: .stdio(.executable(at: URL(fileURLWithPath: "/bin/sh"), args: ["-c", "echo nope"])),
            dataDisclosure: "test"
        )

        let client = MCPClient()

        do {
            _ = try await client.connect(descriptor)
            XCTFail("Expected stdio connect to fail without a full MCP server")
        } catch let error as MCPError {
            #if os(macOS) && !targetEnvironment(macCatalyst)
            XCTAssertEqual(error, .transportFailure("stdio executable must not be a shell"))
            #else
            XCTAssertEqual(error, .transportFailure("stdio MCP transport is unavailable on this platform"))
            #endif
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
