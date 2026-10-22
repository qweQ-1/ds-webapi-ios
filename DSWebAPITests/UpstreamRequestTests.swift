import XCTest
@testable import DSWebAPI

final class UpstreamRequestTests: XCTestCase {

    private func makeClient(token: String = "tok-123") -> DeepSeekWebClient {
        DeepSeekWebClient(baseURL: URL(string: "https://chat.deepseek.com")!,
                          accessToken: token,
                          sessionCookie: "",
                          deviceID: "device-abc",
                          clientVersion: "20250101.99999")
    }

    func testRequestTargetsWebEndpoint() throws {
        let client = makeClient()
        let request = try client.makeRequest(messages: [.init(role: "user", content: "你好")],
                                             options: .init(),
                                             stream: true)
        XCTAssertEqual(request.url?.absoluteString, "https://chat.deepseek.com/api/v0/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testRequestCarriesAuthAndDeviceHeaders() throws {
        let client = makeClient()
        let request = try client.makeRequest(messages: [.init(role: "user", content: "hi")],
                                             options: .init(),
                                             stream: true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-device-id"), "device-abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-device-os"), "iOS")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-client-locale"), "zh_CN")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-parent-app-id"), "0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
    }

    func testRequestBodyHasExpectedFields() throws {
        var options = DeepSeekWebClient.Options()
        options.model = "deepseek-reasoner"
        options.thinkingEnabled = true
        options.temperature = 0.3
        options.maxTokens = 2048

        let client = makeClient()
        let request = try client.makeRequest(messages: [.init(role: "user", content: "hi")],
                                             options: options,
                                             stream: true)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "deepseek-reasoner")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["thinking_enabled"] as? Bool, true)
        XCTAssertEqual(body["search_enabled"] as? Bool, false)
        XCTAssertEqual(body["temperature"] as? Double, 0.3)
        XCTAssertEqual(body["max_tokens"] as? Int, 2048)
        XCTAssertNotNil(body["id"] as? String)
        XCTAssertNotNil(body["conversation_id"] as? String)

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "hi")
    }

    func testMissingCredentialThrows() {
        let client = makeClient(token: "")
        XCTAssertThrowsError(try client.makeRequest(messages: [.init(role: "user", content: "hi")],
                                                     options: .init(),
                                                     stream: true))
    }

    func testParseMessagesAcceptsStringAndArrayContent() {
        let raw: [[String: Any]] = [
            ["role": "user", "content": "纯文本"],
            ["role": "user", "content": [["type": "text", "text": "多模态文本"]]],
            ["role": "assistant", "content": ""]
        ]
        let messages = BridgeServer.parseMessages(raw)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].content, "纯文本")
        XCTAssertEqual(messages[1].content, "多模态文本")
        XCTAssertEqual(messages[0].role, "user")
    }

    func testParseMessagesIgnoresInvalidInput() {
        XCTAssertTrue(BridgeServer.parseMessages(nil).isEmpty)
        XCTAssertTrue(BridgeServer.parseMessages("not a list").isEmpty)
    }
}
