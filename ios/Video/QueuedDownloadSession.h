//
//  QueuedDownloadSession.h
//  DownloadSessionOperation
//
// License: https://github.com/travisjeffery/TRVSURLSessionOperation/blob/master/LICENSE
//

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import "RCTVideoDownloader.h"

@interface DownloadSessionOperation : NSOperation

- (instancetype)initWithDelegate:(RCTVideoDownloader *)delegate url:(NSURL *)url cacheKey:(NSString *)cacheKey cookies:(NSArray *)cookies queue:(dispatch_queue_t)queue;
- (void)completeOperation;
- (void)retry;
- (void)suspend;
- (void)resume;
- (int)attempts;

@property (nonatomic, copy) NSString *cacheKey;
@property (nonatomic, assign) BOOL suspended;
@property (nonatomic, strong, readonly) AVAggregateAssetDownloadTask *task;

@end

