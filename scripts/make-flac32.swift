// Test fixture for test.sh: writes a 1 s, mono, 32-bit / 44.1 kHz FLAC (verbatim subframes),
// which afconvert can't encode. Usage: make-flac32 <out.flac>
import CryptoKit
import Foundation

let rate = 44_100, count = 44_100, block = 4096
let samples = (0..<count).map { i in
    Int32(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 2e9) &+ Int32(i % 251)   // detail below 24-bit
}

func crc8(_ bytes: [UInt8]) -> UInt8 {
    var c: UInt8 = 0
    for b in bytes { c ^= b; for _ in 0..<8 { c = c & 0x80 != 0 ? (c << 1) ^ 0x07 : c << 1 } }
    return c
}
func crc16(_ bytes: [UInt8]) -> UInt16 {
    var c: UInt16 = 0
    for b in bytes { c ^= UInt16(b) << 8; for _ in 0..<8 { c = c & 0x8000 != 0 ? (c << 1) ^ 0x8005 : c << 1 } }
    return c
}
func bigEndian<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }

var md5 = Insecure.MD5()
for s in samples { withUnsafeBytes(of: s.littleEndian) { md5.update(bufferPointer: $0) } }

// STREAMINFO: block sizes, unknown frame sizes, then rate(20) channels-1(3) bps-1(5) total(36), MD5.
var out = Array("fLaC".utf8) + [0x80, 0, 0, 34]
out += bigEndian(UInt16(block)) + bigEndian(UInt16(block)) + [0, 0, 0, 0, 0, 0]
out += bigEndian(UInt64(rate) << 44 | 31 << 36 | UInt64(count))
out += Array(md5.finalize())

for (frame, start) in stride(from: 0, to: count, by: block).enumerated() {
    let samplesInFrame = samples[start..<min(start + block, count)]
    // Fixed block size; 16-bit block size follows; 44.1 kHz; mono; 32-bit; frame number < 128.
    var f: [UInt8] = [0xFF, 0xF8, 0x79, 0x07, UInt8(frame)] + bigEndian(UInt16(samplesInFrame.count - 1))
    f.append(crc8(f))
    f.append(0x02)   // verbatim subframe
    for s in samplesInFrame { f += bigEndian(s) }
    out += f + bigEndian(crc16(f))
}
try Data(out).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
