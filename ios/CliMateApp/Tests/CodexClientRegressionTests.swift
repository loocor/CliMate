import XCTest
@testable import CliMate

final class CodexClientRegressionTests: XCTestCase {
    @MainActor
    func testConnectInvalidURLSetsErrorAndKeepsDisconnected() {
        let client = CodexClient()

        client.connect(urlString: "", mode: .manual)

        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertEqual(client.lastError, "Invalid URL")
    }

    @MainActor
    func testConnectUnsupportedSchemeSetsErrorAndKeepsDisconnected() {
        let client = CodexClient()

        client.connect(urlString: "https://example.com:4500", mode: .manual)

        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertEqual(client.lastError, "Only http:// is supported (server is HTTP + SSE).")
    }

    @MainActor
    func testConnectMissingHostSetsErrorAndKeepsDisconnected() {
        let client = CodexClient()

        client.connect(urlString: "http:///", mode: .manual)

        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertEqual(client.lastError, "Invalid URL (missing host)")
    }

    @MainActor
    func testAutoConnectInvalidURLDoesNotSetUserFacingError() {
        let client = CodexClient()

        client.connect(urlString: "", mode: .auto)

        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertNil(client.lastError)
    }

    @MainActor
    func testAutoConnectUnsupportedSchemeDoesNotSetUserFacingError() {
        let client = CodexClient()

        client.connect(urlString: "https://example.com:4500", mode: .auto)

        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertNil(client.lastError)
    }

    @MainActor
    func testAutoConnectMissingHostDoesNotSetUserFacingError() {
        let client = CodexClient()

        client.connect(urlString: "http:///", mode: .auto)

        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertNil(client.lastError)
    }

    @MainActor
    func testConnectIgnoredWhenNotDisconnected() {
        let client = CodexClient()
        client.connectionState = .connecting

        client.connect(urlString: "not-a-url", mode: .manual)

        XCTAssertEqual(client.connectionState, .connecting)
        XCTAssertNil(client.lastError)
    }

    @MainActor
    func testDisconnectIsIdempotent() {
        let client = CodexClient()

        client.disconnect()
        client.disconnect()

        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertNil(client.pendingApproval)
    }

    @MainActor
    func testDisconnectCanPreserveRetryAttemptForAutoRetry() {
        let client = CodexClient()
        client.setRetryAttemptForTests(3)

        client.disconnect(cancelRetryTask: false, resetRetryAttempt: false)

        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertEqual(client.retryAttemptForTests(), 3)
    }

    @MainActor
    func testDisconnectDefaultResetsRetryAttempt() {
        let client = CodexClient()
        client.setRetryAttemptForTests(3)

        client.disconnect()

        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertEqual(client.retryAttemptForTests(), 0)
    }

    func testSSEPayloadKindForServerRequest() {
        let payload = "{\"id\":1,\"method\":\"item/commandExecution/requestApproval\",\"params\":{}}"
        XCTAssertEqual(CodexClient.ssePayloadKindForTests(payload), .serverRequest)
    }

    func testSSEPayloadKindForResponse() {
        let payload = "{\"id\":1,\"result\":{\"ok\":true}}"
        XCTAssertEqual(CodexClient.ssePayloadKindForTests(payload), .response)
    }

    func testSSEPayloadKindForTranscriptEvents() {
        let delta = "{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"hello\"}}"
        let completed = "{\"method\":\"turn/completed\"}"
        let err = "{\"method\":\"error\",\"params\":{\"message\":\"boom\"}}"

        XCTAssertEqual(CodexClient.ssePayloadKindForTests(delta), .transcriptDelta)
        XCTAssertEqual(CodexClient.ssePayloadKindForTests(completed), .transcriptBoundary)
        XCTAssertEqual(CodexClient.ssePayloadKindForTests(err), .transcriptError)
    }

    func testSSEPayloadKindForInvalidJSON() {
        XCTAssertEqual(CodexClient.ssePayloadKindForTests("not-json"), .ignore)
    }

    func testSSEPayloadKindForResponseWithStringId() {
        let payload = "{\"id\":\"42\",\"result\":{\"ok\":true}}"
        XCTAssertEqual(CodexClient.ssePayloadKindForTests(payload), .response)
    }

    func testSSEPayloadKindForUnknownMethodIsIgnored() {
        let payload = "{\"method\":\"unknown/method\",\"params\":{}}"
        XCTAssertEqual(CodexClient.ssePayloadKindForTests(payload), .ignore)
    }

    func testTranscriptClippingKeepsLatestSuffix() {
        let prefix = String(repeating: "x", count: 150_000)
        let suffix = String(repeating: "y", count: 60_000)
        let full = prefix + suffix

        let clipped = CodexClient.clippedTranscriptForTests(full, max: 200_000)

        XCTAssertEqual(clipped.count, 200_000)
        XCTAssertTrue(clipped.hasSuffix(suffix))
    }

    func testTranscriptClippingNoOpWhenUnderLimit() {
        let text = "hello"
        XCTAssertEqual(CodexClient.clippedTranscriptForTests(text, max: 200_000), text)
    }

    func testTranscriptClippingReturnsEmptyWhenMaxNonPositive() {
        XCTAssertEqual(CodexClient.clippedTranscriptForTests("hello", max: 0), "")
        XCTAssertEqual(CodexClient.clippedTranscriptForTests("hello", max: -1), "")
    }

    func testRetryDelayIncreasesAndCaps() {
        XCTAssertEqual(CodexClient.retryDelaySecondsForTests(attempt: 1), 1.6, accuracy: 0.0001)
        XCTAssertEqual(CodexClient.retryDelaySecondsForTests(attempt: 2), 2.56, accuracy: 0.0001)
        XCTAssertEqual(CodexClient.retryDelaySecondsForTests(attempt: 100), 20.0, accuracy: 0.0001)
    }

    func testRetryDelayNormalizesNonPositiveAttempt() {
        XCTAssertEqual(CodexClient.retryDelaySecondsForTests(attempt: 0), 1.6, accuracy: 0.0001)
        XCTAssertEqual(CodexClient.retryDelaySecondsForTests(attempt: -3), 1.6, accuracy: 0.0001)
    }
}
