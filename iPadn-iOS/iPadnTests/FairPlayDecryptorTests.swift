import XCTest
import CryptoKit
import CommonCrypto
@testable import iPadn

/// Pins the FairPlay page-key derivation to a public known-answer vector and
/// proves the whole binary round trip (encrypt -> decrypt -> byte identical).
final class FairPlayDecryptorTests: XCTestCase {

    // MARK: - Known answer

    /// The page-key fold, cross-checked against the published unfairplay
    /// TestPageKeyKnownAnswer vector (upstream commit 19a53bba9ceb).
    func testPageKeyKnownAnswer() throws {
        // The work key that corresponds to logical key 00..0f.
        var logical = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { logical[i] = UInt8(i) }
        var work = [UInt8](repeating: 0, count: 16)
        for w in 0..<4 {
            let chunk = UInt32(logical[w * 4]) | UInt32(logical[w * 4 + 1]) << 8
                | UInt32(logical[w * 4 + 2]) << 16 | UInt32(logical[w * 4 + 3]) << 24
            let inner = chunk &- (UInt32(13 + w) &* 0xA6B13D89)
            let bytes = withUnsafeBytes(of: inner.bigEndian) { Array($0) }
            for b in 0..<4 { work[w * 4 + b] = bytes[b] }
        }
        let fixedPageAESKey: [UInt8] = [0xf5, 0x88, 0xff, 0xe1, 0x89, 0xf9, 0x89, 0xf8,
                                        0xe1, 0xf8, 0x89, 0xfe, 0x8a, 0xe1, 0xf4, 0xfe]
        let mask = (0..<16).map { work[$0] ^ fixedPageAESKey[$0] }
        XCTAssertEqual(mask.map { String(format: "%02x", $0) }.joined(),
                       "79891eea60ad2e7ea75fe7ff291bc082")
        var wrapped = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { wrapped[i] = UInt8(0xF0 + i) }
        let key = try FairPlayDecryptor.derivePageKey(work: work, wrapped: wrapped, pageByteOffset: 0x0102030405060708)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(),
                       "45f89ea4a3a1e9b97e038bcb27f269c9")
    }

    // MARK: - Synthetic SINF / SUPF round trip

    private func makeSINF(credential: [UInt8]) -> [UInt8] {
        func atom(_ tag: String, _ payload: [UInt8]) -> [UInt8] {
            let size = UInt32(8 + payload.count)
            return [UInt8(size >> 24), UInt8(size >> 16), UInt8(size >> 8), UInt8(size)]
                + Array(tag.utf8) + payload
        }
        let iviv = Array(UInt8(0x10)...UInt8(0x1F))
        let key16 = Array(UInt8(0xF0)...UInt8(0xFF))
        let types = ["veID", "plat", "aver", "tran", "sing", "song", "tool", "medi", "mode", "hi32"]
        var rights: [UInt8] = []
        for (index, type) in types.enumerated() {
            rights += Array(type.utf8)
            let value = UInt32(index + 1)
            rights += [UInt8(value >> 24), UInt8(value >> 16), UInt8(value >> 8), UInt8(value)]
        }
        rights += [0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe]
        let name = Array("testapp".utf8) + [UInt8](repeating: 0, count: 256 - "testapp".utf8.count)
        var cleartext: [UInt8] = Array("itun".utf8) + [0, 0, 0, 12] + Array("vers".utf8) + [0, 0, 0, 1]
        cleartext += atom("key ", key16)
        cleartext += atom("iviv", iviv)
        cleartext += atom("tmpr", Array(UInt8(0x20)...UInt8(0x2F)))
        cleartext += atom("righ", rights)
        cleartext += atom("name", name)
        XCTAssertEqual(cleartext.count, 448)
        let md5Input = Array("testapp".utf8) + iviv
        let iv = Array(Insecure.MD5.hash(data: Data(md5Input)))
        var aesKey = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { aesKey[i] = credential[i] ^ UInt8(ascii: "0") }
        let priv = Self.aesCBCEncryptForTest(key: aesKey, iv: iv, data: cleartext)
        var inner: [UInt8] = atom("user", [0, 0, 0, 1]) + atom("crdt", [0, 0, 0, 0]) + atom("asdt", [0, 0, 0, 0])
        inner += atom("key ", key16) + atom("iviv", iviv) + atom("righ", rights) + atom("name", name)
        inner += atom("priv", priv)
        return atom("sinf", atom("schi", inner))
    }

    private func makeSUPF(pages: Int) -> [UInt8] {
        var records: [UInt8] = []
        for i in 0..<pages {
            records += Array(SHA256.hash(data: Data("seed".utf8) + Data([UInt8(i >> 24), UInt8(i >> 16), UInt8(i >> 8), UInt8(i)]))[0..<16])
            records += Array(SHA256.hash(data: Data("seediv".utf8) + Data([UInt8(i >> 24), UInt8(i >> 16), UInt8(i >> 8), UInt8(i)]))[0..<16])
        }
        let length = UInt32(32 + pages * 32)
        var supf: [UInt8] = [3] + Array("507".utf8) + [0, 0, 0, 0]
        supf += [0, 0, 0, 1]
        supf += [UInt8(length >> 24), UInt8(length >> 16), UInt8(length >> 8), UInt8(length)]
        supf += [UInt8(FairPlayDecryptorTests.cpuARM64 >> 24), UInt8(FairPlayDecryptorTests.cpuARM64 >> 16),
                 UInt8(FairPlayDecryptorTests.cpuARM64 >> 8), UInt8(FairPlayDecryptorTests.cpuARM64)]
        supf += [UInt8](repeating: 0, count: 20)
        supf += [UInt8(pages >> 24), UInt8(pages >> 16), UInt8(pages >> 8), UInt8(pages)]
        supf += records
        return supf
    }

    static let cpuARM64: UInt32 = 0x0100000C

    /// Minimal thin arm64 Mach-O: page 0 header + load commands, encrypted
    /// body pages after that.
    private func makeMachO(pages: Int) -> (data: [UInt8], cryptidOffset: Int) {
        let nsects = 1
        let segCmdSize = 72 + nsects * 80
        var header: [UInt8] = []
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v), UInt8(v >> 8), UInt8(v >> 16), UInt8(v >> 24)] }
        func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(v >> UInt64(8 * $0)) } }
        header += le32(0xFEEDFACF)
        header += le32(0x0100000C) + le32(0) + le32(2) // cputype, subtype, filetype
        header += le32(2) + le32(UInt32(segCmdSize + 24)) + le32(0) + le32(0) // ncmds, sizeofcmds, flags, reserved
        var segment = le32(0x19) + le32(UInt32(segCmdSize))
        segment += Array("__TEXT".utf8) + [UInt8](repeating: 0, count: 10)
        segment += le64(0) + le64(UInt64(pages * 4096)) + le64(0) + le64(UInt64(pages * 4096))
        segment += le32(7) + le32(5) + le32(UInt32(nsects)) + le32(0)
        segment += Array("__text".utf8) + [UInt8](repeating: 0, count: 10)
        segment += Array("__TEXT".utf8) + [UInt8](repeating: 0, count: 10)
        segment += le64(4096) + le64(UInt64((pages - 1) * 4096)) + le32(4096) + le32(2) + le32(0) + le32(0) + le32(0)
        segment += le32(0) + le32(0) + le32(0)
        let encryption = le32(0x2C) + le32(24) + le32(4096) + le32(UInt32((pages - 1) * 4096)) + le32(1)
        let headerPage = header + segment + encryption + [UInt8](repeating: 0, count: max(0, 4096 - header.count - segment.count - encryption.count))
        var body: [UInt8] = []
        for i in 0..<(pages - 1) {
            var page = [UInt8](repeating: 0, count: 4096)
            for j in 0..<512 { page[j] = UInt8((j * 13 + i * 7) & 0xFF) }
            body += page
        }
        return (headerPage + body, header.count + segCmdSize + 16)
    }

    func testBinaryRoundTrip() throws {
        let credential = Array(UInt8(0xA0)...UInt8(0xAF))
        let sinf = makeSINF(credential: credential)
        XCTAssertEqual(FairPlayDecryptor.credentialDecodes(credential: credential, sinf: sinf), true)
        XCTAssertEqual(FairPlayDecryptor.credentialDecodes(credential: Array(UInt8(0xB0)...UInt8(0xBF)), sinf: sinf), false)
        let work = try FairPlayDecryptor.deriveWork16(credential: credential, sinf: sinf)
        XCTAssertEqual(work, Array(UInt8(0xF0)...UInt8(0xFF)))

        let pages = 5
        let supf = makeSUPF(pages: pages)
        let (plain, cryptidOffset) = makeMachO(pages: pages)
        XCTAssertEqual(plain.count, pages * 4096)
        var encrypted = plain
        for i in 0..<(pages - 1) {
            let offset = 4096 + i * 4096
            let wrapped = Array(SHA256.hash(data: Data("seed".utf8) + Data([0, 0, 0, UInt8(i)]))[0..<16])
            let iv = Array(SHA256.hash(data: Data("seediv".utf8) + Data([0, 0, 0, UInt8(i)]))[0..<16])
            let key = try FairPlayDecryptor.derivePageKey(work: work, wrapped: wrapped, pageByteOffset: UInt64(i + 1) << 12)
            let block = try Self.aesCBCEncryptForTest(key: key, iv: iv, data: Array(encrypted[offset..<(offset + 4096)]))
            encrypted.replaceSubrange(offset..<(offset + 4096), with: block)
        }
        var expected = plain
        expected.replaceSubrange(cryptidOffset..<(cryptidOffset + 4), with: [0, 0, 0, 0])

        let (decrypted, decryptedPages) = try FairPlayDecryptor.decryptBinary(encrypted, sinf: sinf,
                                                                              license: supf, credential: credential)
        XCTAssertEqual(decryptedPages, pages - 1)
        XCTAssertEqual(decrypted, expected)
    }

    func testCryptidZeroIsRejectedAsNotEncrypted() throws {
        let (plain, cryptidOffset) = makeMachO(pages: 3)
        var clear = plain
        clear.replaceSubrange(cryptidOffset..<(cryptidOffset + 4), with: [0, 0, 0, 0])
        XCTAssertNil(try FairPlayDecryptor.encryptedSlice(in: clear),
                     "a cryptid=0 slice must not be reported as encrypted")
    }

    func testEntropyDetector() {
        var zeros = [UInt8](repeating: 0, count: 4096)
        for i in 0..<512 { zeros[i] = UInt8(i &* 13 &+ 7) }
        XCTAssertLessThan(FairPlayDecryptor.entropy(zeros), 6.0)
        let random: [UInt8] = (0..<4096).map { _ in UInt8.random(in: 0...255) }
        XCTAssertGreaterThan(FairPlayDecryptor.entropy(random), 7.6)
    }

    // MARK: - Credential parsing

    func testCredentialParsing() throws {
        let hex = "000102030405060708090a0b0c0d0e0f"
        XCTAssertEqual(FairPlayCredentialStore.parse(hex), Data([UInt8](0...15)))
        XCTAssertEqual(FairPlayCredentialStore.parse("00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F"),
                       Data([UInt8](0...15)))
        XCTAssertEqual(FairPlayCredentialStore.parse("AAECAwQFBgcICQoLDA0ODw=="), Data([UInt8](0...15)))
        XCTAssertNil(FairPlayCredentialStore.parse("nope"))
    }

    // MARK: - Test helpers

    /// Encrypts with AES-CBC via CommonCrypto (the engine itself only needs
    /// the decrypt direction; tests build their own fixtures).
    static func aesCBCEncryptForTest(key: [UInt8], iv: [UInt8], data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(),
                             key, key.count, iv, data, data.count, &out, out.count, &moved)
        precondition(status == kCCSuccess)
        return out
    }
}
