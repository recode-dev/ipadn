#include <stddef.h>
#include <stdint.h>
#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <dlfcn.h>
#include <pthread.h>
#include <string.h>
#include <mach/mach.h>

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

static __thread sigjmp_buf ipadn_guard_env;
static __thread volatile sig_atomic_t ipadn_guard_armed = 0;
static pthread_mutex_t ipadn_guard_install_mutex = PTHREAD_MUTEX_INITIALIZER;
static volatile int ipadn_guard_installed = 0;
static struct sigaction ipadn_guard_prev_segv;
static struct sigaction ipadn_guard_prev_bus;

static void *ipadn_symbol(const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

static int ipadn_readable(const void *address, unsigned long length) {
    if (!address) return 0;
    vm_size_t out_size = 0;
    unsigned long scratch = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         (vm_address_t)(uintptr_t)address,
                                         (vm_size_t)length,
                                         (vm_address_t)(uintptr_t)&scratch,
                                         &out_size);
    return kr == KERN_SUCCESS;
}

static int ipadn_valid_receiver(const void *value) {
    if (!value) return 0;
    uintptr_t bits = (uintptr_t)value;
    if (bits >> 62 != 0) return 1;
    return ipadn_readable(value, sizeof(void *));
}

static void ipadn_guard_dispatch(int sig, siginfo_t *info, void *uap) {
    if (ipadn_guard_armed) {
        ipadn_guard_armed = 0;
        siglongjmp(ipadn_guard_env, 1);
        return;
    }
    struct sigaction *prev = (sig == SIGBUS) ? &ipadn_guard_prev_bus : &ipadn_guard_prev_segv;
    if (prev->sa_handler == SIG_DFL || prev->sa_handler == SIG_IGN) {
        struct sigaction reset;
        memset(&reset, 0, sizeof(reset));
        sigemptyset(&reset.sa_mask);
        reset.sa_handler = SIG_DFL;
        sigaction(sig, &reset, NULL);
        raise(sig);
        return;
    }
    if (prev->sa_flags & SA_SIGINFO) {
        prev->sa_sigaction(sig, info, uap);
    } else {
        prev->sa_handler(sig);
    }
}

static void ipadn_guard_install(void) {
    pthread_mutex_lock(&ipadn_guard_install_mutex);
    if (!ipadn_guard_installed) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sigemptyset(&sa.sa_mask);
        sa.sa_sigaction = ipadn_guard_dispatch;
        sa.sa_flags = SA_SIGINFO | SA_RESTART;
        sigaction(SIGSEGV, &sa, &ipadn_guard_prev_segv);
        sigaction(SIGBUS, &sa, &ipadn_guard_prev_bus);
        ipadn_guard_installed = 1;
    }
    pthread_mutex_unlock(&ipadn_guard_install_mutex);
}

void *ipadn_ls_class(const char *class_name) {
    if (!class_name) return NULL;
    ipadn_guard_install();
    void *(*get_class)(const char *) = (void *(*)(const char *))ipadn_symbol("objc_getClass");
    if (!get_class) return NULL;
    void *cls = get_class(class_name);
    if (!cls) {
        void *handle = dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
        if (handle) cls = get_class(class_name);
    }
    if (!cls || !ipadn_readable(cls, sizeof(unsigned long))) return NULL;
    unsigned long isa = 0;
    vm_size_t out_size = 0;
    if (vm_read_overwrite(mach_task_self(), (vm_address_t)(uintptr_t)cls, sizeof(unsigned long),
                          (vm_address_t)(uintptr_t)&isa, &out_size) != KERN_SUCCESS) return NULL;
    if ((isa & 0x0007fffffffffff8UL) < 0x1000UL) return NULL;
    return cls;
}

static void *(*ipadn_guard_send)(void *, void *) = NULL;
static void *(*ipadn_guard_send3)(void *, void *, void *) = NULL;
static void *(*ipadn_guard_send5)(void *, void *, void *, long, void **) = NULL;
static void *(*ipadn_guard_selreg)(const char *) = NULL;
static void *(*ipadn_guard_retainar)(void *) = NULL;
static volatile int ipadn_guard_symbols_resolved = 0;

