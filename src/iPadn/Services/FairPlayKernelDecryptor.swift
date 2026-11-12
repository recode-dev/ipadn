import Foundation
import Darwin
import MachO

enum FairPlayKernelDecryptor {

    enum KernelError: LocalizedError {
        case open(Int32)
        case mmap(Int32)
        case mremap(Int32)
        case pageRead(kr: Int32, page: Int)
        case write(Int32)
        case truncated(String)
        case entropy

        var errorDescription: String? {
            switch self {
            case .open(let code): return AppText.text("Could not open the staged binary (errno \(code))")
            case .mmap(let code): return AppText.text("Could not map the binary for the kernel decryptor (errno \(code))")
            case .mremap(let code): return AppText.text("The kernel refused FairPlay decryption (code \(code)). Sign the Apple ID that owns this app in to the App Store on this iPhone once (Settings, then Media & Purchases), then retry. iOS 17.4 or newer is required.")
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
    }

    private static let mremapSyscallNumber: Int32 = 489
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
        var lastError: Error?
        for plan in plans {
            do {
                let stagedBinary = try stage(plan.binary, archive: archive, root: staging)
                if let sinf = plan.sinf, let sinfPath = plan.sinfPath {
                    try stageData(sinf, path: sinfPath, root: staging)
                }
                if let license = plan.license, let licensePath = plan.licensePath {
                    try stageData(license, path: licensePath, root: staging)
                }
                let decryptedFile = decryptedRoot.appendingPathComponent(plan.binary.path)
                try FileManager.default.createDirectory(at: decryptedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                let pages = try decryptBinaryFile(at: stagedBinary, destination: decryptedFile)
                handled.insert(plan.binary.path)
                reports.append(FairPlayDecryptor.BinaryReport(path: plan.binary.path, pages: pages))
            } catch FairPlayDecryptor.DecryptError.notEncrypted {
                continue
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

        let magic = try read(4, 0)
        var candidates: [(offset: UInt64, size: UInt64)] = []
        if magic[0] == 0xCA, magic[1] == 0xFE, magic[2] == 0xBA, magic[3] == 0xBE {
            let count = Int(be32(try read(4, 4), 0))
            guard count > 0, count <= 16, 8 + count * 20 <= Int(total) else { throw KernelError.truncated("invalid FAT32 architecture table") }
            for i in 0..<count {
                let entry = try read(20, UInt64(8 + i * 20))
                candidates.append((UInt64(be32(entry, 8)), UInt64(be32(entry, 12))))
            }
        } else if magic[0] == 0xCA, magic[1] == 0xFE, magic[2] == 0xBA, magic[3] == 0xBF {
            let count = Int(be32(try read(4, 4), 0))
            guard count > 0, count <= 16, 8 + count * 32 <= Int(total) else { throw KernelError.truncated("invalid FAT64 architecture table") }
            for i in 0..<count {
                let entry = try read(32, UInt64(8 + i * 32))
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
            let header = try read(32, candidate.offset)
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
            let commands = try read(sizeofcmds, candidate.offset + UInt64(headerSize))
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
                    out.append(SliceInfo(fileOffset: candidate.offset, size: candidate.size, cpuType: cpuType, cpuSubtype: cpuSubtype,
                                         is64: is64, cryptOff: cryptOff, cryptSize: cryptSize, cryptid: cryptid,
                                         cryptidFileOffset: Int(candidate.offset) + headerSize + pos + 16))
                }
                pos += cmdSize
            }
        }
        return out
    }

    private static func decryptSlice(fd: Int32, slice: SliceInfo, outFd: Int32) throws -> Int {
        let pagesize = Int(sysconf(Int32(_SC_PAGESIZE)))
        let mapLen = ((slice.cryptOff + slice.cryptSize + pagesize - 1) / pagesize) * pagesize
        var mmapError: Int32 = 0
        var mremapError: Int32 = 0
        var pageFailure: KernelError?
        for variant in 0..<2 {
            let mmapProt: Int32 = variant == 0 ? PROT_READ : (PROT_READ | PROT_EXEC)
            let callProt: Int32 = variant == 0 ? 2 : 3
            let mapping = mmap(nil, mapLen, mmapProt, MAP_PRIVATE, fd, off_t(slice.fileOffset))
            guard let base = mapping, base != UnsafeMutableRawPointer(bitPattern: UInt.max) else {
                mmapError = errno
                continue
            }
            defer { munmap(base, mapLen) }
            let target = base.advanced(by: slice.cryptOff)
            let kr = callMremapEncrypt(target, slice.cryptSize, callProt, slice.cpuType, slice.cpuSubtype)
            guard kr == 0 else {
                mremapError = kr == -1 ? errno : kr
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
                                      vm_address_t(UInt(bitPattern: target) &+ UInt64(offset)),
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
                if FairPlayDecryptor.entropy(check) < 7.6 { return pagesOK }
            }
        }
        if let pageFailure { throw pageFailure }
        if mremapError != 0 { throw KernelError.mremap(mremapError) }
        if mmapError != 0 { throw KernelError.mmap(mmapError) }
        throw KernelError.entropy
    }

    private static func callMremapEncrypt(_ addr: UnsafeMutableRawPointer, _ length: Int, _ prot: Int32,
                                          _ cpuType: UInt32, _ cpuSubtype: UInt32) -> Int32 {
        if let fn = symbol {
            typealias Signature = @convention(c) (UnsafeMutableRawPointer?, Int, Int32, UInt32, UInt32) -> Int32
            return unsafeBitCast(fn, to: Signature.self)(addr, length, prot, cpuType, cpuSubtype)
        }
        return syscall(mremapSyscallNumber, Int(bitPattern: UInt(bitPattern: addr)), length,
                       Int(prot), Int(cpuType), Int(cpuSubtype))
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
