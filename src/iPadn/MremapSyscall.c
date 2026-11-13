#include <stddef.h>
#include <fcntl.h>

#ifndef F_ADDFILESIGS_RETURN
#define F_ADDFILESIGS_RETURN 97
#endif

// Mirror of the kernel struct used by dyld's ImageLoaderMachO::loadCodeSignature:
// for the F_ADDFILESIGS family the kernel treats fs_blob_start as an offset
// inside the file (it reads the blob itself with vn_rdwr at
// fs_file_start + fs_blob_start), not as a userspace pointer.
struct ipadn_fsignatures {
    long long fs_file_start;
    void *fs_blob_start;
    unsigned long long fs_blob_size;
};

// Raw arm64 invocation of XNU syscall 489 (mremap_encrypted) for iOS builds
// where the libc symbol is not linked: addr, length, cryptid (1 = app
// encryption, 2 = model encryption), cputype, cpusubtype.
//
// Dispatch rule on arm64 (verified against xnu osfmk/arm64/sleh.c
// handle_svc()): the raw svc number in x16 is read as a signed int; values
// >= 0 are routed to unix_syscall() and index the BSD sysent[] table, and
// only negative values go to mach_syscall(). 489 is the BSD syscall number
// assigned to mremap_encrypted in bsd/kern/syscalls.master under
// #if CONFIG_CODE_DECRYPTION (enabled on every embedded/iOS configuration),
// with the identical line in xnu-4570 (iOS 12), xnu-8792 (iOS 16) and the
// current xnu main - so plain 489 is the correct encoding, and the i386
// class-bit scheme (SYSCALL_CLASS_UNIX << 24 | n) must NOT be used here.
// The argument order matches the public prototype in bsd/sys/mman.h
// (int mremap_encrypted(void *, size_t, uint32_t cryptid, cpu_type_t,
// cpu_subtype_t)) and the kern_return_t/int return value lands in x0.
int ipadn_mremap_encrypted_svc(void *addr, size_t length, int cryptid, unsigned int cpu_type, unsigned int cpu_subtype) {
    register void *x0 __asm__("x0") = addr;
    register size_t x1 __asm__("x1") = length;
    register unsigned long x2 __asm__("x2") = (unsigned long)cryptid;
    register unsigned long x3 __asm__("x3") = (unsigned long)cpu_type;
    register unsigned long x4 __asm__("x4") = (unsigned long)cpu_subtype;
    register unsigned long x16 __asm__("x16") = 489;
    __asm__ volatile("svc #0x80"
                     : "+r"(x0)
                     : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x16)
                     : "memory", "cc");
    return (int)x0;
}

// Register the LC_CODE_SIGNATURE blob of the staged binary with the kernel
// (ubc_cs_blob_add on the vnode). dyld does this for every image it maps
// (ImageLoaderMachO::loadCodeSignature) and the FairPlay text crypter refuses
// the request with EPERM when the vnode has no validated signature blob.
int ipadn_addfilesigs(int fd, long long file_start, long long blob_offset, unsigned long long blob_size) {
    struct ipadn_fsignatures sig;
    sig.fs_file_start = file_start;
    sig.fs_blob_start = (void *)blob_offset;
    sig.fs_blob_size = blob_size;
    return fcntl(fd, F_ADDFILESIGS_RETURN, &sig);
}
