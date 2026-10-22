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
