// Test fixture for test.sh: writes a mono FLAC of any bit depth (verbatim subframes), including
// depths afconvert can't encode. Usage: make-flac <bits> <rate> <seconds> <out.flac>
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 5, let bits = Int(args[1]), let rate = Int(args[2]), let seconds = Double(args[3]),
      let bitsCode = [8: 1, 12: 2, 16: 4, 20: 5, 24: 6, 32: 7][bits],
      let rateCode = [88_200: 1, 176_400: 2, 192_000: 3, 32_000: 8, 44_100: 9, 48_000: 10, 96_000: 11][rate] else {
    FileHandle.standardError.write("usage: make-flac <8|12|16|20|24|32> <32000|44100|48000|88200|96000|176400|192000> <seconds> <out.flac>\n".data(using: .utf8)!)
    exit(2)
}
let count = Int(Double(rate) * seconds), block = 4096
let peak = Double((Int64(1) << (bits - 1)) - 1) * 0.9
let samples = (0..<count).map { i in   // a sine, plus detail in the lowest bits
    Int32(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * peak) &+ Int32(i % 3)
}

struct BitWriter {
    var bytes: [UInt8] = []
    private var acc: UInt64 = 0, used = 0
    mutating func write(_ value: UInt64, _ n: Int) {
        for i in (0..<n).reversed() {
            acc = acc << 1 | (value >> UInt64(i) & 1); used += 1
            if used == 8 { bytes.append(UInt8(acc)); acc = 0; used = 0 }
        }
    }
    mutating func padToByte() { if used > 0 { write(0, 8 - used) } }
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
/// FLAC codes frame numbers like UTF-8.
func utf8Coded(_ n: Int) -> [UInt8] {
    if n < 0x80 { return [UInt8(n)] }
    if n < 0x800 { return [0xC0 | UInt8(n >> 6), 0x80 | UInt8(n & 0x3F)] }
    return [0xE0 | UInt8(n >> 12), 0x80 | UInt8(n >> 6 & 0x3F), 0x80 | UInt8(n & 0x3F)]
}

var md5 = Insecure.MD5()   // over signed little-endian samples, ceil(bits/8) bytes each
let sampleBytes = (bits + 7) / 8
for s in samples { withUnsafeBytes(of: s.littleEndian) { md5.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<sampleBytes])) } }

var w = BitWriter()
w.bytes = Array("fLaC".utf8) + [0x80, 0, 0, 34]   // last metadata block: STREAMINFO
w.write(UInt64(block), 16); w.write(UInt64(block), 16); w.write(0, 24); w.write(0, 24)   // frame sizes unknown
w.write(UInt64(rate), 20); w.write(0, 3); w.write(UInt64(bits - 1), 5); w.write(UInt64(count), 36)
w.bytes += Array(md5.finalize())
var out = w.bytes

for (frame, start) in stride(from: 0, to: count, by: block).enumerated() {
    let part = samples[start..<min(start + block, count)]
    // Fixed block size; 16-bit block size at the end of the header; mono.
    var header: [UInt8] = [0xFF, 0xF8, 0x70 | UInt8(rateCode), UInt8(bitsCode << 1)] + utf8Coded(frame)
    header += [UInt8((part.count - 1) >> 8), UInt8((part.count - 1) & 0xFF)]
    header.append(crc8(header))
    var f = BitWriter()
    f.bytes = header
    f.write(0x02, 8)   // verbatim subframe
    for s in part { f.write(UInt64(UInt32(bitPattern: s)) & (UInt64(1) << bits - 1), bits) }
    f.padToByte()
    let c = crc16(f.bytes)
    out += f.bytes + [UInt8(c >> 8), UInt8(c & 0xFF)]
}
try Data(out).write(to: URL(fileURLWithPath: args[4]))
