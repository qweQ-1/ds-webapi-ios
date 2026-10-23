import XCTest
@testable import DSWebAPI

final class HIFTokenProviderTests: XCTestCase {

    func testParsesOfficialHIFEnvelope() throws {
        let raw = """
        {"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"",
          "biz_data":{"value":"LEIM-TEST-VALUE"}}}
        """
        let value = try HIFTokenProvider.parseValue(in: Data(raw.utf8))
        XCTAssertEqual(value, "LEIM-TEST-VALUE")
    }

    func testRejectsHIFBusinessError() {
        let raw = #"{"code":0,"data":{"biz_code":7,"biz_msg":"rate limit","biz_data":null}}"#
        XCTAssertThrowsError(try HIFTokenProvider.parseValue(in: Data(raw.utf8)))
    }

    func testRejectsEmptyHIFValue() {
        let raw = #"{"code":0,"data":{"biz_code":0,"biz_msg":"","biz_data":{"value":""}}}"#
        XCTAssertThrowsError(try HIFTokenProvider.parseValue(in: Data(raw.utf8)))
    }

    func testTTLHeaderFallsBackToTenMinutes() {
        XCTAssertEqual(HIFTokenProvider.ttlSeconds(fromHeader: "600"), 600)
        XCTAssertEqual(HIFTokenProvider.ttlSeconds(fromHeader: nil), 600)
        XCTAssertEqual(HIFTokenProvider.ttlSeconds(fromHeader: "invalid"), 600)
    }

    func testFailureBackoffGrowsAndCaps() {
        XCTAssertEqual(HIFTokenProvider.failureBackoff(failures: 1), 30)
        XCTAssertEqual(HIFTokenProvider.failureBackoff(failures: 2), 60)
        XCTAssertEqual(HIFTokenProvider.failureBackoff(failures: 6), 600)
        XCTAssertEqual(HIFTokenProvider.failureBackoff(failures: 50), 600)
    }
}