static void ipadn_guard_resolve_symbols(void) {
    if (ipadn_guard_symbols_resolved) return;
    pthread_mutex_lock(&ipadn_guard_install_mutex);
    if (!ipadn_guard_symbols_resolved) {
        ipadn_guard_send = (void *(*)(void *, void *))ipadn_symbol("objc_msgSend");
        ipadn_guard_send3 = (void *(*)(void *, void *, void *))ipadn_symbol("objc_msgSend");
        ipadn_guard_send5 = (void *(*)(void *, void *, void *, long, void **))ipadn_symbol("objc_msgSend");
        ipadn_guard_selreg = (void *(*)(const char *))ipadn_symbol("sel_registerName");
        ipadn_guard_retainar = (void *(*)(void *))ipadn_symbol("objc_retainAutoreleasedReturnValue");
        ipadn_guard_symbols_resolved = 1;
    }
    pthread_mutex_unlock(&ipadn_guard_install_mutex);
}

void *ipadn_ls_send_plain(void *receiver, const char *selector_name) {
    if (!receiver || !selector_name || !ipadn_valid_receiver(receiver)) return NULL;
    ipadn_guard_install();
    ipadn_guard_resolve_symbols();
    if (!ipadn_guard_send || !ipadn_guard_selreg) return NULL;
    void *selector = ipadn_guard_selreg(selector_name);
    if (!selector) return NULL;
    if (sigsetjmp(ipadn_guard_env, 1) != 0) return NULL;
    ipadn_guard_armed = 1;
    void *result = ipadn_guard_send(receiver, selector);
    ipadn_guard_armed = 0;
    return result;
}

void *ipadn_ls_send_plain_retained(void *receiver, const char *selector_name) {
    if (!receiver || !selector_name || !ipadn_valid_receiver(receiver)) return NULL;
    ipadn_guard_install();
    ipadn_guard_resolve_symbols();
    if (!ipadn_guard_send || !ipadn_guard_selreg || !ipadn_guard_retainar) return NULL;
    void *selector = ipadn_guard_selreg(selector_name);
    if (!selector) return NULL;
    if (sigsetjmp(ipadn_guard_env, 1) != 0) return NULL;
    ipadn_guard_armed = 1;
    void *result = ipadn_guard_send(receiver, selector);
    if (!result) {
        ipadn_guard_armed = 0;
        return NULL;
    }
    void *retained = ipadn_guard_retainar(result);
    ipadn_guard_armed = 0;
    return retained;
}

void *ipadn_ls_send_id_retained(void *receiver, const char *selector_name, void *argument) {
    if (!receiver || !selector_name || !ipadn_valid_receiver(receiver)) return NULL;
    ipadn_guard_install();
    ipadn_guard_resolve_symbols();
    if (!ipadn_guard_send3 || !ipadn_guard_selreg || !ipadn_guard_retainar) return NULL;
    void *selector = ipadn_guard_selreg(selector_name);
    if (!selector) return NULL;
    if (sigsetjmp(ipadn_guard_env, 1) != 0) return NULL;
    ipadn_guard_armed = 1;
    void *result = ipadn_guard_send3(receiver, selector, argument);
    if (!result) {
        ipadn_guard_armed = 0;
        return NULL;
    }
    void *retained = ipadn_guard_retainar(result);
    ipadn_guard_armed = 0;
    return retained;
}

void *ipadn_ls_send_record_init(void *receiver, const char *selector_name, void *argument, int flag, void **error) {
    if (!receiver || !selector_name || !ipadn_valid_receiver(receiver)) return NULL;
    ipadn_guard_install();
    ipadn_guard_resolve_symbols();
    if (!ipadn_guard_send5 || !ipadn_guard_selreg) return NULL;
    void *selector = ipadn_guard_selreg(selector_name);
    if (!selector) return NULL;
    if (sigsetjmp(ipadn_guard_env, 1) != 0) return NULL;
    ipadn_guard_armed = 1;
    void *result = ipadn_guard_send5(receiver, selector, argument, (long)flag, error);
    ipadn_guard_armed = 0;
    return result;
}

int ipadn_ls_is_array(void *value) {
    if (!value || !ipadn_valid_receiver(value)) return 0;
    ipadn_guard_install();
    const char *(*class_name)(void *) = (const char *(*)(void *))ipadn_symbol("object_getClassName");
    if (!class_name) return 0;
    if (sigsetjmp(ipadn_guard_env, 1) != 0) return 0;
    ipadn_guard_armed = 1;
    const char *name = class_name(value);
    ipadn_guard_armed = 0;
    return name && strstr(name, "Array") != NULL;
}

void *ipadn_ls_retain(void *value) {
    if (!value) return NULL;
    void *(*retain)(void *) = (void *(*)(void *))ipadn_symbol("objc_retain");
    if (!retain) return NULL;
    return retain(value);
}

void ipadn_ls_release(void *value) {
    if (!value) return;
    void (*release)(void *) = (void (*)(void *))ipadn_symbol("objc_release");
    if (!release) return;
    release(value);
}
