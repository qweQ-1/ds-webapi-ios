import XCTest
@testable import DSWebAPI

final class CredentialExtractorTests: XCTestCase {

    func testFindsTokenByStorageKey() {
        let storage = ["userToken": "{\"access_token\":\"abc123\",\"expires_in\":3600}"]
        XCTAssertEqual(CredentialExtractor.findToken(in: storage), "abc123")
    }

    func testFindsTokenNestedInJSON() {
        let storage = ["someKey": "{\"data\":{\"auth\":{\"access_token\":\"nested-token-value\"}}}"]
        XCTAssertEqual(CredentialExtractor.findToken(in: storage), "nested-token-value")
    }

    func testFindsTokenInsideOfficialEnvelope() {
        // 官方 storage 处理类把 userToken 写成 { "value": <token>, "__version": ... }
        let storage = ["userToken": "{\"value\":\"opaque-token-value-1234567890\",\"__version\":\"0\"}"]
        XCTAssertEqual(CredentialExtractor.findToken(in: storage), "opaque-token-value-1234567890")
    }

    func testFindsJWTTInsideOfficialEnvelope() {
        let storage = ["userToken": "{\"value\":\"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc\",\"__version\":\"2\"}"]
        XCTAssertEqual(CredentialExtractor.findToken(in: storage), "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc")
    }

    func testIgnoresNonTokenWrappedValue() {
        // value 是用户 id 之类不叫 token 的字段，不应被当成凭证
        let storage = ["someKey": "{\"value\":\"user-123\",\"__version\":\"0\"}"]
        XCTAssertNil(CredentialExtractor.findToken(in: storage))
    }

    func testFindsPlainTokenValue() {
        let storage = ["access_token": "plain-token-value-1234567890"]
        XCTAssertEqual(CredentialExtractor.findToken(in: storage), "plain-token-value-1234567890")
    }

    func testReturnsNilWhenNothingFound() {
        XCTAssertNil(CredentialExtractor.findToken(in: ["theme": "dark", "lang": "zh"]))
    }

    func testRecognizesJWTStyle() {
        XCTAssertTrue(CredentialExtractor.looksLikeToken("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc"))
        XCTAssertFalse(CredentialExtractor.looksLikeToken("short"))
        XCTAssertFalse(CredentialExtractor.looksLikeToken("aaaaaaaaaaaaaaaaaaaaaa"))
    }

    func testCookieHeaderKeepsOnlyDeepSeekCookies() {
        let cookies = [
            HTTPCookie(properties: [
                .domain: "chat.deepseek.com",
                .path: "/",
                .name: "session",
                .value: "abc"
            ])!,
            HTTPCookie(properties: [
                .domain: "example.com",
                .path: "/",
                .name: "other",
                .value: "xyz"
            ])!
        ]
        let header = CredentialExtractor.cookieHeader(from: cookies)
        XCTAssertTrue(header.contains("session=abc"))
        XCTAssertFalse(header.contains("other=xyz"))
    }
}
