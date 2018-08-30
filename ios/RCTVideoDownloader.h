#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <React/RCTBridge.h>

@interface RCTVideoDownloader : NSObject <AVAssetDownloadDelegate>

@property (nonatomic, strong) AVAssetDownloadURLSession *session;

+ (instancetype)sharedVideoDownloader;

- (instancetype)init;

- (BOOL)hasCachedAsset:(NSString *)cacheKey;

- (void)prefetch:(NSString *)uri
        cacheKey:(NSString *)cacheKey
         resolve:(RCTPromiseResolveBlock)resolve
         reject:(RCTPromiseRejectBlock)reject;

- (void)getAsset:(NSURL *)url cacheKey:(NSString *)cacheKey completion:(void (^)(AVURLAsset *asset, NSError *))completion;
- (BOOL)hasCachedAsset:(NSString *)cacheKey;
- (void)clearCachedAsset:(NSString *)cacheKey;
- (void)invalidate;

@end
