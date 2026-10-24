import XCTest
@testable import DSWebAPI

/// 网页驱动模式的纯逻辑测试：把网页截获到的原始 SSE 文本还原成回复增量。
final class WebChatDriverTests: XCTestCase {

    // MARK: - 增量解析

    func testCollectorEmitsContentFromOfficialOpsFormat() {
        var collector = WebReplyCollector()
        let raw = "data: {\"p\":\"response/fragments/-1/content\",\"o\":\"APPEND\",\"v\":\"你好\"}\n\n"
        let deltas = collector.ingest(raw: raw)
        XCTAssertEqual(deltas, [.content("你好")])
    }

    func testCollectorHandlesIncrementalChunks() {
        var collector = WebReplyCollector()
        let first = "data: {\"p\":\"response/fragments/-1/content\",\"o\":\"APPEND\",\"v\":\"你\"}\n\ndata: {\"p\":\"resp"
        XCTAssertEqual(collector.ingest(raw: first), [.content("你")])

        let second = first + "onse/status\",\"o\":\"SET\",\"v\":\"FINISHED\"}\n\n"
        let deltas = collector.ingest(raw: second)
        // 第二段把上一段没读完的 data 行拼完了
        XCTAssertTrue(deltas.contains(.finish("stop")) || deltas.contains(.finish(nil)),
                      "应解析出结束信号，实际：\(deltas)")
    }

    func testCollectorDoesNotReparseOldText() {
        var collector = WebReplyCollector()
        let raw = "data: {\"p\":\"response/fragments/-1/content\",\"o\":\"APPEND\",\"v\":\"A\"}\n\n"
        XCTAssertEqual(collector.ingest(raw: raw).count, 1)
        // 同样的文本再喂一次，不应该重复产出
        XCTAssertEqual(collector.ingest(raw: raw).count, 0)
    }

    func testCollectorFlushEmitsPendingEvent() {
        var collector = WebReplyCollector()
        // 最后一段没有换行符，只有 flush 时才会吐出来
        let raw = "data: {\"p\":\"response/fragments/-1/content\",\"o\":\"APPEND\",\"v\":\"尾\"}"
        XCTAssertEqual(collector.ingest(raw: raw).count, 0)
        XCTAssertEqual(collector.flush(), [.content("尾")])
    }

    func testCollectorEmitsThinking() {
        var collector = WebReplyCollector()
        let raw = "data: {\"p\":\"response/fragments/-1/thinking_content\",\"o\":\"APPEND\",\"v\":\"想一下\"}\n\n"
        let deltas = collector.ingest(raw: raw)
        XCTAssertTrue(deltas.contains(.thinking("想一下")), "实际：\(deltas)")
    }

    // MARK: - 快照解析

    func testSnapshotDecode() {
        let json = """
        {"raw":"data: x\\n\\n","count":3,"active":true,"done":false,"error":"","loggedIn":true,"composerFound":true,"href":"https://chat.deepseek.com/"}
        """
        let snap = WebChatDriver.Snapshot.decode(json)
        XCTAssertEqual(snap.count, 3)
        XCTAssertTrue(snap.active)
        XCTAssertFalse(snap.done)
        XCTAssertTrue(snap.loggedIn)
        XCTAssertTrue(snap.composerFound)
        XCTAssertTrue(snap.raw.contains("data: x"))
    }

    func testSnapshotDecodeBadJSONReturnsEmpty() {
        let snap = WebChatDriver.Snapshot.decode("这不是 JSON")
        XCTAssertEqual(snap.count, 0)
        XCTAssertTrue(snap.done)
        XCTAssertFalse(snap.loggedIn)
    }

    // MARK: - 脚本构造

    func testFillScriptEscapesPrompt() {
        let prompt = "他说\"你好\"\n换行 \\ 反斜杠"
        let script = WebChatDriver.fillScript(prompt: prompt)
        // 引号、换行、反斜杠都必须被转义，不能破坏整段 JS
        XCTAssertFalse(script.contains("\n换行"))
        XCTAssertTrue(script.contains("\\\""))
        // 拼回来还应该是同一个字符串
        let decoded = WebChatDriver.jsonString(prompt)
        XCTAssertTrue(decoded.hasPrefix("\""))
        XCTAssertTrue(decoded.hasSuffix("\""))
    }
}
