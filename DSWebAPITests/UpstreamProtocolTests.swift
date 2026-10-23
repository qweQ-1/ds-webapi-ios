import XCTest
@testable import DSWebAPI

final class UpstreamProtocolTests: XCTestCase {

    private func makeClient(token: String = "tok-123") -> DeepSeekWebClient {
        DeepSeekWebClient(baseURL: URL(string: "https://chat.deepseek.com")!,
                          accessToken: token,
                          sessionCookie: "",
                          deviceID: "device-abc",
                          deviceModel: "iPhone",
                          clientVersion: "20250101.99999")
    }

    // MARK: - 请求构造

    func testCompletionRequestTargetsRealEndpoint() throws {
        let client = makeClient()
        let request = try client.makeCompletionRequest(prompt: "你好",
                                                        options: .init(),
                                                        chatSessionID: "session-1",
                                                        parentMessageID: nil,
                                                        powHeader: "")
        XCTAssertEqual(request.url?.absoluteString, "https://chat.deepseek.com/api/v0/chat/completion")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    func testCompletionRequestCarriesAuthDeviceAndPowHeaders() throws {
        let client = makeClient()
        let request = try client.makeCompletionRequest(prompt: "hi",
                                                        options: .init(),
                                                        chatSessionID: "session-1",
                                                        parentMessageID: "msg-1",
                                                        powHeader: "BASE64VALUE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-DS-PoW-Response"), "BASE64VALUE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-device-id"), "device-abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-device-model"), "iPhone")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-client-locale"), "zh-CN")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-client-platform"), "web")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-client-bundle-id"), "com.deepseek.chat")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "x-client-version"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "x-client-timezone-offset"))
    }

    func testCompletionRequestCarriesHIFRiskHeaders() throws {
        let client = makeClient()
        let request = try client.makeCompletionRequest(prompt: "hi",
                                                        options: .init(),
                                                        chatSessionID: "session-1",
                                                        parentMessageID: nil,
                                                        powHeader: "BASE64VALUE",
                                                        hifHeaders: [
                                                            "x-hif-leim": "LEIM-VALUE",
                                                            "x-hif-dliq": "DLIQ-VALUE"
                                                        ])
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-hif-leim"), "LEIM-VALUE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-hif-dliq"), "DLIQ-VALUE")
    }

    func testSharedClientHeadersDoNotLeakCredentials() {
        let headers = makeClient().clientHeaderFields
        XCTAssertEqual(headers["x-device-id"], "device-abc")
        XCTAssertNotNil(headers["x-client-version"])
        XCTAssertNil(headers["Authorization"])
        XCTAssertNil(headers["Cookie"])
    }

    func testCompletionRequestBodyHasExpectedFields() throws {
        var options = DeepSeekWebClient.Options()
        options.modelType = "deepseek-reasoner"
        options.thinkingEnabled = true
        options.searchEnabled = true

        let client = makeClient()
        let request = try client.makeCompletionRequest(prompt: "讲个笑话",
                                                        options: options,
                                                        chatSessionID: "session-xyz",
                                                        parentMessageID: "parent-1",
                                                        powHeader: "")

        let httpBody = try XCTUnwrap(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: httpBody)
        let body = try XCTUnwrap(object as? [String: Any])

        XCTAssertEqual(body["chat_session_id"] as? String, "session-xyz")
        XCTAssertEqual(body["parent_message_id"] as? String, "parent-1")
        XCTAssertEqual(body["model_type"] as? String, "deepseek-reasoner")
        XCTAssertEqual(body["prompt"] as? String, "讲个笑话")
        XCTAssertEqual(body["thinking_enabled"] as? Bool, true)
        XCTAssertEqual(body["search_enabled"] as? Bool, true)
        XCTAssertNotNil(body["ref_file_ids"] as? [Any])
    }

    func testCompletionRequestWithoutParentMessageSendsNull() throws {
        let client = makeClient()
        let request = try client.makeCompletionRequest(prompt: "hi",
                                                        options: .init(),
                                                        chatSessionID: "s",
                                                        parentMessageID: nil,
                                                        powHeader: "")
        let httpBody = try XCTUnwrap(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: httpBody)
        let body = try XCTUnwrap(object as? [String: Any])
        XCTAssertTrue(body["parent_message_id"] is NSNull)
    }

    // MARK: - 工作量证明

    /// 真实向量：prefix = "<salt>_<expireAt>_"，SHA3-256(prefix + "257") == challenge
    func testProofOfWorkSolvesKnownVector() throws {
        var challenge = DeepSeekWebClient.Challenge()
        challenge.algorithm = "DeepSeekHashV1"
        challenge.challenge = "0073b08ac980ce93ca1329ba719987fae7e4fb175686d0bf1f522494402bcf95"
        challenge.salt = "1234567890123456"
        challenge.expireAt = "1792670999665"
        challenge.difficulty = 258
        challenge.signature = "sig"

        XCTAssertEqual(challenge.prefix, "1234567890123456_1792670999665_")
        let answer = try challenge.solve()
        XCTAssertEqual(answer, 257)
    }

    func testParsesChallengeFromServerDict() {
        let dict: [String: Any] = [
            "algorithm": "DeepSeekHashV1",
            "challenge": "0073b08ac980ce93ca1329ba719987fae7e4fb175686d0bf1f522494402bcf95",
            "salt": 1234567890123456,
            "difficulty": 258,
            "signature": "sig-1",
            "expire_at": 1792670999665
        ]
        let challenge = DeepSeekWebClient.parseChallenge(dict)
        XCTAssertEqual(challenge.algorithm, "DeepSeekHashV1")
        XCTAssertEqual(challenge.salt, "1234567890123456")
        XCTAssertEqual(challenge.expireAt, "1792670999665")
        XCTAssertEqual(challenge.difficulty, 258)
        XCTAssertEqual(challenge.prefix, "1234567890123456_1792670999665_")
    }

    func testJSStringFormatting() {
        XCTAssertEqual(DeepSeekWebClient.jsString(12345 as NSNumber), "12345")
        XCTAssertEqual(DeepSeekWebClient.jsString(1792670999665 as NSNumber), "1792670999665")
        XCTAssertEqual(DeepSeekWebClient.jsString("abc" as String), "abc")
    }

    func testProofOfWorkRejectsUnknownAlgorithm() {
        var challenge = DeepSeekWebClient.Challenge()
        challenge.algorithm = "Nope"
        challenge.challenge = "00"
        challenge.salt = "10"
        XCTAssertThrowsError(try challenge.solve())
    }

    func testPowHeaderIsBase64JSON() throws {
        var challenge = DeepSeekWebClient.Challenge()
        challenge.algorithm = "DeepSeekHashV1"
        challenge.challenge = "abc"
        challenge.salt = "100"
        challenge.difficulty = 4
        challenge.signature = "sig"

        let client = makeClient()
        let header = client.powHeaderValue(challenge: challenge, answer: 7, guest: false)

        let data = try XCTUnwrap(Data(base64Encoded: header))
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(json["algorithm"] as? String, "DeepSeekHashV1")
        XCTAssertEqual(json["challenge"] as? String, "abc")
        XCTAssertEqual(json["salt"] as? Int, 100)
        XCTAssertEqual(json["answer"] as? Int, 7)
        XCTAssertEqual(json["signature"] as? String, "sig")
        XCTAssertEqual(json["target_path"] as? String, "/api/v0/chat/completion")
    }

    func testGuestPowHeaderOnlyCarriesSaltAndAnswer() throws {
        var challenge = DeepSeekWebClient.Challenge()
        challenge.salt = "42"
        let client = makeClient()
        let header = client.powHeaderValue(challenge: challenge, answer: 3, guest: true)

        let data = try XCTUnwrap(Data(base64Encoded: header))
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(json["salt"] as? Int, 42)
        XCTAssertEqual(json["answer"] as? Int, 3)
        XCTAssertNil(json["challenge"])
    }

    // MARK: - 挑战解析

    func testFindsChallengeInsideBizData() throws {
        let raw = """
        {"code":0,"data":{"biz_code":0,"biz_msg":"","biz_data":{"challenge":{
            "algorithm":"DeepSeekHashV1","challenge":"0011ff","salt":1000,
            "difficulty":4,"signature":"sig-1","expire_at":123.5}}}}
        """
        let json = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
        let found = try XCTUnwrap(DeepSeekWebClient.findChallenge(in: json))
        XCTAssertEqual(found["challenge"] as? String, "0011ff")
        XCTAssertEqual(DeepSeekWebClient.intValue(found["salt"]), 1000)
        XCTAssertEqual(DeepSeekWebClient.intValue(found["difficulty"]), 4)
        XCTAssertEqual(found["signature"] as? String, "sig-1")
    }

    func testFindsChallengeWithStringNumbers() throws {
        let raw = """
        {"data":{"biz_data":{"challenge":{"challenge":"00ff","salt":"2048","difficulty":"3"}}}}
        """
        let json = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
        let found = try XCTUnwrap(DeepSeekWebClient.findChallenge(in: json))
        XCTAssertEqual(DeepSeekWebClient.intValue(found["salt"]), 2048)
        XCTAssertEqual(DeepSeekWebClient.intValue(found["difficulty"]), 3)
    }

    func testDetectsErrorPayload() throws {
        let raw = #"{"code":40003,"message":"Authorization Failed"}"#
        let json = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
        XCTAssertEqual(DeepSeekWebClient.errorMessage(in: json), "Authorization Failed")
    }

    // MARK: - 消息解析

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

    func testExtractsMessageIDFromEvent() {
        let event = SSEEvent(id: nil, event: "delta", data: "{\"biz_data\":{\"message_id\":\"m-42\"}}", retry: nil)
        XCTAssertEqual(BridgeServer.messageID(in: event), "m-42")
    }

    // MARK: - 会话登记

    func testMapsModelToOfficialModelType() {
        XCTAssertEqual(DeepSeekWebClient.upstreamModelType("deepseek-chat"), "default")
        XCTAssertEqual(DeepSeekWebClient.upstreamModelType("deepseek-reasoner"), "expert")
        XCTAssertEqual(DeepSeekWebClient.upstreamModelType("deepseek-coder"), "default")
        XCTAssertEqual(DeepSeekWebClient.upstreamModelType("anything-else"), "default")
    }

    func testFindsSessionIDInsideCreateResponse() throws {
        let raw = """
        {"code":0,"data":{"biz_code":0,"biz_msg":"","biz_data":{"chat_session":{
            "id":"e6795fb3-272f-4782-87cf-6d6140b5bf76"}}}}
        """
        let json = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
        let found = try XCTUnwrap(DeepSeekWebClient.chatSessionID(in: json))
        XCTAssertEqual(found, "e6795fb3-272f-4782-87cf-6d6140b5bf76")
    }

    func testConversationStoreReusesSessionForSameConversation() {
        let store = BridgeServer.ConversationStore()
        let first = store.state(for: "k", fingerprint: "第一句", messageCount: 1)
        store.updateMessage(id: "m-1", key: "k")
        let second = store.state(for: "k", fingerprint: "第一句", messageCount: 3)
        XCTAssertEqual(first.chatSessionID, second.chatSessionID)
        XCTAssertEqual(second.lastMessageID, "m-1")
    }

    func testConversationStoreStartsNewSessionForDifferentConversation() {
        let store = BridgeServer.ConversationStore()
        let first = store.state(for: "k", fingerprint: "第一句", messageCount: 1)
        let other = store.state(for: "k", fingerprint: "另一句", messageCount: 1)
        XCTAssertNotEqual(first.chatSessionID, other.chatSessionID)
        XCTAssertNil(other.lastMessageID)
    }

    func testConversationStoreMarksLocalSessionsWithAutoPrefix() {
        let store = BridgeServer.ConversationStore()
        let local = store.state(for: "k", fingerprint: "x", messageCount: 1)
        XCTAssertTrue(local.chatSessionID.hasPrefix("auto-"))
    }

    func testConversationStoreCanReplaceWithServerSession() {
        let store = BridgeServer.ConversationStore()
        let local = store.state(for: "k", fingerprint: "x", messageCount: 1)
        let serverID = "e6795fb3-272f-4782-87cf-6d6140b5bf76"
        let serverState = BridgeServer.ConversationState(chatSessionID: serverID,
                                                         lastMessageID: local.lastMessageID,
                                                         fingerprint: "x",
                                                         messageCount: 1)
        store.replace(state: serverState, for: "k")
        let reused = store.state(for: "k", fingerprint: "x", messageCount: 2)
        XCTAssertEqual(reused.chatSessionID, serverID)
    }
}
