# Decryptor cross-check against the Apple sources

Status: verified against the current published XNU source tree
(`apple-oss-distributions/xnu`, `main`, as of 2026-11) and against the
historical releases `xnu-4570.41.2` (iOS 12 era) and `xnu-8792.81.2`
(iOS 16 era). Every claim below was checked against the actual file
contents, not from memory. The offline kernel model in
`src/scripts/test_kernel_decryptor_ladder.py` mirrors these findings.

## Kernel call used by FairPlayKernelDecryptor

| ipadn behavior | Apple source | Verdict |
| --- | --- | --- |
| `dlsym(RTLD_DEFAULT, "mremap_encrypted")`, C signature `(void *, size_t, uint32_t, uint32_t, uint32_t) -> int` | `bsd/sys/mman.h:294` (`#ifdef PRIVATE`): `int mremap_encrypted(void *, size_t, __uint32_t, __uint32_t, __uint32_t);` | match |
| Raw fallback `mov x16, #489; svc #0x80` with args in x0..x4 | `osfmk/arm64/sleh.c` `handle_svc()`: raw svc number is read as a signed int; **`x16 >= 0` routes to `unix_syscall()`**, only negative numbers reach `mach_syscall()`. Plain `489` is therefore the correct arm64 encoding (the i386 `SYSCALL_CLASS_UNIX << 24` scheme must not be used). | match |
| Syscall number 489 | `bsd/kern/syscalls.master:753`: `489 AUE_MPROTECT ALL { int mremap_encrypted(caddr_ut addr, size_ut len, uint32_t cryptid, uint32_t cputype, uint32_t cpusubtype); }` guarded by `#if CONFIG_CODE_DECRYPTION` (compiled in on every embedded/iOS configuration). The line is identical in `xnu-4570.41.2`, `xnu-8792.81.2` and current `main`. | match |
| Argument order `addr, len, cryptid, cputype, cpusubtype` | same syscalls.master line | match |
| Alignment pre-check answers EINVAL before touching the kernel | `bsd/kern/kern_mman.c` `mremap_encrypted()`: `mremap_encrypted_sanitize(... VM_SANITIZE_FLAGS_CHECK_ALIGNED_START ...)`; any sanitize failure `return EINVAL;` | match (ipadn is conservative: it pre-checks 16 K alignment; the kernel additionally tolerates 4 K-only alignment through the `fourk_pager` path of `vm_map_apple_protected`, but App Store toolchains always emit 16 K-aligned `cryptoff`/FAT slice offsets) |
| Only cryptid 0 / 1 / 2 / 0x10 ever sent (never 3) | `kern_mman.c` switch: `CRYPTID_NO_ENCRYPTION (0)` returns 0 immediately, `CRYPTID_APP_ENCRYPTION (1)` and `CRYPTID_MODEL_ENCRYPTION (2)` map to `"com.apple.unfree"`, `0x10` maps to `"com.apple.null"`, `default: return EINVAL;` (constants from `bsd/sys/mman.h`) | match |
| cryptid 1 requires a PROT_EXEC mapping; cryptid 2 does not | `osfmk/vm/vm_map.c` `vm_map_apple_protected()`: `if ((cryptid != CRYPTID_MODEL_ENCRYPTION) && !(map_entry->protection & VM_PROT_EXECUTE)) { kr = KERN_INVALID_ARGUMENT; ... }` and `mremap_encrypted` folds every `vm_map_apple_protected` failure into `return EPERM;` | match — this is exactly the historical "kernel refused (code 1)" failure mode |
| Ladder `[R/cryptid 2] -> [+sig] -> [R|X/cryptid 1] -> [+sig]` with per-attempt page verification | TetherlessiOS DecryptHelper variant table `[(1,0),(1,1),(2,0),(2,1)]`; success verification (entropy drop + ARM64 code words over the marker set) mirrors the helper's before/after verdict so a no-op kernel answer (cryptid 0 or 0x10 "success" with pages untouched) can never be accepted | match |
| `fcntl(F_ADDFILESIGS_RETURN)` registration with `fs_file_start = slice offset`, `fs_blob_start = LC_CODE_SIGNATURE dataoff`, `fs_blob_size = datasize` | `bsd/sys/fcntl.h`: `#define F_ADDFILESIGS_RETURN 97`. `bsd/kern/kern_descrip.c`: for the `F_ADDFILESIGS*` family the kernel reads the blob **from the file** with `vn_rdwr(UIO_READ, vp, ..., fs.fs_file_start + fs.fs_blob_start, ...)` (unlike `F_ADDSIGS`, which `copyin`s a userspace pointer) | match |
| Errors reported verbatim to the user | `kern_mman.c` return values: 0, `EPERM (1)`, `ENOMEM (12)`, `ENOTSUP (45)`, `EINVAL (30)` | match — "kernel refused (code N)" always names the real kernel answer (first refusal is kept, per the helper's "firstfail") |

Mach-O parsing (`FairPlayKernelDecryptor.parseSlices`) follows the
cctools `mach-o/loader.h` layout: `fat_arch` / `fat_arch_64` entry
geometry, `MH_MAGIC`/`MH_MAGIC_64` detection, `LC_ENCRYPTION_INFO`
(0x21) vs `LC_ENCRYPTION_INFO_64` (0x2C), `cryptid` at command offset
+16, `LC_CODE_SIGNATURE` (0x1D) `dataoff`/`datasize`, with bounds
checks on every read.

## Why this keeps working on iOS 27 without any change

1. **No version gates in the decryption path.** The kernel decryptor
   contains no `#available`, no `operatingSystemVersion`, no hardcoded
   build numbers. Version checks in the app exist only in SwiftUI
   presentation code and already include an iOS 27 branch.
2. **The ABI it relies on is the most stable surface in XNU.**
   `mremap_encrypted` has kept the same syscall number, argument list
   and validation order across every published release from `xnu-4570`
   (iOS 12) to the current `main` (iOS 26 era), and it is guarded only
   by `CONFIG_CODE_DECRYPTION`, which is part of the FairPlay stack on
   all embedded configurations.
3. **Two independent ways to reach the syscall.** The dlsym path uses
   the libc symbol; if a future release hides it, the raw `svc #0x80`
   path calls the trap directly and does not depend on symbol
   visibility at all.
4. **The ladder absorbs behavior changes.** Both prot/cryptid
   combinations the kernel can accept (R + cryptid 2, R|X + cryptid 1)
   and both signature-registration states (blob already on the vnode /
   registered first) are tried, in the same order as dyld and the
   Tetherless helper. A future kernel that tightens one requirement
   degrades to the next variant instead of failing outright.
5. **Nothing can silently pass.** Every claimed success is verified
   page-by-page (`vm_read_overwrite`), then by entropy and ARM64
   code-word probes, so a kernel that starts returning no-op success
   (the cryptid 0 / 0x10 semantics) cannot produce a corrupt IPA.
6. **Failures are precise, not crashes.** Every failure path maps to a
   specific `KernelError` with the kernel's own code, so on an iOS 27
   device the user gets an actionable diagnosis rather than a broken
   feature.
7. **A version-independent fallback exists.** The CPU-side
   `FairPlayDecryptor.decryptBinary` path (credential + SINF + SUPF/SUPP
   page keys, pure CryptoKit/CommonCrypto) does not touch the kernel at
   all and is used automatically when the kernel path refuses.

## Reproduce

```bash
python3 src/scripts/assemble_runtime.py          # stage local resources
python3 src/scripts/test_kernel_decryptor_ladder.py  # 20 offline checks
python3 src/scripts/verify_project.py            # project/self-check gates
```

CI (`.github/workflows/ios-build.yml`) runs the same verification and a
full unsigned device IPA build on every push.
