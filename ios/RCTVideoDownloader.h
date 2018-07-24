#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <React/RCTBridge.h>

@interface RCTVideoDownloader : NSObject <AVAssetDownloadDelegate>

+ (instancetype)sharedVideoDownloader;

- (instancetype)init;

- (void)prefetch:(NSString *)uri
        cacheKey:(NSString *)cacheKey
         resolve:(RCTPromiseResolveBlock)resolve
         reject:(RCTPromiseRejectBlock)reject;

- (AVURLAsset *)getAsset:(NSURL *)url cacheKey:(NSString *)cacheKey;
- (BOOL)hasCachedAsset:(NSString *)cacheKey;
- (void)clearCachedAsset:(NSString *)cacheKey;

@end
