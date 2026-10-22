import XCTest
@testable import DSWebAPI

/// SHA3-256 自研实现的正确性验证（NIST 标准测试向量）
final class SHA3DigestTests: XCTestCase {

    func testEmptyString() {
        XCTAssertEqual(SHA3Digest.hexHash(""),
                       "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a")
    }

    func testAbc() {
        XCTAssertEqual(SHA3Digest.hexHash("abc"),
                       "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532")
    }

    func testLongNISTVector() {
        let text = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno"
            + "ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
        XCTAssertEqual(SHA3Digest.hexHash(text),
                       "916f6061fe879741ca6469b43971dfdb28b1a32dc36cb3254e812be27aad1d18")
    }

    func testIncrementalUpdateMatchesOneShot() {
        var digest = SHA3Digest()
        digest.update("ab")
        digest.update("c")
        XCTAssertEqual(digest.finalize().map { String(format: "%02x", $0) }.joined(),
                       "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532")
    }

    func testResetAllowsReuse() {
        var digest = SHA3Digest()
        digest.update("abc")
        _ = digest.finalize()
        digest.reset()
        digest.update("abc")
        XCTAssertEqual(digest.finalize().map { String(format: "%02x", $0) }.joined(),
                       "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532")
    }

    func testHexBytesParsing() {
        XCTAssertEqual(SHA3Digest.hexBytes("00ff"), [0x00, 0xFF])
        XCTAssertNil(SHA3Digest.hexBytes("0"))
        XCTAssertNil(SHA3Digest.hexBytes("zz"))
    }
}
