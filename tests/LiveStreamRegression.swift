import Foundation

enum BridgeError: Error { case message(String) }

@main
enum LiveStreamRegression {
    static func expect(_ value: Bool, _ message: String) {
        precondition(value, message)
    }
    static func head(chunked: Bool) -> Data {
        Data(("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=galaxy-frame\r\n" +
              (chunked ? "Transfer-Encoding: chunked\r\n" : "") + "\r\n").utf8)
    }
    static func frame(_ jpeg: Data) -> Data {
        var data = Data("--galaxy-frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
        data.append(jpeg); data.append(Data("\r\n".utf8)); return data
    }
    static func main() throws {
        let jpeg = Data([0xff, 0xd8, 1, 2, 0xff, 0xd9])
        let payload = frame(jpeg)
        var wire = head(chunked: true)
        for start in stride(from: 0, to: payload.count, by: 7) {
            let chunk = Data(payload.dropFirst(start).prefix(7))
            wire.append(Data("\(String(chunk.count, radix: 16))\r\n".utf8))
            wire.append(chunk); wire.append(Data("\r\n".utf8))
        }
        wire.append(Data("0\r\n\r\n".utf8))

        var parser = MJPEGParser()
        var frames: [Data] = []
        for byte in wire { frames += try parser.append(Data([byte])) }
        expect(frames == [jpeg], "Fragmented HTTP chunks must preserve the JPEG.")
        expect(parser.ended, "A normal terminating chunk must end gracefully.")
        expect(try parser.append(Data()).isEmpty, "An ended parser must not generate extra frames.")

        var batched = MJPEGParser()
        expect(try batched.append(wire) == [jpeg], "The final frame must survive a terminator in the same receive.")
        expect(batched.ended, "Batched termination must also be graceful.")

        var unchunked = MJPEGParser()
        var plain = head(chunked: false)
        plain.append(payload); plain.append(payload)
        expect(try unchunked.append(plain) == [jpeg, jpeg], "Unchunked frames must still parse.")

        var unavailable = MJPEGParser()
        do {
            _ = try unavailable.append(Data("HTTP/1.1 503 Unavailable\r\nContent-Type: application/json\r\n\r\n".utf8))
            preconditionFailure("A disabled stream must fail.")
        } catch BridgeError.message(let message) {
            expect(message.contains("disabled"), "Disabled diagnostics must retain a helpful error.")
        }

        var invalid = MJPEGParser()
        var bad = head(chunked: true); bad.append(Data("not-hex\r\n".utf8))
        do {
            _ = try invalid.append(bad)
            preconditionFailure("Invalid chunk lengths must be rejected.")
        } catch { }
        print("Live stream regression checks passed.")
    }
}
