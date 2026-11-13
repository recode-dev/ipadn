#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WorseQueryAccess : NSObject

+ (NSString *_Nullable)appGroup;
+ (BOOL)escapeAvailable;
+ (BOOL)systemAreasReachable;
+ (BOOL)grant:(NSString *)path;
+ (NSString *_Nullable)grantedStageRoot;
+ (NSArray<NSString *> *)list:(NSString *)dir;
+ (NSArray<NSString *> *)enumerate:(NSString *)dir;
+ (NSData *_Nullable)read:(NSString *)path limit:(NSUInteger)limit;
+ (NSData *_Nullable)readRange:(NSString *)path offset:(unsigned long long)offset length:(NSUInteger)length;
+ (BOOL)write:(NSString *)path data:(NSData *)data;
+ (BOOL)createDirectory:(NSString *)path;
+ (BOOL)remove:(NSString *)path;
+ (BOOL)rename:(NSString *)path to:(NSString *)newName;
+ (BOOL)copyFile:(NSString *)src to:(NSString *)dst;
+ (BOOL)statPath:(NSString *)path isDirectory:(BOOL *)isDirectory size:(unsigned long long *)size modified:(long long *)modified symbolic:(BOOL *)symbolic;
+ (NSString *_Nullable)containerLabel:(NSString *)dir;

@end

NS_ASSUME_NONNULL_END
