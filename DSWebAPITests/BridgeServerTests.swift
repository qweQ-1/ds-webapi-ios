import XCTest
@testable import DSWebAPI

final class BridgeServerTests: XCTestCase {

    private func message(_ role: String, _ content: String) -> DeepSeekWebClient.UpstreamMessage {
        DeepSeekWebClient.UpstreamMessage(role: role, content: content)
    }

    func testPreparePromptMergesSystemMessageIntoLatestUserPrompt() {
        let messages = [
            message("system", "请始终用中文回答"),
            message("user", "第一问"),
            message("assistant", "第一答"),
            message("user", "第二问")
        ]

        let prompt = BridgeServer.preparePrompt(messages: messages,
                                                configuredSystemPrompt: "")
        XCTAssertEqual(prompt, "请始终用中文回答\n\n第二问")
    }

    func testPreparePromptMergesConfiguredAndDeveloperPrompts() {
        let messages = [
            message("developer", "开发者规则"),
            message("user", "问题")
        ]

        let prompt = BridgeServer.preparePrompt(messages: messages,
                                                configuredSystemPrompt: " 全局规则 ")
        XCTAssertEqual(prompt, "全局规则\n\n开发者规则\n\n问题")
    }

    func testPreparePromptWithoutSystemPromptReturnsLatestUserText() {
        let messages = [
            message("user", "第一问"),
            message("assistant", "回答"),
            message("user", "最后一句")
        ]

        let prompt = BridgeServer.preparePrompt(messages: messages,
                                                configuredSystemPrompt: "")
        XCTAssertEqual(prompt, "最后一句")
    }

    func testSessionStorageExtractionUsesActualStorageKey() {
        let script = LoginWebView.Coordinator.extractScript
        XCTAssertTrue(script.contains("out.ss[k] = sessionStorage.getItem(k);"))
        XCTAssertFalse(script.contains("sessionStorage.getItem(i)"))
    }
}
