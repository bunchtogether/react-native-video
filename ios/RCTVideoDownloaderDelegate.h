//
//  RCTVideoDownloaderDelegate.h
//  RCTVideo
//
//  Created by John Wehr on 1/4/19.
//

#import <AVFoundation/AVAssetResourceLoader.h>

@interface RCTVideoDownloaderDelegate : NSObject <AVAssetResourceLoaderDelegate>

+ (instancetype)sharedVideoDownloaderDelegate;

- (void)clearCacheForUrl:(NSURL*)baseUrl;

@end

