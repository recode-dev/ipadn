#include <stddef.h>

// Raw arm64 invocation of XNU syscall 489 (mremap_encrypted) for iOS builds
// where the libc symbol is not linked: addr, length, cryptid (1 = app
// encryption, 2 = model encryption), cputype, cpusubtype.
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
