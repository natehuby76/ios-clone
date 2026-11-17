import Foundation
import XCTest
@testable import StarPortReceiver

final class StarPortWireTests: XCTestCase {
    func testVersionRequestMatchesOfficialTabletFixture() throws {
        let frame = StarPortFrame(channel: 0, flags: 3, payload: Data([0, 1, 0, 1, 0, 7]))
        XCTAssertEqual(try frame.encoded(), Data([0, 3, 0, 6, 0, 1, 0, 1, 0, 7]))
        var parser = StarPortFrameParser()
        var output: [StarPortFrame] = []
        for byte in try frame.encoded() { output += try parser.append(Data([byte])) }
        XCTAssertEqual(output, [frame])
        var assembler = StarPortMessageAssembler()
        let message = try assembler.accept(frame, plaintext: frame.payload)
        XCTAssertEqual(message?.kind, 1)
        XCTAssertEqual(message?.body, Data([0, 1, 0, 7]))
    }

    func testEncryptedFragmentLengthIsPlaintextLength() throws {
        let first = StarPortFrame(channel: 3, flags: 9, messageLength: 7, payload: Data(repeating: 99, count: 30))
        let last = StarPortFrame(channel: 3, flags: 10, payload: Data(repeating: 88, count: 24))
        var parser = StarPortFrameParser()
        let frames = try parser.append(first.encoded() + last.encoded())
        XCTAssertEqual(frames, [first, last])
        var assembler = StarPortMessageAssembler()
        XCTAssertNil(try assembler.accept(first, plaintext: Data([0, 0, 1, 2])))
        let message = try assembler.accept(last, plaintext: Data([3, 4, 5]))
        XCTAssertEqual(message?.channel, 3)
        XCTAssertEqual(message?.kind, 0)
        XCTAssertEqual(message?.body, Data([1, 2, 3, 4, 5]))
    }

    func testRejectsUnboundedAndBrokenFragmentSequences() throws {
        var assembler = StarPortMessageAssembler()
        let orphan = StarPortFrame(channel: 3, flags: 10, payload: Data([1]))
        XCTAssertThrowsError(try assembler.accept(orphan, plaintext: Data([1])))
        let huge = StarPortFrame(channel: 3, flags: 9,
            messageLength: StarPortMessageAssembler.maximumMessage + 1, payload: Data([1]))
        XCTAssertThrowsError(try huge.encoded())
        let first = StarPortFrame(channel: 3, flags: 9, messageLength: 8, payload: Data([1]))
        XCTAssertNil(try assembler.accept(first, plaintext: Data([0, 0, 1])))
        XCTAssertThrowsError(try assembler.accept(first, plaintext: Data([0, 0, 1])))
        XCTAssertThrowsError(try assembler.accept(orphan, plaintext: Data([2])))
        var parser = StarPortFrameParser()
        XCTAssertThrowsError(try parser.append(Data([0, 0x80, 0, 1, 1])))
    }
}
