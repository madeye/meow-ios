#import "MWSharedStore.h"
#import "MWAppGroup.h"
#import "MWPreferences.h"

@implementation MWSharedStore

+ (BOOL)writeDict:(NSDictionary *)dict toURL:(NSURL *)url error:(NSError **)error {
    NSURL *dir = [url URLByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:error];
    if (!data) return NO;
    return [data writeToURL:url options:NSDataWritingAtomic error:error];
}

+ (nullable NSDictionary *)readDictFromURL:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

+ (BOOL)writeState:(NSDictionary *)state error:(NSError **)error {
    return [self writeDict:state toURL:[MWAppGroup stateURL] error:error];
}

+ (nullable NSDictionary *)readState {
    return [self readDictFromURL:[MWAppGroup stateURL]];
}

+ (BOOL)writeTraffic:(NSDictionary *)traffic error:(NSError **)error {
    return [self writeDict:traffic toURL:[MWAppGroup trafficURL] error:error];
}

+ (nullable NSDictionary *)readTraffic {
    return [self readDictFromURL:[MWAppGroup trafficURL]];
}

+ (BOOL)queueIntent:(NSDictionary *)intent error:(NSError **)error {
    NSData *data = [NSJSONSerialization dataWithJSONObject:intent options:0 error:error];
    if (!data) return NO;
    [[MWAppGroup defaults] setObject:data forKey:MWPrefKeyPendingIntent];
    return YES;
}

+ (nullable NSDictionary *)takeIntent {
    NSData *data = [[MWAppGroup defaults] dataForKey:MWPrefKeyPendingIntent];
    if (!data) return nil;
    [[MWAppGroup defaults] removeObjectForKey:MWPrefKeyPendingIntent];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

@end
