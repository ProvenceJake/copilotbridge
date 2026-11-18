import XCTest

@testable import CopilotBridgeCore

final class SSEDecoderTests: XCTestCase {
  func testIncrementalParserPreservesLFAndSplitCRLFBoundaries() throws {
    let chunks = [
      Data("data: first\r".utf8),
      Data("\n\r".utf8),
      Data("\ndata: second\n".utf8),
      Data("\n".utf8),
    ]
    let source = chunks.reduce(into: Data()) { $0.append($1) }
    var parser = SSELineParser()
    var lines: [SSELine] = []

    for chunk in chunks {
      lines.append(contentsOf: try parser.feed(chunk))
    }
    if let trailingLine = parser.finish() { lines.append(trailingLine) }

    XCTAssertEqual(lines.map(\.text), ["data: first", "", "data: second", ""])
    XCTAssertEqual(lines.reduce(into: Data()) { $0.append($1.bytes) }, source)

    var decoder = SSEDecoder()
    let events = try lines.compactMap { try decoder.feed(line: $0.text) }
    XCTAssertEqual(events.map(\.data), ["first", "second"])
  }

  func testIncrementalParserFlushesTrailingLineAndSupportsCarriageReturn() throws {
    var parser = SSELineParser()
    let lines = try parser.feed(Data(": keep-alive\rdata: final".utf8))

    XCTAssertEqual(lines.map(\.text), [": keep-alive"])
    XCTAssertEqual(lines.map(\.bytes), [Data(": keep-alive\r".utf8)])

    let trailingLine = try XCTUnwrap(parser.finish())
    XCTAssertEqual(trailingLine.text, "data: final")
    XCTAssertEqual(trailingLine.bytes, Data("data: final".utf8))
    XCTAssertNil(parser.finish())
  }

  func testCombinesMultilineDataAndResetsEventName() throws {
    var decoder = SSEDecoder()
    XCTAssertNil(try decoder.feed(line: "event: response.output_text.delta"))
    XCTAssertNil(try decoder.feed(line: "data: first"))
    XCTAssertNil(try decoder.feed(line: "data:second"))

    let event = try XCTUnwrap(try decoder.feed(line: ""))
    XCTAssertEqual(event.name, "response.output_text.delta")
    XCTAssertEqual(event.data, "first\nsecond")
    XCTAssertNil(try decoder.feed(line: ""))
  }

  func testCommentsAreIgnoredAndTrailingEventCanBeFlushed() throws {
    var decoder = SSEDecoder()
    XCTAssertNil(try decoder.feed(line: ": keep-alive"))
    XCTAssertNil(try decoder.feed(line: "data: [DONE]"))

    let event = try XCTUnwrap(decoder.finish())
    XCTAssertNil(event.name)
    XCTAssertEqual(event.data, "[DONE]")
    XCTAssertNil(decoder.finish())
  }

  func testLineParserRejectsOversizedLineWithoutWaitingForDelimiter() throws {
    var parser = SSELineParser(maximumLineBytes: 4)
    XCTAssertNil(try parser.feed(Data("data".utf8)).first)
    XCTAssertThrowsError(try parser.feed(UInt8(ascii: ":"))) { error in
      XCTAssertEqual(
        error as? BridgeError,
        .protocolFailure("Copilot 上游 SSE 单行超过读取限制。"))
    }
  }

  func testDecoderAppliesIndependentAggregateEventLimit() throws {
    var decoder = SSEDecoder(maximumEventBytes: 7)
    XCTAssertNil(try decoder.feed(line: "data: abc"))
    XCTAssertNil(try decoder.feed(line: "data: def"))
    XCTAssertThrowsError(try decoder.feed(line: "data: x")) { error in
      XCTAssertEqual(
        error as? BridgeError,
        .protocolFailure("Copilot 上游 SSE 单事件超过读取限制。"))
    }
  }

  func testFrameBufferReleasesOnlyCompleteValidatedEventsAndStandaloneComments() throws {
    var frames = SSEFrameBuffer(maximumEventBytes: 7, maximumLineBytes: 64)
    let comment = SSELine(text: ": ping", bytes: Data(": ping\n".utf8))
    XCTAssertEqual(try frames.feed(line: comment)?.bytes, comment.bytes)

    let first = SSELine(text: "data: abc", bytes: Data("data: abc\r\n".utf8))
    let second = SSELine(text: "data: def", bytes: Data("data: def\n".utf8))
    let delimiter = SSELine(text: "", bytes: Data("\n".utf8))
    XCTAssertNil(try frames.feed(line: first))
    XCTAssertNil(try frames.feed(line: second))
    let frame = try XCTUnwrap(try frames.feed(line: delimiter))
    XCTAssertEqual(frame.bytes, first.bytes + second.bytes + delimiter.bytes)
    XCTAssertEqual(frame.event?.data, "abc\ndef")
    XCTAssertNoThrow(try frames.finish())
  }

  func testFrameBufferRejectsOversizedOrUnterminatedEventBeforeRelease() throws {
    var oversized = SSEFrameBuffer(maximumEventBytes: 4, maximumLineBytes: 64)
    XCTAssertNil(
      try oversized.feed(line: SSELine(text: "data: ab", bytes: Data("data: ab\n".utf8))))
    XCTAssertThrowsError(
      try oversized.feed(line: SSELine(text: "data: cd", bytes: Data("data: cd\n".utf8))))

    var unterminated = SSEFrameBuffer(maximumEventBytes: 64, maximumLineBytes: 64)
    XCTAssertNil(
      try unterminated.feed(line: SSELine(text: "data: partial", bytes: Data("data: partial".utf8)))
    )
    XCTAssertThrowsError(try unterminated.finish()) { error in
      XCTAssertEqual(
        error as? BridgeError,
        .protocolFailure("Copilot 上游 SSE 事件在分隔空行前结束。"))
    }
  }
}
