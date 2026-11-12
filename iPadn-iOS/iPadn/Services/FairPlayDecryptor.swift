import Foundation
import CryptoKit
import CommonCrypto
import ZIPFoundation

/// Offline FairPlay (DRM) decryptor for App Store binaries, fully on-device.
///
/// Takes the IPA's SINF license record and SUPF/SUPP page-key table plus the
/// 16-byte per-account FairPlay credential, derives every per-page key locally
/// and rewrites the archive with decrypted, cryptid-cleared binaries. No Mac,
/// no PC and no jailbreak are involved in the decryption itself.
///
/// The algorithm mirrors the published fairplay-decrypt research (core.py /
/// ipadecrypt), including the page-key fold that is pinned by a public
/// known-answer test in the unit tests.
enum FairPlayDecryptor {

    static let pageSize = 4096
    private static let maxBinaryBytes: Int = 1_500_000_000

    // MARK: - Errors

    enum DecryptError: LocalizedError {
        case notMachO
        case notEncrypted
        case badHeader(String)
        case badSinf(String)
        case badLicense(String)
        case credentialMismatch
        case verifyFailed(String)

        var errorDescription: String? {
            switch self {
            case .notMachO: return AppText.text("这不是有效的 Mach-O 二进制")
            case .notEncrypted: return AppText.text("这个二进制没有加密（cryptid=0）")
            case .badHeader(let why): return AppText.text("Mach-O 结构异常：\(why)")
            case .badSinf(let why): return AppText.text("SINF 授权记录无效：\(why)")
            case .badLicense(let why): return AppText.text("授权页表无效：\(why)")
            case .credentialMismatch: return AppText.text("FairPlay 凭据与此应用的账号授权不匹配")
            case .verifyFailed(let why): return AppText.text("解密结果校验失败：\(why)")
            }
        }
    }

    // MARK: - Mach-O parsing

    struct EncryptedSlice {
        let base: Int
        let size: Int
        let cryptOff: Int
        let cryptSize: Int
        let cryptidOffset: Int
        let subtype: UInt32
        var pages: Int { cryptSize / pageSize }
    }

    private static let cpuTypeARM = UInt32(0x0000000C)
    private static let cpuTypeARM64 = UInt32(0x0100000C)
    private static let cpuTypeARM6432 = UInt32(0x0200000C)
    private static let cpuSubtypeARMV7 = UInt32(9)
    private static let cpuSubtypeARM64E = UInt32(2)
    private static let cpuSubtypeMask = UInt32(0x00FFFFFF)

    private struct ARMCandidate {
        let base: Int
        let size: Int
        let cpu: UInt32
        let subtype: UInt32
    }

    /// The slice the output is thinned to, following the same preference the
    /// on-device flow uses: plain arm64, else arm64e, else arm64_32, else armv7.
    static func encryptedSlice(in data: [UInt8]) throws -> EncryptedSlice? {
        var candidates: [ARMCandidate] = []
        if data.count >= 4, data[0] == 0xCA, data[1] == 0xFE, data[2] == 0xBA, data[3] == 0xBE {
            guard data.count >= 8 else { throw DecryptError.badHeader("FAT table missing") }
            let count = Int(be32(data, 4))
            guard count > 0, count <= 16, 8 + count * 20 <= data.count else {
                throw DecryptError.badHeader("invalid FAT32 architecture table")
            }
            for i in 0..<count {
                let off = 8 + i * 20
                candidates.append(ARMCandidate(base: Int(be32(data, off + 8)), size: Int(be32(data, off + 12)),
                                               cpu: be32(data, off), subtype: be32(data, off + 4)))
            }
        } else if data.count >= 4, data[0] == 0xCA, data[1] == 0xFE, data[2] == 0xBA, data[3] == 0xBF {
            guard data.count >= 8 else { throw DecryptError.badHeader("FAT table missing") }
            let count = Int(be32(data, 4))
            guard count > 0, count <= 16, 8 + count * 32 <= data.count else {
                throw DecryptError.badHeader("invalid FAT64 architecture table")
            }
            for i in 0..<count {
                let off = 8 + i * 32
                candidates.append(ARMCandidate(base: Int(be64(data, off + 8)), size: Int(be64(data, off + 16)),
                                               cpu: be32(data, off), subtype: be32(data, off + 4)))
            }
        } else if data.count >= 32, (data[0] == 0xCF || data[0] == 0xCE), data[1] == 0xFA, data[2] == 0xED, data[3] == 0xFE {
            candidates.append(ARMCandidate(base: 0, size: data.count, cpu: le32(data, 4), subtype: le32(data, 8)))
        } else {
            throw DecryptError.notMachO
        }

        let arm64e = candidates.filter { $0.cpu == cpuTypeARM64 && $0.subtype & cpuSubtypeMask == cpuSubtypeARM64E }
        var chosen = candidates.filter { $0.cpu == cpuTypeARM64 && $0.subtype & cpuSubtypeMask != cpuSubtypeARM64E }
        if chosen.isEmpty { chosen = arm64e }
        if chosen.isEmpty { chosen = candidates.filter { $0.cpu == cpuTypeARM6432 } }
        if chosen.isEmpty { chosen = candidates.filter { $0.cpu == cpuTypeARM } }
        // Fat 32-bit apps pair armv7 with armv7s/armv6; armv7 runs everywhere.
        if chosen.count > 1, chosen[0].cpu == cpuTypeARM {
            chosen = chosen.filter { $0.subtype & cpuSubtypeMask == cpuSubtypeARMV7 }
        }
        guard chosen.count == 1 else {
            throw DecryptError.badHeader("expected exactly one ARM slice, found \(chosen.count)")
        }
        return try sliceCryptInfo(data, base: chosen[0].base, size: chosen[0].size,
                                  cpu: chosen[0].cpu, subtype: chosen[0].subtype)
    }

