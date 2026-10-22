import XCTest
@testable import DSWebAPI

final class UpstreamEventParserTests: XCTestCase {

    private func deltas(_ json: String) -> [UpstreamDelta] {
        UpstreamEventParser.interpret(SSEEvent(id: nil, event: nil, data: json, retry: nil))
    }

    func testParsesOpenAIStyleDelta() {
        let result = deltas("{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"你好\"},\"finish_reason\":null}]}")
        XCTAssertEqual(result, [.content("你好")])
    }

    func testParsesOpenAIStyleReasoning() {
        let result = deltas("{\"choices\":[{\"delta\":{\"reasoning_content\":\"想一想\"}}]}")
        XCTAssertEqual(result, [.thinking("想一想")])
    }

    func testParsesOpenAIStyleFinishReason() {
        let result = deltas("{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}")
        XCTAssertEqual(result, [.finish("stop")])
    }

    func testParsesTopLevelContent() {
        let result = deltas("{\"content\":\"直接给内容\"}")
        XCTAssertEqual(result, [.content("直接给内容")])
    }

    func testParsesTopLevelThinkingContent() {
        let result = deltas("{\"thinking_content\":\"思考中\",\"content\":\"答案\"}")
        XCTAssertEqual(result, [.thinking("思考中"), .content("答案")])
    }

    func testParsesTextField() {
        let result = deltas("{\"text\":\"文本\"}")
        XCTAssertEqual(result, [.content("文本")])
    }

    func testDoneMarkerEndsStream() {
        let result = deltas("[DONE]")
        XCTAssertEqual(result, [.finish("stop")])
    }

    func testErrorPayload() {
        let result = deltas("{\"error\":{\"message\":\"额度用完了\"}}")
        XCTAssertEqual(result, [.failure("额度用完了")])
    }

    func testPlainTextFallback() {
        let result = deltas("纯文本")
        XCTAssertEqual(result, [.content("纯文本")])
    }

    func testFinishEventName() {
        let result = UpstreamEventParser.interpret(SSEEvent(id: nil, event: "finish", data: "{}", retry: nil))
        XCTAssertEqual(result, [.finish("stop")])
    }

    func testUnknownPayloadIsKept() {
        let result = deltas("{\"weird\":123}")
        XCTAssertEqual(result.count, 1)
        if case .unknown = result.first {} else {
            XCTFail("应该是 unknown")
        }
    }
}
