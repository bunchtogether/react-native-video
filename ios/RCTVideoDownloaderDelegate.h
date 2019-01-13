//
//  RCTVideoDownloaderDelegate.h
//  RCTVideo
//
//  Created by John Wehr on 1/4/19.
//

#import <AVFoundation/AVAssetResourceLoader.h>

@interface RCTVideoDownloaderDelegate : NSObject <AVAssetResourceLoaderDelegate>

+ (instancetype)sharedVideoDownloaderDelegate;

- (void)addCompletionHandlerForAsset:(AVURLAsset *)asset completionHandler:(void (^)(NSError *))completionHandler;

+ (void)clearCacheForUrl:(NSString*)urlString;

@end

