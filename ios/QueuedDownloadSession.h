//
//  QueuedDownloadSession.h
//  DownloadSessionOperation
//
// License: https://github.com/travisjeffery/TRVSURLSessionOperation/blob/master/LICENSE
//

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

@interface DownloadSessionOperation : NSOperation

- (instancetype)initWithSession:(NSURLSession *)session url:(NSURL *)url cacheKey:(NSString *)cacheKey;
- (void)completeOperation;
- (void)retry;
- (void)suspend;
- (void)resume;
- (int)attempts;

@property (nonatomic, copy) NSString *cacheKey;
@property (nonatomic, assign) BOOL suspended;
@property (nonatomic, strong, readonly) AVAssetDownloadTask *task;

@end