    private static func sliceCryptInfo(_ data: [UInt8], base: Int, size: Int, cpu: UInt32, subtype: UInt32) throws -> EncryptedSlice? {
        let is64 = cpu == cpuTypeARM64
        let headerSize = is64 ? 32 : 28
        let encCmd: UInt32 = is64 ? 0x2C : 0x21
        let wantMagic: UInt32 = is64 ? 0xFEEDFACF : 0xFEEDFACE

        guard base + size <= data.count, base + headerSize <= data.count else {
            throw DecryptError.badHeader("Mach-O slice exceeds file")
        }
        let magic = le32(data, base)
        let sliceCPU = le32(data, base + 4)
        let ncmds = Int(le32(data, base + 16))
        let sizeofcmds = Int(le32(data, base + 20))
        guard magic == wantMagic, sliceCPU == cpu, ncmds > 0, ncmds <= 1000 else {
            throw DecryptError.badHeader("invalid Mach-O slice header")
        }
        let commandsStart = base + headerSize
        let commandsEnd = commandsStart + sizeofcmds
        guard commandsEnd <= base + size else { throw DecryptError.badHeader("load commands exceed slice") }

        var cryptOff = 0, cryptSize = 0, cryptid = 0, cryptidOffset = 0, found = 0
        var pos = commandsStart
        for _ in 0..<ncmds {
            guard pos + 8 <= commandsEnd else { throw DecryptError.badHeader("truncated load command") }
            let cmd = le32(data, pos)
            let cmdSize = Int(le32(data, pos + 4))
            guard cmdSize >= 8, pos + cmdSize <= commandsEnd else { throw DecryptError.badHeader("invalid load command size") }
            if cmd == encCmd {
                guard cmdSize >= 20 else { throw DecryptError.badHeader("short encryption info command") }
                cryptOff = Int(le32(data, pos + 8))
                cryptSize = Int(le32(data, pos + 12))
                cryptid = Int(le32(data, pos + 16))
                cryptidOffset = pos + 16
                found += 1
            }
            pos += cmdSize
        }
        guard pos == commandsEnd else { throw DecryptError.badHeader("load command sizes do not match header") }
        guard found <= 1 else { throw DecryptError.badHeader("found \(found) encryption commands") }
        guard found == 1, cryptid != 0 else { return nil }
        guard cryptid == 1, cryptSize > 0, cryptSize % pageSize == 0 else {
            throw DecryptError.badHeader("unsupported cryptid/cryptsize: \(cryptid), \(cryptSize)")
        }
        guard cryptOff + cryptSize <= size, cryptidOffset < base + cryptOff else {
            throw DecryptError.badHeader("encrypted region out of bounds")
        }
        return EncryptedSlice(base: base, size: size, cryptOff: cryptOff, cryptSize: cryptSize,
                              cryptidOffset: cryptidOffset, subtype: subtype)
    }

