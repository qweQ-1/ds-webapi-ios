import Foundation

/// 纯 Swift 的 SHA3-256（Keccak-f[1600] 海绵结构）。
///
/// 为什么不用 CryptoKit：Apple 直到 iOS 26 才把 SHA3 放进 CryptoKit，
/// 而本 App 要支持 iOS 17。DeepSeek 网页端的工作量证明正是用 SHA3-256。
///
/// 参考：FIPS 202、NIST SHA3 测试向量。
struct SHA3Digest {
    /// 速率（字节）：SHA3-256 = 1600 - 2*256 位 = 1088 位 = 136 字节
    private static let rate = 136
    /// 输出长度（字节）
    static let digestLength = 32

    private var state: [UInt64]
    private var scratch: [UInt64]
    private var column: [UInt64]
    private var temp: [UInt64]
    private var buffer: [UInt8]
    private var bufferCount: Int

    init() {
        state = [UInt64](repeating: 0, count: 25)
        scratch = [UInt64](repeating: 0, count: 25)
        column = [UInt64](repeating: 0, count: 5)
        temp = [UInt64](repeating: 0, count: 5)
        buffer = [UInt8](repeating: 0, count: SHA3Digest.rate)
        bufferCount = 0
    }

    /// 复位成初始状态（PoW 循环里反复用同一个实例）
    mutating func reset() {
        for index in 0..<state.count { state[index] = 0 }
        bufferCount = 0
    }

    mutating func update(_ bytes: [UInt8]) {
        for byte in bytes {
            buffer[bufferCount] = byte
            bufferCount += 1
            if bufferCount == SHA3Digest.rate {
                absorbBlock()
                bufferCount = 0
            }
        }
    }

    mutating func update(_ text: String) {
        update(Array(text.utf8))
    }

    /// 收尾（会填充并置换，调用后需要 reset 才能再用）
    mutating func finalize() -> [UInt8] {
        // pad10*1，域分隔符 0x06
        buffer[bufferCount] = 0x06
        if bufferCount + 1 < SHA3Digest.rate {
            for index in (bufferCount + 1)..<(SHA3Digest.rate - 1) { buffer[index] = 0 }
        }
        buffer[SHA3Digest.rate - 1] |= 0x80
        absorbBlock()

        var output = [UInt8](repeating: 0, count: SHA3Digest.digestLength)
        for lane in 0..<(SHA3Digest.digestLength / 8) {
            let value = state[lane]
            for byte in 0..<8 {
                output[lane * 8 + byte] = UInt8((value >> UInt64(8 * byte)) & 0xFF)
            }
        }
        return output
    }

    /// 一次性算 SHA3-256
    static func hash(_ text: String) -> [UInt8] {
        var digest = SHA3Digest()
        digest.update(text)
        return digest.finalize()
    }

    static func hexHash(_ text: String) -> String {
        hash(text).map { String(format: "%02x", $0) }.joined()
    }

    /// hex 字符串 → 字节（PoW 比较用，避免每次迭代都拼字符串）
    static func hexBytes(_ hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = nibble(chars[index]), let low = nibble(chars[index + 1]) else { return nil }
            bytes.append((high << 4) | low)
            index += 2
        }
        return bytes
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case 0x30...0x39: return character - 0x30
        case 0x61...0x66: return character - 0x61 + 10
        case 0x41...0x46: return character - 0x41 + 10
        default: return nil
        }
    }

    // MARK: - 内部

    private mutating func absorbBlock() {
        for lane in 0..<17 {
            var value: UInt64 = 0
            for byte in 0..<8 {
                value |= UInt64(buffer[lane * 8 + byte]) << UInt64(8 * byte)
            }
            state[lane] ^= value
        }
        permute()
    }

    private static let rotationOffsets: [[UInt64]] = [
        [0, 36, 3, 41, 18],
        [1, 44, 10, 45, 2],
        [62, 6, 43, 15, 61],
        [28, 55, 25, 21, 56],
        [27, 20, 39, 8, 14]
    ]

    private static let roundConstants: [UInt64] = [
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808B, 0x0000_0000_8000_0001, 0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
        0x0000_0000_0000_008A, 0x0000_0000_0000_0088, 0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
        0x0000_0000_8000_808B, 0x8000_0000_0000_008B, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080, 0x0000_0000_0000_800A, 0x8000_0000_8000_000A,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8080, 0x0000_0000_8000_0001, 0x8000_0000_8000_8008
    ]

    @inline(__always)
    private static func rotateLeft(_ value: UInt64, _ amount: UInt64) -> UInt64 {
        if amount == 0 { return value }
        return (value << amount) | (value >> (64 - amount))
    }

    private mutating func permute() {
        for round in 0..<24 {
            // θ
            for x in 0..<5 {
                column[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            }
            for x in 0..<5 {
                temp[x] = column[(x + 4) % 5] ^ SHA3Digest.rotateLeft(column[(x + 1) % 5], 1)
            }
            for y in 0..<5 {
                for x in 0..<5 {
                    state[x + 5 * y] ^= temp[x]
                }
            }

            // ρ + π
            for x in 0..<5 {
                for y in 0..<5 {
                    let target = y + 5 * ((2 * x + 3 * y) % 5)
                    scratch[target] = SHA3Digest.rotateLeft(state[x + 5 * y], SHA3Digest.rotationOffsets[x][y])
                }
            }

            // χ
            for y in 0..<5 {
                for x in 0..<5 {
                    state[x + 5 * y] = scratch[x + 5 * y]
                        ^ (~scratch[(x + 1) % 5 + 5 * y] & scratch[(x + 2) % 5 + 5 * y])
                }
            }

            // ι
            state[0] ^= SHA3Digest.roundConstants[round]
        }
    }
}
