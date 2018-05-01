#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <React/RCTBridge.h>

@class RCTVideoDownloader;

@interface RCTVideoDownloader : NSObject <AVAssetDownloadDelegate>

- (instancetype)init;

- (void)prefetch:(NSString *)uri
        resolve:(RCTPromiseResolveBlock)resolve
        reject:(RCTPromiseRejectBlock)reject;

- (AVURLAsset *)getAsset:(NSURL *)url;

@end