    // MARK: - SINF

    private struct Atom {
        let tag: [UInt8]
        let start: Int
        let end: Int
    }

    private static func atomChildren(_ data: [UInt8], _ start: Int, _ end: Int) throws -> [Atom] {
        var out: [Atom] = []
        var offset = start
        while offset < end {
            guard offset + 8 <= end else { throw DecryptError.badSinf("truncated SINF atom") }
            let size = Int(be32(data, offset))
            guard size >= 8, offset + size <= end else { throw DecryptError.badSinf("invalid SINF atom size") }
            out.append(Atom(tag: Array(data[(offset + 4)..<(offset + 8)]), start: offset + 8, end: offset + size))
            offset += size
        }
        return out
    }

    private static func sinfField(_ sinf: [UInt8], _ wanted: String) throws -> [UInt8] {
        let roots = try atomChildren(sinf, 0, sinf.count)
        guard roots.count == 1, roots[0].tag == Array("sinf".utf8) else {
            throw DecryptError.badSinf("missing outer sinf atom")
        }
        let children = try atomChildren(sinf, roots[0].start, roots[0].end)
        let schi = children.filter { $0.tag == Array("schi".utf8) }
        guard schi.count == 1 else { throw DecryptError.badSinf("missing schi container") }
        let fields = try atomChildren(sinf, schi[0].start, schi[0].end)
        let wantedBytes = Array(wanted.utf8)
        let match = fields.filter { $0.tag == wantedBytes }
        guard match.count == 1 else { throw DecryptError.badSinf("missing \(wanted) field") }
        return Array(sinf[match[0].start..<match[0].end])
    }

    /// Unwraps the account credential against a SINF priv record to obtain the
    /// per-app 16-byte work key.
    static func deriveWork16(credential: [UInt8], sinf: [UInt8]) throws -> [UInt8] {
        let nameField = try sinfField(sinf, "name")
        var name = nameField
        if let zero = name.firstIndex(of: 0) { name = Array(name[..<zero]) }
        let iviv = try sinfField(sinf, "iviv")
        var rawPriv = try sinfField(sinf, "priv")
        switch rawPriv.count {
        case 448: break
        case 440:
            guard rawPriv.suffix(8).allSatisfy({ $0 == 0 }) else { throw DecryptError.badSinf("invalid priv-record trailer") }
            rawPriv = Array(rawPriv.prefix(440))
        default:
            throw DecryptError.badSinf("unsupported priv-record length \(rawPriv.count)")
        }
        guard credential.count == 16, iviv.count == 16 else { throw DecryptError.badSinf("invalid credential/iviv length") }

        var md5Input = name
        md5Input.append(contentsOf: iviv)
        let iv = Insecure.MD5.hash(data: Data(md5Input))

        var key = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { key[i] = credential[i] ^ UInt8(ascii: "0") }
        let clear = try aesCBCDecrypt(key: key, iv: Array(iv), data: rawPriv)

        let itun = Array("itun".utf8), keyTag = Array("key ".utf8), ivivTag = Array("iviv".utf8)
        guard clear.count >= 48, Array(clear[0..<4]) == itun, Array(clear[20..<24]) == keyTag,
              Array(clear[44..<48]) == ivivTag else { throw DecryptError.credentialMismatch }
        return Array(clear[24..<40])
    }

    /// Whether this credential unwraps the given SINF (right account + kind).
    static func credentialDecodes(credential: [UInt8], sinf: [UInt8]) -> Bool {
        (try? deriveWork16(credential: credential, sinf: sinf)) != nil
    }

    // MARK: - License page tables (SUPF v3/v5 and SUPP v01/v04)

    /// Offset of the 32-byte key record for a page in a "pclass" SUPP table:
    /// one record per 4 KB page of the whole file, indexed from offset 0.
    private static func suppPageKeyOffset(_ supp: [UInt8], absolutePage: Int) throws -> Int {
        guard supp.count >= 8, supp[0] == 1 || supp[0] == 4 else { throw DecryptError.badLicense("unsupported SUPP version") }
        var pos = 4
        if supp[0] == 1 { pos += 20 }
        guard pos + 4 <= supp.count else { throw DecryptError.badLicense("truncated SUPP header") }
        let count = Int(be32(supp, pos))
        guard count > 0, count <= 1 << 20, pos + 4 + count * 32 <= supp.count else {
            throw DecryptError.badLicense("invalid SUPP page count")
        }
        guard absolutePage >= 0, absolutePage < count else { throw DecryptError.badLicense("SUPP key missing for page \(absolutePage)") }
        return pos + 4 + 32 * absolutePage
    }

