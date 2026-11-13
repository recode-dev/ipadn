import Foundation
import Darwin
import MachO
import ZIPFoundation

@_silgen_name("ipadn_mremap_encrypted_svc")
private func ipadnRawMremapEncrypted(_ addr: UnsafeMutableRawPointer?, _ length: Int, _ prot: Int32,
                                     _ cpuType: UInt32, _ cpuSubtype: UInt32) -> Int32

@_silgen_name("ipadn_addfilesigs")
private func ipadnAddFileSigs(_ fd: Int32, _ fileStart: Int64, _ blobOffset: Int64, _ blobSize: UInt64) -> Int32

enum FairPlayKernelDecryptor {

    enum KernelError: LocalizedError {
        case open(Int32)
        case mmap(Int32)
        case mremap(Int32)
        case pageRead(kr: Int32, page: Int)
        case write(Int32)
        case truncated(String)
        case entropy
        case missingSinf(String)

        var errorDescription: String? {
            switch self {
            case .open(let code): return AppText.text("Could not open the staged binary (errno \(code))")
            case .mmap(let code): return AppText.text("Could not map the binary for the kernel decryptor (errno \(code))")
            case .mremap(let code): return AppText.text("The kernel refused FairPlay decryption (code \(code)). Sign the Apple ID that owns this app in to the App Store on this iPhone once (Settings, then Media & Purchases), then retry. iOS 17.4 or newer is required.")
            case .missingSinf(let name): return AppText.text("The package has no SC_Info license for \(name) (missing SINF file). Download the app again from the App Store so its decryption license is included, then retry.")
            case .pageRead(let kr, let page): return AppText.text("FairPlay page \(page) could not be read decrypted (code \(kr)). The App Store account signed in on this device may not own this app.")
            case .write(let code): return AppText.text("Writing the decrypted binary failed (errno \(code))")
            case .truncated(let why): return AppText.text("Mach-O structure problem: \(why)")
            case .entropy: return AppText.text("The kernel decryptor produced still-encrypted pages. The App Store account signed in on this device does not own this app.")
            }
        }
    }

    struct SliceInfo {
        let fileOffset: UInt64
        let size: UInt64
        let cpuType: UInt32
        let cpuSubtype: UInt32
        let is64: Bool
        let cryptOff: Int
        let cryptSize: Int
        let cryptid: Int
        let cryptidFileOffset: Int
        let csOff: Int
        let csSize: Int
    }

