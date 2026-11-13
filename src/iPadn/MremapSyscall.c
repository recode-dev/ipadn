#include <stddef.h>
#include <fcntl.h>

#ifndef F_ADDFILESIGS_RETURN
#define F_ADDFILESIGS_RETURN 97
#endif

struct ipadn_fsignatures {
    long long fs_file_start;
    void *fs_blob_start;
    unsigned long long fs_blob_size;
};

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

int ipadn_addfilesigs(int fd, long long file_start, long long blob_offset, unsigned long long blob_size) {
    struct ipadn_fsignatures sig;
    sig.fs_file_start = file_start;
    sig.fs_blob_start = (void *)blob_offset;
    sig.fs_blob_size = blob_size;
    return fcntl(fd, F_ADDFILESIGS_RETURN, &sig);
}