    private static func supfRecordOffset(_ supf: [UInt8], requiredPages: Int, cpu: UInt32, subtype: UInt32) throws -> Int {
        guard supf.count >= 12, supf[0] == 3 || supf[0] == 5 else { throw DecryptError.badLicense("unsupported SUPF version") }
        let magic = String(bytes: supf[1..<4], encoding: .ascii) ?? ""
        guard ["319", "322", "502", "507", "510", "611", "612"].contains(magic) else {
            throw DecryptError.badLicense("unsupported SUPF magic: \(magic)")
        }
        let headerSize = supf[0] == 3 ? 32 : 12
        let count = Int(be32(supf, 8))
        guard count > 0, count <= 16 else { throw DecryptError.badLicense("invalid SUPF architecture count") }
        var pos = 12
        for _ in 0..<count {
            guard pos + 4 + headerSize <= supf.count else { throw DecryptError.badLicense("truncated SUPF architecture header") }
            let length = Int(be32(supf, pos))
            let entryCPU = be32(supf, pos + 4)
            let entrySubtype = be32(supf, pos + 8)
            guard length >= headerSize, pos + 4 + length <= supf.count else { throw DecryptError.badLicense("invalid SUPF architecture length") }
            let pages = Int(be32(supf, pos + headerSize))
            if entryCPU == cpu, entrySubtype & cpuSubtypeMask == subtype & cpuSubtypeMask {
                guard pages >= requiredPages, length >= headerSize + pages * 32 else {
                    throw DecryptError.badLicense("SUPF page records incomplete")
                }
                return pos + 4 + headerSize
            }
            pos += length + 4
        }
        throw DecryptError.badLicense("SUPF record missing for this architecture")
    }

    // MARK: - Page-key derivation

    private static func sourceBlocks(wrapped: [UInt8], pageByteOffset: UInt64) -> ([UInt8], [UInt8], [UInt8]) {
        var pageOffset = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { pageOffset[i] = UInt8((pageByteOffset >> UInt64(8 * (7 - i))) & 0xFF) }
        let first = Array(wrapped[8..<16]) + pageOffset
        let second = Array(wrapped[0..<16])
        let third = pageOffset + Array(wrapped[0..<8])
        return (first, second, third)
    }

    static func finish(_ state: [UInt8]) -> [UInt8] {
        let roundSelectors: [[(Int, Int)]] = [[(0, 1), (2, 3), (4, 5), (6, 7)],
                                              [(2, 1), (0, 3), (4, 7), (6, 5)],
                                              [(2, 0), (4, 1), (6, 3), (7, 5)],
                                              [(1, 2), (4, 0), (7, 3), (5, 6)]]
        let roundConstants: [UInt32] = [0x68547C2E, 0x7E05E1DE, 0xD495038B, 0x0AB24ADD]
        let finalSelectors: [[Int]] = [[0, 1, 2, 3], [0, 2, 4, 6], [0, 3, 5, 7], [4, 5, 6, 7]]
        let finalConstants: [UInt32] = [0x5B7198C7, 0xEB5DE22C, 0x0F8AA8FA, 0xF6E1BB3F]

        var initial = [UInt16](repeating: 0, count: 8)
        for i in 0..<8 { initial[i] = UInt16(state[i * 2]) << 8 | UInt16(state[i * 2 + 1]) }
        var src = initial
        for (round, selectors) in roundSelectors.enumerated() {
            var dst = [UInt16](repeating: 0, count: 8)
            for (pair, sel) in selectors.enumerated() {
                let sum = UInt32(src[sel.0]) &+ UInt32(src[sel.1])
                let square = sum &* sum
                let x = square ^ (sum >> 16) ^ roundConstants[pair]
                dst[pair * 2] = UInt16(truncatingIfNeeded: x)
                dst[pair * 2 + 1] = UInt16(truncatingIfNeeded: x >> 16)
            }
            src = dst
        }
        func pack(_ high: Int, _ low: Int) -> UInt32 { UInt32(src[high]) << 16 | UInt32(src[low]) }
        let combined: [UInt32] = [pack(3, 2) &+ pack(1, 0), pack(6, 4) &+ pack(2, 0),
                                  pack(7, 5) &+ pack(3, 0), pack(7, 6) &+ pack(5, 4)]
        var out = [UInt8](repeating: 0, count: 16)
        for (pair, value) in combined.enumerated() {
            let square = UInt64(value) &* UInt64(value)
            let folded = UInt32(truncatingIfNeeded: square) ^ UInt32(truncatingIfNeeded: square >> 32) ^ finalConstants[pair]
            let low = UInt16(truncatingIfNeeded: folded)
            let high = UInt16(truncatingIfNeeded: folded >> 16)
            let a = initial[pair * 2] ^ low
            let b = initial[pair * 2 + 1] ^ high
            out[pair * 4] = UInt8(a >> 8); out[pair * 4 + 1] = UInt8(a & 0xFF)
            out[pair * 4 + 2] = UInt8(b >> 8); out[pair * 4 + 3] = UInt8(b & 0xFF)
        }
        return out
    }

