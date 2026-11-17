"""Compile the production framing and Annex-B parser without UIKit."""
from pathlib import Path
import sys

source = Path('GalaxyBluetooth/CarPlayLiveVideo.swift').read_text()
packet_parser = source[source.index('struct CarPlayVideoPacket'):source.index('@MainActor')]
start = source.index('    static func nalUnits(')
brace = source.index('{', start)
depth = 1
end = brace + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
nal_parser = source[start:end]
tests = r'''
enum BridgeError: Error { case message(String) }
enum NALParser {
NAL_METHOD
}
@main struct Tests {
    static func main() throws {
        func record(_ payload: [UInt8], id: UInt64 = 42) -> Data {
            var data = Data("SPV1".utf8)
            func integer(_ value: UInt64, _ count: Int) {
                for index in (0..<count).reversed() { data.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
            }
            integer(UInt64(payload.count), 4)
            integer(id, 8); integer(123456, 8); integer(321, 4); integer(654, 4)
            data.append(contentsOf: payload)
            return data
        }
        let frame = record([0, 0, 0, 1, 0x65, 9])
        let heartbeat = record([], id: 0)
        var fragmented = CarPlayVideoParser()
        var received: [CarPlayVideoPacket] = []
        for byte in heartbeat + frame { received += try fragmented.append(Data([byte])) }
        precondition(received.count == 2 && received[0].payload.isEmpty)
        precondition(received[1].frameID == 42 && received[1].captureClock == 123456)
        precondition(received[1].encodeMicroseconds == 321 && received[1].sourceAgeMicroseconds == 654)
        precondition(received[1].payload == Data([0, 0, 0, 1, 0x65, 9]))
        var coalesced = CarPlayVideoParser()
        let batch = try coalesced.append(frame + heartbeat + frame)
        precondition(batch.count == 3)
        var bad = CarPlayVideoParser()
        var invalid = frame; invalid[0] = 0
        do { _ = try bad.append(invalid); fatalError("Accepted invalid magic") } catch {}
        var oversized = CarPlayVideoParser()
        var header = frame.prefix(32)
        header[4] = 0; header[5] = 0x20; header[6] = 0; header[7] = 1
        do { _ = try oversized.append(Data(header)); fatalError("Accepted oversized frame") } catch {}
        let units = NALParser.nalUnits(Data([0, 0, 0, 1, 0x67, 8, 0, 0, 1, 0x68, 9, 0, 0, 0, 1, 0x65, 10]))
        precondition(units == [Data([0x67, 8]), Data([0x68, 9]), Data([0x65, 10])])
        precondition(NALParser.nalUnits(Data()).isEmpty)
        precondition(NALParser.nalUnits(Data([0, 0, 1])).isEmpty)
        print("CarPlay video framing and NAL regression tests passed")
    }
}
'''
Path(sys.argv[1]).write_text('import Foundation\n' + packet_parser + tests.replace('NAL_METHOD', nal_parser))
