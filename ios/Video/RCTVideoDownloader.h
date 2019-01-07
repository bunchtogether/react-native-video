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
         cookies:(NSArray *)cookies
         resolve:(RCTPromiseResolveBlock)resolve
         reject:(RCTPromiseRejectBlock)reject;

- (void)getAsset:(NSURL *)url
        cacheKey:(NSString *)cacheKey
         cookies:(NSArray *)cookies
      completion:(void (^)(AVURLAsset *asset, NSError *))completion;

- (BOOL)hasCachedAsset:(NSString *)cacheKey;
- (void)clearCachedAsset:(NSString *)cacheKey;

@end