    private static var symbol: UnsafeMutableRawPointer? = {
        dlsym(UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: -2)), "mremap_encrypted")
    }()

    static func decryptIPA(at url: URL, destination: URL) throws -> FairPlayDecryptor.IpaResult {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolError.message(AppText.text("The output file already exists"))
        }
        let archive = try Archive(url: url, accessMode: .read)
        let plans = try FairPlayDecryptor.archivePlan(archive)
        guard !plans.isEmpty else { throw FairPlayDecryptor.DecryptError.badSinf("no Mach-O binaries in the package") }

        let support = LocalResources.support
        let staging = support.appendingPathComponent("kernel-staging-\(UUID().uuidString)", isDirectory: true)
        let decryptedRoot = support.appendingPathComponent("kernel-decrypted-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: decryptedRoot)
        }
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: decryptedRoot, withIntermediateDirectories: true)

        var reports: [FairPlayDecryptor.BinaryReport] = []
        var handled = Set<String>()
        var staged = Set<String>()
        var lastError: Error?
        for plan in plans {
            do {
                let stagedBinary = try stage(plan.binary, archive: archive, root: staging)
                staged.insert(plan.binary.path)
                if let sinf = plan.sinf, let sinfPath = plan.sinfPath {
                    try stageData(sinf, path: sinfPath, root: staging)
                    staged.insert(sinfPath)
                    // AppStoreSinfInjector parity: the kernel-side FairPlay
                    // stack resolves the license next to the executable as
                    // SC_Info/<CFBundleExecutable>.sinf (Tetherless writes
                    // the downloaded SINF under exactly that name). When the
                    // package ships the license under another name, replicate
                    // it under the expected one so the lookup succeeds.
                    let dir = plan.binary.path.split(separator: "/").dropLast().joined(separator: "/")
                    if let exec = plan.binary.path.split(separator: "/").last, !exec.isEmpty {
                        let expected = (dir.isEmpty ? "" : dir + "/") + "SC_Info/" + exec + ".sinf"
                        if expected != sinfPath, !staged.contains(expected) {
                            try stageData(sinf, path: expected, root: staging)
                            staged.insert(expected)
                        }
                    }
                }
                if let license = plan.license, let licensePath = plan.licensePath {
                    try stageData(license, path: licensePath, root: staging)
                    staged.insert(licensePath)
                }
                let decryptedFile = decryptedRoot.appendingPathComponent(plan.binary.path)
                try FileManager.default.createDirectory(at: decryptedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                let pages = try decryptBinaryFile(at: stagedBinary, destination: decryptedFile)
                handled.insert(plan.binary.path)
                reports.append(FairPlayDecryptor.BinaryReport(path: plan.binary.path, pages: pages))
            } catch FairPlayDecryptor.DecryptError.notEncrypted {
                continue
            } catch FairPlayDecryptor.DecryptError.notMachO {
                continue
            } catch let error as KernelError {
                // A kernel refusal on a package whose SC_Info license never
                // made it into the IPA has exactly one fix: re-download the
                // app so the SINF is included. Report that instead of the
                // generic kernel message.
                if case .mremap = error, plan.sinf == nil {
                    let name = plan.binary.path.split(separator: "/").last.map(String.init) ?? plan.binary.path
                    throw KernelError.missingSinf(name)
                }
                lastError = error
            } catch {
                lastError = error
            }
        }
        guard !reports.isEmpty else {
            if let lastError { throw lastError }
            throw FairPlayDecryptor.DecryptError.notEncrypted
        }
        try? FileManager.default.removeItem(at: destination)
        let output = try Archive(url: destination, accessMode: .create)
        for entry in archive where !handled.contains(entry.path) {
            guard entry.type == .file, !entry.path.hasSuffix("/"), !FairPlayDecryptor.isLicensePath(entry.path) else { continue }
            try copyEntry(entry, archive: archive, output: output)
        }
        for report in reports {
            try output.addEntry(with: report.path, relativeTo: decryptedRoot, compressionMethod: .deflate)
        }
        return FairPlayDecryptor.IpaResult(destination: destination, binaries: reports, stripped: true)
    }

    static func decryptBinaryFile(at source: URL, destination: URL) throws -> Int {
        let fd = open(source.path, O_RDONLY)
        guard fd >= 0 else { throw KernelError.open(errno) }
        defer { close(fd) }
        let slices = try parseSlices(fd: fd)
        let encrypted = slices.filter { $0.cryptid >= 1 && $0.cryptSize > 0 }
        guard !encrypted.isEmpty else { throw FairPlayDecryptor.DecryptError.notEncrypted }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let outFd = open(destination.path, O_RDWR)
        guard outFd >= 0 else { throw KernelError.open(errno) }
        defer { close(outFd) }
        var pagesTotal = 0
        for slice in encrypted {
            pagesTotal += try decryptSlice(fd: fd, slice: slice, outFd: outFd)
            let zeros: [UInt8] = [0, 0, 0, 0]
            let written = zeros.withUnsafeBufferPointer { buffer -> Int in
                pwrite(outFd, UnsafeRawPointer(buffer.baseAddress!), 4, off_t(slice.cryptidFileOffset))
            }
            guard written == 4 else { throw KernelError.write(errno) }
        }
        return pagesTotal
    }

    static func parseSlices(fd: Int32) throws -> [SliceInfo] {
        var stats = stat()
        guard fstat(fd, &stats) == 0 else { throw KernelError.open(errno) }
        let total = UInt64(max(0, stats.st_size))
        func read(_ count: Int, at offset: UInt64) throws -> [UInt8] {
            guard count > 0, offset + UInt64(count) <= total else { throw KernelError.truncated("slice read out of bounds") }
            var buffer = [UInt8](repeating: 0, count: count)
            let got = buffer.withUnsafeMutableBufferPointer { window -> Int in
                pread(fd, window.baseAddress!, count, off_t(offset))
            }
            guard got == count else { throw KernelError.truncated("short slice read") }
            return buffer
        }
        func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
        func be64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<8 { value = value << 8 | UInt64(bytes[offset + i]) }
            return value
        }
        func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }

        let magic = try read(4, at: 0)
        var candidates: [(offset: UInt64, size: UInt64)] = []
        if magic[0] == 0xCA, magic[1] == 0xFE, magic[2] == 0xBA, magic[3] == 0xBE {
            let count = Int(be32(try read(4, at: 4), 0))
            guard count > 0, count <= 16, 8 + count * 20 <= Int(total) else { throw KernelError.truncated("invalid FAT32 architecture table") }
            for i in 0..<count {
                let entry = try read(20, at: UInt64(8 + i * 20))
                candidates.append((UInt64(be32(entry, 8)), UInt64(be32(entry, 12))))
            }
        } else if magic[0] == 0xCA, magic[1] == 0xFE, magic[2] == 0xBA, magic[3] == 0xBF {
            let count = Int(be32(try read(4, at: 4), 0))
            guard count > 0, count <= 16, 8 + count * 32 <= Int(total) else { throw KernelError.truncated("invalid FAT64 architecture table") }
            for i in 0..<count {
                let entry = try read(32, at: UInt64(8 + i * 32))
                candidates.append((be64(entry, 8), be64(entry, 16)))
            }
        } else if (magic[0] == 0xCF || magic[0] == 0xCE), magic[1] == 0xFA, magic[2] == 0xED, magic[3] == 0xFE {
            candidates.append((0, total))
        } else {
            throw FairPlayDecryptor.DecryptError.notMachO
        }

        var out: [SliceInfo] = []
        for candidate in candidates {
            guard candidate.offset + 32 <= total else { continue }
            let header = try read(32, at: candidate.offset)
            let sliceMagic = le32(header, 0)
            let is64 = sliceMagic == 0xFEEDFACF
            guard is64 || sliceMagic == 0xFEEDFACE else { continue }
            let cpuType = le32(header, 4)
            let cpuSubtype = le32(header, 8)
            let ncmds = Int(le32(header, 16))
            let sizeofcmds = Int(le32(header, 20))
            let headerSize = is64 ? 32 : 28
            guard ncmds > 0, ncmds <= 1000, sizeofcmds >= 8, sizeofcmds <= 1 << 24,
                  candidate.offset + UInt64(headerSize) + UInt64(sizeofcmds) <= total else { continue }
            let commands = try read(sizeofcmds, at: candidate.offset + UInt64(headerSize))
            let encCmd: UInt32 = is64 ? 0x2C : 0x21
            var pos = 0
            while pos + 8 <= sizeofcmds {
                let cmd = le32(commands, pos)
                let cmdSize = Int(le32(commands, pos + 4))
                guard cmdSize >= 8, pos + cmdSize <= sizeofcmds else { break }
                if cmd == encCmd, cmdSize >= 20 {
                    let cryptOff = Int(le32(commands, pos + 8))
                    let cryptSize = Int(le32(commands, pos + 12))
                    let cryptid = Int(le32(commands, pos + 16))
                    // LC_CODE_SIGNATURE (0x1D) carries the CMS blob the kernel
                    // must validate before FairPlay decryption is allowed;
                    // dyld registers it via fcntl(F_ADDFILESIGS_RETURN).
                    var csOff = 0
                    var csSize = 0
                    var scan = 0
                    while scan + 8 <= sizeofcmds {
                        let scanCmd = le32(commands, scan)
                        let scanSize = Int(le32(commands, scan + 4))
                        guard scanSize >= 8, scan + scanSize <= sizeofcmds else { break }
                        if scanCmd == 0x1D, scanSize >= 12 {
                            csOff = Int(le32(commands, scan + 8))
                            csSize = Int(le32(commands, scan + 12))
                            break
                        }
                        scan += scanSize
                    }
                    out.append(SliceInfo(fileOffset: candidate.offset, size: candidate.size, cpuType: cpuType, cpuSubtype: cpuSubtype,
                                         is64: is64, cryptOff: cryptOff, cryptSize: cryptSize, cryptid: cryptid,
                                         cryptidFileOffset: Int(candidate.offset) + headerSize + pos + 16,
                                         csOff: csOff, csSize: csSize))
                }
                pos += cmdSize
            }
        }
        return out
    }

    private static func decryptSlice(fd: Int32, slice: SliceInfo, outFd: Int32) throws -> Int {
        let pagesize = Int(sysconf(Int32(_SC_PAGESIZE)))
        // Map the whole file from offset 0 so no slice offset can break
        // mmap's page-alignment requirement, and keep one spare page of
        // head-room the way the TetherlessiOS helper does.
        let span = Int(slice.fileOffset) + slice.cryptOff + slice.cryptSize + pagesize
        let mapLen = ((span + pagesize - 1) / pagesize) * pagesize
        // XNU bsd/kern/kern_mman.c mremap_encrypted() validates the request
        // before touching FairPlay:
        //   1. cryptid must be 0, 1 (app), 2 (model) or 0x10; anything else,
        //      including the 3 the older builds tried, is rejected outright
        //      with EINVAL (30).
        //   2. user_addr must be page aligned (EINVAL when not).
        //   3. the range must be vnode backed (EINVAL when not).
        // osfmk/vm/vm_map.c vm_map_apple_protected() then requires the map
        // entry to carry VM_PROT_EXECUTE for every cryptid except
        // CRYPTID_MODEL_ENCRYPTION (2) and folds any other failure into
        // EPERM (1). A PROT_READ-only mapping with cryptid 1 therefore
        // always answers EPERM - the exact "kernel refused (code 1)" the
        // device reported before this fix.
        // dyld (Loader::mapSegments, dyld-1245) maps __TEXT as PROT_READ |
        // PROT_EXEC and calls mremap_encrypted(loadAddress + cryptoff,
        // cryptsize, 1, cputype, cpusubtype) after registering the
        // LC_CODE_SIGNATURE blob with fcntl(F_ADDFILESIGS_RETURN). The
        // TetherlessiOS DecryptHelper (variant table [(1,0),(1,1),(2,0),
        // (2,1)]) walks the same ladder: variant 1 maps PROT_READ and calls
        // with cryptid 2, which skips the execute requirement while still
        // selecting the com.apple.unfree crypter; variant 2 maps
        // PROT_READ|PROT_EXEC and calls with cryptid 1 like dyld. Each
        // variant runs once with and once without registering the signature
        // blob (fcntl(fd, F_ADDFILESIGS_RETURN) - the kernel reads the blob
        // from the file at fs_file_start + fs_blob_start, both file
        // offsets). We mirror that ladder in the same order and verify the
        // pages actually decrypted before accepting any attempt, so a
        // no-op kernel answer (cryptid 0) can never pass as success.
        struct Attempt {
            let prot: Int32
            let cryptid: Int32
            let registerSignature: Bool
        }
        let attempts: [Attempt] = [
            Attempt(prot: PROT_READ, cryptid: 2, registerSignature: false),
            Attempt(prot: PROT_READ, cryptid: 2, registerSignature: true),
            Attempt(prot: PROT_READ | PROT_EXEC, cryptid: 1, registerSignature: false),
            Attempt(prot: PROT_READ | PROT_EXEC, cryptid: 1, registerSignature: true),
        ]
        // mremap_encrypted requires a page aligned user_addr; the mmap base
        // is page aligned, so the in-file address of the encrypted range
        // must be as well (thin binaries qualify via cryptoff, FAT slices
        // need sliceOffset + cryptoff aligned).
        if (Int(slice.fileOffset) + slice.cryptOff) % pagesize != 0 {
            throw KernelError.mremap(Int32(EINVAL))
        }
        var mremapError: Int32 = 0
        var pageFailure: KernelError?
        for attempt in attempts {
            if attempt.registerSignature, slice.csSize > 0 {
                // dyld parity: attach the CMS blob (fs_file_start = slice
                // offset in a FAT, fs_blob_start = LC_CODE_SIGNATURE dataoff
                // relative to the slice, fs_blob_size = datasize) so FairPlay
                // trusts this vnode. A failure here is not fatal; the plain
                // variants still get their chance, matching the helper.
                _ = ipadnAddFileSigs(fd, Int64(slice.fileOffset), Int64(slice.csOff), UInt64(slice.csSize))
            }
            let mapping = mmap(nil, mapLen, attempt.prot, MAP_PRIVATE, fd, 0)
            guard let base = mapping, base != UnsafeMutableRawPointer(bitPattern: UInt.max) else {
                continue
            }
            defer { munmap(base, mapLen) }
            let target = base.advanced(by: Int(slice.fileOffset) + slice.cryptOff)
            errno = 0
            let kr = callMremapEncrypt(target, slice.cryptSize, attempt.cryptid, slice.cpuType, slice.cpuSubtype)
            guard kr == 0 else {
                // Keep the first refusal (the helper's "firstfail"), so the
                // reported code is the one FairPlay actually answered with.
                let code = kr == -1 ? errno : kr
                if mremapError == 0 { mremapError = code }
                continue
            }
            let pageCount = (slice.cryptSize + FairPlayDecryptor.pageSize - 1) / FairPlayDecryptor.pageSize
            var pagesOK = 0
            var probe = [UInt8]()
            for page in 0..<pageCount {
                let offset = page * FairPlayDecryptor.pageSize
                let length = min(FairPlayDecryptor.pageSize, slice.cryptSize - offset)
                var buffer = [UInt8](repeating: 0, count: length)
                var outLen: vm_size_t = 0
                let readKr = buffer.withUnsafeMutableBufferPointer { window -> kern_return_t in
                    vm_read_overwrite(mach_task_self_,
                                      vm_address_t(UInt(bitPattern: target) &+ UInt(offset)),
                                      vm_size_t(length),
                                      vm_address_t(UInt(bitPattern: window.baseAddress!)),
                                      &outLen)
                }
                guard readKr == KERN_SUCCESS, Int(outLen) == length else {
                    pageFailure = KernelError.pageRead(kr: readKr, page: page)
                    break
                }
                if page < 4 { probe.append(contentsOf: buffer) }
                let written = buffer.withUnsafeBufferPointer { window -> Int in
                    pwrite(outFd, UnsafeRawPointer(window.baseAddress!), length,
                           off_t(slice.fileOffset + UInt64(slice.cryptOff + offset)))
                }
                guard written == length else {
                    pageFailure = KernelError.write(errno)
                    break
                }
                pagesOK += 1
            }
            guard pageFailure == nil else { continue }
            if pagesOK == pageCount {
                let check = Array(probe.prefix(FairPlayDecryptor.pageSize * 4))
                let decEntropy = FairPlayDecryptor.entropy(check)
                // DecryptHelper verdict parity: the pages must stop looking
                // like AES output (entropy drop) and must not be zeros, and
                // the decrypted probe must contain more recognizable ARM64
                // code words than the encrypted original did (the kernel
                // counting common branch/return/nop encodings). A no-op
                // kernel answer keeps the random ciphertext and fails here.
                guard decEntropy < 7.6, decEntropy > 2.0 else { continue }
                let plain = plainProbe(fd: fd, slice: slice)
                if arm64CodeWords(check) > arm64CodeWords(plain) { return pagesOK }
            }
        }
        if let pageFailure { throw pageFailure }
        if mremapError != 0 { throw KernelError.mremap(mremapError) }
        // Every attempt decrypted the pages but they still look encrypted
        // (entropy unchanged): the kernel answered, FairPlay did not apply
        // the key - no valid license for this app on this device.
        throw KernelError.entropy
    }

    // Reads the encrypted bytes of the probe range straight from the file,
    // mirroring the helper's pread buffer used for the before/after verdict.
    private static func plainProbe(fd: Int32, slice: SliceInfo) -> [UInt8] {
        let count = min(FairPlayDecryptor.pageSize * 4, slice.cryptSize)
        var buffer = [UInt8](repeating: 0, count: count)
        let got = buffer.withUnsafeMutableBufferPointer { window -> Int in
            pread(fd, window.baseAddress!, count,
                  off_t(slice.fileOffset + UInt64(slice.cryptOff)))
        }
        if got != count { return [] }
        return buffer
    }

    // Counts words from the DecryptHelper's exact code-word set (RET,
    // PACIASP, 0xD65F0FFF) that real ARM64 text is full of and random
    // ciphertext almost never matches.
    private static func arm64CodeWords(_ bytes: [UInt8]) -> Int {
        let words: [UInt32] = [
            0xD65F03C0, // RET
            0xD503237F, // PACIASP
            0xD65F0FFF, // helper's third marker
        ]
        guard bytes.count >= 4 else { return 0 }
        var count = 0
        var index = 0
        let limit = bytes.count - 3
        while index < limit {
            let word = UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
                | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
            if words.contains(word) { count += 1 }
            index += 4
        }
        return count
    }

    private static func callMremapEncrypt(_ addr: UnsafeMutableRawPointer, _ length: Int, _ cryptid: Int32,
                                          _ cpuType: UInt32, _ cpuSubtype: UInt32) -> Int32 {
        if let fn = symbol {
            typealias Signature = @convention(c) (UnsafeMutableRawPointer?, Int, Int32, UInt32, UInt32) -> Int32
            return unsafeBitCast(fn, to: Signature.self)(addr, length, cryptid, cpuType, cpuSubtype)
        }
        return ipadnRawMremapEncrypted(addr, length, cryptid, cpuType, cpuSubtype)
    }

    private static func stageData(_ data: Data, path: String, root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func stage(_ entry: Entry, archive: Archive, root: URL) throws -> URL {
        let url = root.appendingPathComponent(entry.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try archive.extract(entry, bufferSize: 1 << 20, consumer: { chunk in
            try handle.write(contentsOf: chunk)
        })
        return url
    }

    private static func copyEntry(_ entry: Entry, archive: Archive, output: Archive) throws {
        if entry.uncompressedSize <= 64 << 20 {
            let data = try FairPlayDecryptor.readEntry(entry, archive: archive)
            try FairPlayDecryptor.writeEntry(data, to: output, path: entry.path)
            return
        }
        let scratch = LocalResources.support.appendingPathComponent("kernel-copy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent(entry.path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        _ = try archive.extract(entry, bufferSize: 1 << 20, consumer: { chunk in
            try handle.write(contentsOf: chunk)
        })
        try output.addEntry(with: entry.path, relativeTo: scratch, compressionMethod: .deflate)
    }
}
