#import "WorseQueryAccess.h"

#import <dlfcn.h>
#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <sys/fsgetpath.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <xpc/xpc.h>

typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

typedef void *(*wq_query_create_fn)(void);
typedef void (*wq_query_set_u64_fn)(void *, uint64_t);
typedef void (*wq_query_set_ids_fn)(void *, xpc_object_t);
typedef void *(*wq_query_result_fn)(void *);
typedef void (*wq_query_free_fn)(void *);
typedef char *(*wq_query_token_fn)(void *);
typedef int64_t (*wq_consume_fn)(const char *);
typedef int (*wq_release_fn)(int64_t);

static NSRecursiveLock *wq_lock(void) {
    static NSRecursiveLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSRecursiveLock new]; });
    return lock;
}

static NSString *wq_normalize(NSString *path) {
    NSString *p = path.stringByStandardizingPath;
    if ([p hasPrefix:@"/var/"]) p = [@"/private" stringByAppendingString:p];
    return p;
}

static BOOL wq_plain_openable(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd >= 0) {
        close(fd);
        return YES;
    }
    return errno != EPERM;
}

@implementation WorseQueryAccess

+ (NSString *)appGroup {
    static NSString *group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
        if (!task) return;
        CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL);
        CFRelease(task);
        if (!value) return;
        NSArray *groups = (__bridge_transfer NSArray *)value;
        for (NSString *candidate in groups) {
            if (![candidate isKindOfClass:NSString.class]) continue;
            NSURL *root = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:candidate];
            if (root) {
                group = candidate;
                break;
            }
        }
    });
    return group;
}

+ (BOOL)escapeAvailable {
    return self.appGroup != nil;
}

+ (BOOL)systemAreasReachable {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27;
}

#pragma mark token query

static int64_t wq_query_token(NSString *group, NSString *target, BOOL altFlags) {
    static void *manager;
    static wq_query_create_fn create;
    static wq_query_set_u64_fn setClass, setFlags, setPart;
    static wq_query_set_ids_fn setGroups;
    static wq_query_result_fn result;
    static wq_query_free_fn freeQuery;
    static wq_query_token_fn copyToken;
    static wq_consume_fn consume;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        manager = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
        if (!manager) return;
        create = (wq_query_create_fn)dlsym(manager, "container_query_create");
        setClass = (wq_query_set_u64_fn)dlsym(manager, "container_query_set_class");
        setGroups = (wq_query_set_ids_fn)dlsym(manager, "container_query_set_group_identifiers");
        setFlags = (wq_query_set_u64_fn)dlsym(manager, "container_query_operation_set_flags");
        setPart = (wq_query_set_u64_fn)dlsym(manager, "container_query_operation_set_part");
        result = (wq_query_result_fn)dlsym(manager, "container_query_get_single_result");
        freeQuery = (wq_query_free_fn)dlsym(manager, "container_query_free");
        copyToken = (wq_query_token_fn)dlsym(manager, "container_copy_sandbox_token");
        consume = (wq_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    });
    if (!manager || !create || !setClass || !setGroups || !setFlags || !setPart || !result || !freeQuery || !copyToken || !consume) return -2;
    void *query = create();
    if (!query) return -3;
    char *token = NULL;
    int64_t handle = -5;
    setClass(query, 7);
    xpc_object_t identifier = xpc_string_create(group.UTF8String);
    setGroups(query, identifier);
    xpc_release(identifier);
    setPart(query, 3);
    setFlags(query, altFlags ? 0x0000000800000000ULL : 0x0000008000000000ULL);
    void *single = result(query);
    if (single) {
        token = copyToken(single);
        if (token) {
            handle = consume(token);
            free(token);
        } else {
            handle = -6;
        }
    }
    freeQuery(query);
    return handle;
}

