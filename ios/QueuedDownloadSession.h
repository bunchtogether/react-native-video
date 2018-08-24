//
//  QueuedDownloadSession.h
//  DownloadSessionOperation
//
// License: https://github.com/travisjeffery/TRVSURLSessionOperation/blob/master/LICENSE
//

#import <Foundation/Foundation.h>

@interface DownloadSessionOperation : NSOperation

- (instancetype)initWithSession:(NSURLSession *)session uploadId:(NSString *)uploadId request:(NSURLRequest *)request;
- (instancetype)initWithSession:(NSURLSession *)session uploadId:(NSString *)uploadId request:(NSURLRequest *)request fromFileUrl:(NSURL *)fileURL;
- (void)completeOperation;
- (void)retry;
- (void)suspend;
- (void)resume;
- (int)attempts;

@property (nonatomic, copy) NSString *uploadId;
@property (nonatomic, assign) BOOL suspended;
@property (nonatomic, strong, readonly) NSURLSessionDataTask *task;

@end