    static func derivePageKey(work: [UInt8], wrapped: [UInt8], pageByteOffset: UInt64) throws -> [UInt8] {
        guard work.count == 16, wrapped.count == 16 else { throw DecryptError.badLicense("invalid page-key input length") }
        let (first, second, third) = sourceBlocks(wrapped: wrapped, pageByteOffset: pageByteOffset)
        let a = try aesECBEncrypt(key: work, block: first)
        let b = try aesECBEncrypt(key: work, block: second)
        let c = try aesECBEncrypt(key: work, block: third)
        func xor16(_ x: [UInt8], _ y: [UInt8]) -> [UInt8] { (0..<16).map { x[$0] ^ y[$0] } }
        let step1 = finish(a)
        let step2 = finish(xor16(step1, b))
        return finish(xor16(step2, c))
    }

    // MARK: - Binary decryption

    /// Decrypts the encrypted arm64 slice of one Mach-O and clears cryptid.
    /// The result is a thin Mach-O (the other fat slices are dropped, matching
    /// what the device actually runs). `license` is SUPF or SUPP content.
    static func decryptBinary(_ source: [UInt8], sinf: [UInt8], license: [UInt8],
                              credential: [UInt8], verify: Bool = true) throws -> ([UInt8], Int) {
        guard let slice = try encryptedSlice(in: source) else { throw DecryptError.notEncrypted }
        let work = try deriveWork16(credential: credential, sinf: sinf)

        let isPclass = !license.isEmpty && (license[0] == 1 || license[0] == 4)
        var recordStart = 0
        if !isPclass {
            recordStart = try supfRecordOffset(license, requiredPages: slice.pages,
                                               cpu: cpuTypeARM64, subtype: slice.subtype)
        }

        let sliceBytes = Array(source[slice.base..<(slice.base + slice.size)])
        var result = sliceBytes
        for localPage in 0..<slice.pages {
            let absolutePage = (slice.base + slice.cryptOff) / pageSize + localPage
            if isPclass {
                recordStart = try suppPageKeyOffset(license, absolutePage: absolutePage)
            }
            guard recordStart + 32 <= license.count else { throw DecryptError.badLicense("truncated page record") }
            let record = Array(license[recordStart..<(recordStart + 32)])
            recordStart += 32
            let key = try derivePageKey(work: work, wrapped: Array(record[0..<16]),
                                        pageByteOffset: UInt64(absolutePage) << 12)
            let start = slice.cryptOff + pageSize * localPage
            let cipher = Array(sliceBytes[start..<(start + pageSize)])
            result.replaceSubrange(start..<start + pageSize,
                                   with: try aesCBCDecrypt(key: key, iv: Array(record[16..<32]), data: cipher))
        }
        let clearCryptid = [0, 0, 0, 0] as [UInt8]
        let cryptidInSlice = slice.cryptidOffset - slice.base
        result.replaceSubrange(cryptidInSlice..<cryptidInSlice + 4, with: clearCryptid)
        if verify { try verifyDecrypted(result, slice: slice) }
        return (result, slice.pages)
    }

