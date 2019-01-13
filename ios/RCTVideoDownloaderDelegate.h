//
//  RCTVideoDownloaderDelegate.h
//  RCTVideo
//
//  Created by John Wehr on 1/4/19.
//

#import <AVFoundation/AVAssetResourceLoader.h>

@interface RCTVideoDownloaderDelegate : NSObject <AVAssetResourceLoaderDelegate>

- (instancetype)initWith:(dispatch_queue_t)queue completionHandler:(void (^)(NSError *))completionHandler;

+ (void)clearCacheForUrl:(NSURL*)url;

@end