static void wq_release_handle(int64_t handle) {
    if (handle < 0) return;
    static wq_release_fn release;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ release = (wq_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release"); });
    if (release) release(handle);
}

static void wq_restore_caches(NSString *group) {
    NSURL *root = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
    if (!root) return;
    NSString *caches = [root.path stringByAppendingPathComponent:@"Library/Caches"];
    NSFileManager *files = NSFileManager.defaultManager;
    [files removeItemAtPath:caches error:nil];
    [files createDirectoryAtPath:caches withIntermediateDirectories:NO attributes:nil error:nil];
}

static int64_t wq_acquire(NSString *target, BOOL altFlags) {
    NSString *group = [WorseQueryAccess appGroup];
    if (!group) return -1;
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = [files containerURLForSecurityApplicationGroupIdentifier:group];
    if (!root) return -1;
    NSString *library = [root.path stringByAppendingPathComponent:@"Library"];
    [files createDirectoryAtPath:library withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *caches = [library stringByAppendingPathComponent:@"Caches"];
    [files removeItemAtPath:caches error:nil];
    if (![files createSymbolicLinkAtPath:caches withDestinationPath:target error:nil]) return -4;
    int64_t handle = wq_query_token(group, target, altFlags);
    wq_restore_caches(group);
    return handle;
}

static NSMutableDictionary<NSString *, NSNumber *> *wq_grants;
static NSMutableArray<NSString *> *wq_order;

static void wq_forget(NSString *key) {
    NSNumber *known = wq_grants[key];
    if (!known) return;
    wq_release_handle(known.longLongValue);
    [wq_grants removeObjectForKey:key];
    [wq_order removeObject:key];
}

+ (BOOL)grant:(NSString *)path {
    NSString *key = wq_normalize(path);
    NSRecursiveLock *lock = wq_lock();
    [lock lock];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        wq_grants = [NSMutableDictionary new];
        wq_order = [NSMutableArray new];
    });
    if (wq_grants[key]) {
        [wq_order removeObject:key];
        [wq_order addObject:key];
        [lock unlock];
        return YES;
    }
    struct stat st;
    if (lstat(key.fileSystemRepresentation, &st) != 0) {
        [lock unlock];
        return NO;
    }
    while (wq_order.count >= 192) {
        NSString *oldest = wq_order.firstObject;
        wq_release_handle(wq_grants[oldest].longLongValue);
        [wq_grants removeObjectForKey:oldest];
        [wq_order removeObjectAtIndex:0];
    }
    [lock unlock];
    BOOL preferAlt = ![self systemAreasReachable];
    int64_t handle = wq_acquire(key, preferAlt);
    if (handle >= 0 && !wq_plain_openable(key)) {
        wq_release_handle(handle);
        handle = -8;
    }
    if (handle < 0 && handle != -1 && handle != -2) {
        int64_t alternate = wq_acquire(key, !preferAlt);
        if (alternate >= 0 && !wq_plain_openable(key)) {
            wq_release_handle(alternate);
            alternate = -8;
        }
        if (alternate >= 0) handle = alternate;
    }
    if (handle < 0) return NO;
    [lock lock];
    if (wq_grants[key]) {
        wq_release_handle(handle);
        [lock unlock];
        return YES;
    }
    wq_grants[key] = @(handle);
    [wq_order addObject:key];
    [lock unlock];
    return YES;
}

+ (NSString *)grantedStageRoot {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        root = [self findStageRoot];
    });
    return root;
}

+ (NSString *)findStageRoot {
    NSMutableArray<NSString *> *candidates = [NSMutableArray new];
    for (NSString *parent in @[@"/private/var/containers/Shared/SystemGroup",
                               @"/private/var/containers/Data/System"]) {
        for (NSString *child in [self list:parent]) {
            [candidates addObject:[parent stringByAppendingPathComponent:child]];
        }
        if (candidates.count > 24) {
            [candidates removeObjectsInRange:NSMakeRange(24, candidates.count - 24)];
        }
    }
    NSString *group = [self appGroup];
    if (group) {
        NSURL *groupRoot = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
        if (groupRoot) [candidates addObject:[groupRoot.path stringByAppendingPathComponent:@"Library/Caches"]];
    }
    for (NSString *candidate in candidates) {
        NSArray<NSString *> *spots = @[[candidate stringByAppendingPathComponent:@"Library/Caches"],
                                       [candidate stringByAppendingPathComponent:@"Caches"],
                                       candidate];
        for (NSString *spot in spots) {
            NSString *probe = [spot stringByAppendingPathComponent:[NSString stringWithFormat:@"ipadn-stage-probe-%@", [NSUUID UUID].UUIDString]];
            if (![self write:probe data:[NSData dataWithBytes:"ok" length:2]]) continue;
            if (![self remove:probe]) continue;
            return spot;
        }
    }
    return nil;
}

#pragma mark listing