    /// Cheap sanity proof the crypt is actually gone: entropy must drop and
    /// cryptid must read back as zero.
    static func verifyDecrypted(_ result: [UInt8], slice: EncryptedSlice) throws {
        let start = slice.cryptOff
        let span = min(pageSize * 4, slice.cryptSize)
        let decEntropy = entropy(Array(result[start..<(start + span)]))
        guard decEntropy < 7.6 else {
            throw DecryptError.verifyFailed("post-decrypt entropy still \(String(format: "%.2f", decEntropy)) - wrong key or license")
        }
        let cryptidStart = slice.cryptidOffset - slice.base
        guard Array(result[cryptidStart..<cryptidStart + 4]) == [0, 0, 0, 0] else {
            throw DecryptError.verifyFailed("cryptid not cleared")
        }
    }

    static func entropy(_ bytes: [UInt8]) -> Double {
        guard !bytes.isEmpty else { return 0 }
        var counts = [Int](repeating: 0, count: 256)
        for b in bytes { counts[Int(b)] += 1 }
        var e = 0.0
        let n = Double(bytes.count)
        for c in counts where c > 0 {
            let p = Double(c) / n
            e -= p * log2(p)
        }
        return e
    }

    // MARK: - IPA-level

    struct BinaryReport {
        let path: String
        let pages: Int
    }

    struct IpaResult {
        let destination: URL
        let binaries: [BinaryReport]
        var pages: Int { binaries.reduce(0) { $0 + $1.pages } }
    }

    /// Whether any licensed binary of an IPA carries an active cryptid.
    static func ipaEncryptionState(at url: URL) throws -> (encrypted: Bool, checked: Int) {
        let archive = try Archive(url: url, accessMode: .read)
        var encrypted = false, checked = 0
        for plan in try archivePlan(archive) {
            let data = try readEntry(plan.binary, archive: archive)
            checked += 1
            if (try encryptedSlice(in: Array(data))) != nil { encrypted = true }
        }
        return (encrypted, checked)
    }

    /// Decrypts every licensed binary inside the IPA and writes the DRM-free
    /// copy to `destination` (which must not exist yet).
    static func decryptIPA(at url: URL, credential: Data, destination: URL) throws -> IpaResult {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolError.message(AppText.text("输出文件已存在"))
        }
        let credentialBytes = Array(credential)
        guard credentialBytes.count == 16 else { throw DecryptError.badLicense("credential must be 16 bytes") }

        let archive = try Archive(url: url, accessMode: .read)
        let plans = try archivePlan(archive)
        guard !plans.isEmpty else { throw DecryptError.badSinf("no usable SC_Info license files in the IPA") }

        var reports: [BinaryReport] = []
        var handled = Set<String>()
        let outputURL = destination
        try? FileManager.default.removeItem(at: outputURL)
        let output = try Archive(url: outputURL, accessMode: .create)

        for plan in plans {
            let binaryData = try readEntry(plan.binary, archive: archive)
            guard (try encryptedSlice(in: Array(binaryData))) != nil else { continue }
            guard let sinf = plan.sinf, let license = plan.license else {
                throw DecryptError.badSinf("\(plan.binary.path) is missing SINF/SUPF license files")
            }
            let (decrypted, pages) = try decryptBinary(Array(binaryData), sinf: Array(sinf), license: Array(license),
                                                       credential: credentialBytes, verify: true)
            try writeEntry(Data(decrypted), to: output, path: plan.binary.path)
            handled.insert(plan.binary.path)
            reports.append(BinaryReport(path: plan.binary.path, pages: pages))
        }

