import XCTest
@testable import DSWebAPI

final class SSEParserTests: XCTestCase {

    func testParsesSimpleEvent() {
        var parser = SSEParser()
        let events = parser.feed("data: hello\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "hello")
    }

    func testParsesEventWithName() {
        var parser = SSEParser()
        let events = parser.feed("event: message\ndata: {\"a\":1}\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.event, "message")
        XCTAssertEqual(events.first?.data, "{\"a\":1}")
    }

    func testParsesMultipleEventsInOneChunk() {
        var parser = SSEParser()
        let events = parser.feed("data: one\n\ndata: two\n\n")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map { $0.data }, ["one", "two"])
    }

    func testKeepsPartialEventUntilSeparator() {
        var parser = SSEParser()
        XCTAssertTrue(parser.feed("data: partial").isEmpty)
        let events = parser.feed("\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "partial")
    }

    func testJoinsMultipleDataLines() {
        var parser = SSEParser()
        let events = parser.feed("data: line1\ndata: line2\n\n")
        XCTAssertEqual(events.first?.data, "line1\nline2")
    }

    func testIgnoresCommentsAndEmptyBlocks() {
        var parser = SSEParser()
        let events = parser.feed(": keepalive\n\n\n\ndata: real\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "real")
    }

    func testFlushReturnsTrailingEvent() {
        var parser = SSEParser()
        XCTAssertTrue(parser.feed("data: tail").isEmpty)
        let events = parser.flush()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "tail")
    }

    func testHandlesCarriageReturns() {
        var parser = SSEParser()
        let events = parser.feed("data: win\r\n\r\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "win")
    }
}