+ (NSArray<NSString *> *)list:(NSString *)dir {
    NSString *key = wq_normalize(dir);
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    DIR *handle = opendir(key.fileSystemRepresentation);
    if (!handle) {
        if (errno == EPERM || errno == EACCES) {
            if (![self grant:key]) return names;
            handle = opendir(key.fileSystemRepresentation);
        }
        if (!handle) return names;
    }
    NSFileManager *files = NSFileManager.defaultManager;
    struct dirent *entry;
    while ((entry = readdir(handle)) != NULL) {
        NSString *name = [files stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name || [name isEqualToString:@"."] || [name isEqualToString:@".."]) continue;
        [names addObject:name];
    }
    closedir(handle);
    return [names sortedArrayUsingSelector:@selector(compare:)];
}

+ (NSArray<NSString *> *)enumerate:(NSString *)dir {
    NSString *key = wq_normalize(dir);
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    while ([key hasSuffix:@"/"]) key = [key substringToIndex:key.length - 1];
    struct statfs volume;
    if (statfs(key.fileSystemRepresentation, &volume) != 0 &&
        statfs("/", &volume) != 0) return names;
    char prefix[PATH_MAX];
    if (![key getFileSystemRepresentation:prefix maxLength:sizeof(prefix)]) return names;
    size_t prefixLength = strlen(prefix);
    if (prefixLength == 1 && prefix[0] == '/') prefixLength = 0;
    NSString *probePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ipadn-inode-%@", [NSUUID UUID].UUIDString]];
    [@"" writeToFile:probePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    struct stat probe;
    uint64_t bound = 200000;
    if (stat(probePath.fileSystemRepresentation, &probe) == 0 && probe.st_ino > 0) bound = probe.st_ino;
    [[NSFileManager defaultManager] removeItemAtPath:probePath error:nil];
    if (bound > 8000000) bound = 8000000;
    char buffer[PATH_MAX];
    NSFileManager *files = NSFileManager.defaultManager;
    for (uint64_t inode = 1; inode <= bound; inode++) {
        ssize_t length = fsgetpath(buffer, sizeof(buffer), &volume.f_fsid, inode);
        if (length <= 0) continue;
        if (strncmp(buffer, prefix, prefixLength) != 0) continue;
        if (buffer[prefixLength] != '/') continue;
        if (strchr(buffer + prefixLength + 1, '/')) continue;
        NSString *name = [files stringWithFileSystemRepresentation:buffer length:strlen(buffer)];
        if (name) [names addObject:[name lastPathComponent]];
    }
    return [names sortedArrayUsingSelector:@selector(compare:)];
}

#pragma mark file operations

+ (NSData *)read:(NSString *)path limit:(NSUInteger)limit {
    NSString *key = wq_normalize(path);
    int fd = open(key.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0 && errno == EPERM) {
        if (![self grant:key]) return nil;
        fd = open(key.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    }
    if (fd < 0) return nil;
    NSMutableData *data = [NSMutableData new];
    uint8_t buffer[1 << 16];
    for (;;) {
        size_t want = sizeof(buffer);
        if (limit > 0) {
            if (data.length >= limit) break;
            NSUInteger left = limit - data.length;
            if ((NSUInteger)want > left) want = left;
        }
        ssize_t got = read(fd, buffer, want);
        if (got <= 0) break;
        [data appendBytes:buffer length:(NSUInteger)got];
    }
    close(fd);
    return data;
}

+ (NSData *)readRange:(NSString *)path offset:(unsigned long long)offset length:(NSUInteger)length {
    NSString *key = wq_normalize(path);
    int fd = open(key.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0 && errno == EPERM) {
        if (![self grant:key]) return nil;
        fd = open(key.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    }
    if (fd < 0) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:length];
    NSUInteger done = 0;
    while (done < length) {
        ssize_t got = pread(fd, (uint8_t *)data.mutableBytes + done, length - done, (off_t)(offset + done));
        if (got <= 0) break;
        done += (NSUInteger)got;
    }
    close(fd);
    if (done < length) [data setLength:done];
    return data;
}

+ (BOOL)write:(NSString *)path data:(NSData *)data {
    NSString *key = wq_normalize(path);
    int fd = open(key.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0 && errno == EPERM) {
        if (![self grant:key]) return NO;
        fd = open(key.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    }
    if (fd < 0) return NO;
    NSData *bytes = data ?: NSData.data;
    BOOL ok = YES;
    NSUInteger done = 0;
    const uint8_t *ptr = bytes.bytes;
    while (done < bytes.length) {
        ssize_t put = write(fd, ptr + done, bytes.length - done);
        if (put <= 0) {
            ok = NO;
            break;
        }
        done += (NSUInteger)put;
    }
    close(fd);
    return ok;
}

+ (BOOL)createDirectory:(NSString *)path {
    NSString *key = wq_normalize(path);
    NSFileManager *files = NSFileManager.defaultManager;
    if ([files createDirectoryAtPath:key withIntermediateDirectories:YES attributes:nil error:nil]) return YES;
    NSString *parent = key.stringByDeletingLastPathComponent;
    if (![self grant:parent]) return NO;
    if ([files createDirectoryAtPath:key withIntermediateDirectories:NO attributes:nil error:nil]) return YES;
    if ([self grant:key]) return [files createDirectoryAtPath:key withIntermediateDirectories:YES attributes:nil error:nil];
    return NO;
}

+ (BOOL)remove:(NSString *)path {
    NSString *key = wq_normalize(path);
    NSFileManager *files = NSFileManager.defaultManager;
    if ([files removeItemAtPath:key error:nil]) return YES;
    struct stat st;
    if (lstat(key.fileSystemRepresentation, &st) != 0) return NO;
    if (![self grant:(S_ISDIR(st.st_mode) ? key : key.stringByDeletingLastPathComponent)]) return NO;
    if (!S_ISDIR(st.st_mode)) return unlink(key.fileSystemRepresentation) == 0;
    for (NSString *child in [self list:key]) {
        if (![self remove:[key stringByAppendingPathComponent:child]]) return NO;
    }
    return rmdir(key.fileSystemRepresentation) == 0;
}

+ (BOOL)rename:(NSString *)path to:(NSString *)newName {
    NSString *key = wq_normalize(path);
    NSString *target = wq_normalize(newName);
    if ([key isEqualToString:target]) return YES;
    if (![self grant:key.stringByDeletingLastPathComponent]) return NO;
    if (![self grant:target.stringByDeletingLastPathComponent]) return NO;
    if (rename(key.fileSystemRepresentation, target.fileSystemRepresentation) == 0) return YES;
    if (errno == EXDEV) {
        if (![self copyFile:key to:target]) return NO;
        return [self remove:key];
    }
    return NO;
}

+ (BOOL)copyFile:(NSString *)src to:(NSString *)dst {
    NSString *from = wq_normalize(src);
    NSString *to = wq_normalize(dst);
    if ([from isEqualToString:to]) return YES;
    if ([[NSFileManager defaultManager] copyItemAtPath:from toPath:to error:nil]) return YES;
    if (![self grant:from]) return NO;
    if (![self grant:to.stringByDeletingLastPathComponent]) return NO;
    int in = open(from.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (in < 0) return NO;
    int out = open(to.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (out < 0) {
        close(in);
        return NO;
    }
    uint8_t buffer[1 << 16];
    BOOL ok = YES;
    for (;;) {
        ssize_t got = read(in, buffer, sizeof(buffer));
        if (got < 0) {
            ok = NO;
            break;
        }
        if (got == 0) break;
        ssize_t put = write(out, buffer, (size_t)got);
        if (put != got) {
            ok = NO;
            break;
        }
    }
    close(in);
    close(out);
    if (!ok) unlink(to.fileSystemRepresentation);
    return ok;
}

+ (BOOL)statPath:(NSString *)path isDirectory:(BOOL *)isDirectory size:(unsigned long long *)size modified:(long long *)modified symbolic:(BOOL *)symbolic {
    NSString *key = wq_normalize(path);
    struct stat st;
    if (lstat(key.fileSystemRepresentation, &st) != 0) {
        if (errno != EPERM && errno != EACCES) return NO;
        if (![self grant:key]) return NO;
        if (lstat(key.fileSystemRepresentation, &st) != 0) return NO;
    }
    if (isDirectory) *isDirectory = S_ISDIR(st.st_mode);
    if (symbolic) *symbolic = S_ISLNK(st.st_mode);
    if (size) *size = (unsigned long long)st.st_size;
    if (modified) *modified = (long long)st.st_mtimespec.tv_sec;
    return YES;
}

+ (NSString *)containerLabel:(NSString *)dir {
    NSString *metadata = [wq_normalize(dir) stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSData *data = [self read:metadata limit:1 << 20];
    if (!data) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
    if (!plist) return nil;
    NSString *identifier = [plist isKindOfClass NSDictionary.class] ? plist[@"MCMMetadataIdentifier"] : nil;
    if (![identifier isKindOfClass:NSString.class]) return nil;
    return identifier;
}

@end