        // Copy everything else through, including sinf/supp so the package
        // stays a complete store-style bundle.
        for entry in archive where !handled.contains(entry.path) {
            guard entry.type == .file else { continue }
            let data = try readEntry(entry, archive: archive, limit: maxBinaryBytes)
            try writeEntry(data, to: output, path: entry.path)
        }
        guard !reports.isEmpty else { throw DecryptError.notEncrypted }
        return IpaResult(destination: destination, binaries: reports)
    }

    // MARK: - Archive plumbing

    struct BinaryPlan {
        let binary: Entry
        let sinf: Data?
        let license: Data?
    }

    /// Matches Payload/<App>.app/<Executable> with its SC_Info license files
    /// by basename stem, like the ipatool-family tools do.
    private static func archivePlan(_ archive: Archive) throws -> [BinaryPlan] {
        var binaries: [Entry] = []
        for entry in archive {
            let parts = entry.path.split(separator: "/")
            if parts.count == 3, parts[0] == "Payload", parts[1].hasSuffix(".app"),
               entry.type == .file, !entry.path.hasSuffix("/") {
                binaries.append(entry)
            }
        }
        var plans: [BinaryPlan] = []
        for binary in binaries {
            let stem = (binary.path.split(separator: "/").last.map { String($0) } ?? "").lowercased()
            guard !stem.isEmpty else { continue }
            let bundlePath = binary.path.split(separator: "/").dropLast().joined(separator: "/")
            let prefix = bundlePath + "/SC_Info/"
            var sinf: Data?
            var license: Data?
            for entry in archive where entry.path.hasPrefix(prefix) && entry.type == .file {
                let name = (entry.path.split(separator: "/").last.map { String($0) } ?? "").lowercased()
                if name == "\(stem).sinf" || name == "\(stem).v4.sinf" {
                    sinf = try readEntry(entry, archive: archive)
                } else if name == "\(stem).supf" || name == "\(stem).v5.supf"
                            || name == "\(stem).supp" || name == "\(stem).v4.supp" {
                    license = try readEntry(entry, archive: archive)
                }
            }
            // Fallback: a bundle with exactly one license pair.
            if sinf == nil || license == nil {
                var fallbackSinf: Data?
                var fallbackLicense: Data?
                for entry in archive where entry.path.hasPrefix(prefix) && entry.type == .file {
                    let name = (entry.path.split(separator: "/").last.map { String($0) } ?? "").lowercased()
                    if name.hasSuffix(".sinf") || name.hasSuffix(".v4.sinf") { fallbackSinf = try readEntry(entry, archive: archive) }
                    if name.hasSuffix(".supf") || name.hasSuffix(".v5.supf") || name.hasSuffix(".supp") || name.hasSuffix(".v4.supp") {
                        fallbackLicense = try readEntry(entry, archive: archive)
                    }
                }
                if sinf == nil { sinf = fallbackSinf }
                if license == nil { license = fallbackLicense }
            }
            plans.append(BinaryPlan(binary: binary, sinf: sinf, license: license))
        }
        return plans
    }

    private static func readEntry(_ entry: Entry, archive: Archive, limit: Int = maxBinaryBytes) throws -> Data {
        guard entry.uncompressedSize <= UInt64(limit) else {
            throw ToolError.message(AppText.text("安装包中的二进制过大，无法在设备上解密"))
        }
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        let checksum = try archive.extract(entry, consumer: { chunk in
            data.append(chunk)
            guard data.count <= limit else { throw DecryptError.badHeader("entry exceeds size limit") }
        })
        guard checksum == entry.checksum else { throw DecryptError.badHeader("archive checksum mismatch") }
        return data
    }

    private static func writeEntry(_ data: Data, to archive: Archive, path: String) throws {
        // Same scratch-dir pattern PackageService uses: the entry's own path
        // decides where the file must sit inside the scratch directory.
        let scratch = LocalResources.support.appendingPathComponent("decrypt-entry-\(UUID().uuidString)", isDirectory: true)
        let file = scratch.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try archive.addEntry(with: path, relativeTo: scratch, compressionMethod: .deflate)
    }

    // MARK: - Crypto primitives

    private static func aesECBEncrypt(key: [UInt8], block: [UInt8]) throws -> [UInt8] {
        guard block.count == 16 else { throw DecryptError.badLicense("ECB input must be 16 bytes") }
        var out = [UInt8](repeating: 0, count: block.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionECBMode), key, key.count, nil,
                             block, block.count, &out, out.count, &moved)
        guard status == kCCSuccess else { throw DecryptError.badLicense("AES failed (status \(status))") }
        return out
    }

    private static func aesCBCDecrypt(key: [UInt8], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        guard data.count % 16 == 0, key.count == 16, iv.count == 16 else {
            throw DecryptError.badLicense("invalid AES-CBC input length")
        }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(), key, key.count, iv,
                             data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess else { throw DecryptError.badLicense("AES failed (status \(status))") }
        return out
    }

    // MARK: - Byte readers

    private static func be32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private static func be64(_ data: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value = value << 8 | UInt64(data[offset + i]) }
        return value
    }

    private static func le32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}
