//
//  QueuedDownloadSession.m
//  DownloadSessionOperation
//
// License: https://github.com/travisjeffery/TRVSURLSessionOperation/blob/master/LICENSE
//

#import <AVFoundation/AVFoundation.h>
#import "QueuedDownloadSession.h"
#import "RCTVideoDownloader.h"
#import "RCTVideoDownloaderDelegate.h"

#define QUEUED_DOWNLOAD_BLOCK(KEYPATH, BLOCK) \
[self willChangeValueForKey:KEYPATH]; \
BLOCK(); \
[self didChangeValueForKey:KEYPATH];

@interface DownloadSessionOperation ()
@property (nonatomic, strong) AVAssetDownloadURLSession *session;
@property (nonatomic, strong) RCTVideoDownloader *delegate;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) NSArray *cookies;
@property (nonatomic, assign) int attempt;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation DownloadSessionOperation {
    BOOL _finished;
    BOOL _executing;
}

- (instancetype)initWithDelegate:(RCTVideoDownloader *)delegate url:(NSURL *)url cacheKey:(NSString *)cacheKey cookies:(NSArray *)cookies queue:(dispatch_queue_t)queue{
    if (self = [super init]) {
        self.suspended = NO;
        self.url = url;
        self.cacheKey = cacheKey;
        self.session = delegate.session;
        self.delegate = delegate;
        self.cookies = cookies;
        self.attempt = 1;
        self.queue = queue;
        _executing = NO;
        _finished = NO;
    }
    return self;
}

- (void)suspend {
    [self.task cancel];
    self.task = nil;
    self.suspended = YES;
}

- (void)resume {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:self.url options:@{AVURLAssetHTTPCookiesKey : self.cookies, AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
    RCTVideoDownloaderDelegate *delegate = [RCTVideoDownloaderDelegate sharedVideoDownloaderDelegate];
    [delegate addCompletionHandlerForAsset:asset completionHandler:^(BOOL playlistIsComplete, NSError *error){
        NSString * urlString = [self.url absoluteString];
        if(error) {
            NSLog(@"VideoDownloader: Error starting task for asset %@ with cache key %@: %@", urlString, self.cacheKey, error.localizedDescription);
            return;
        }
        if(!playlistIsComplete) {
            NSLog(@"VideoDownloader: Incomplete playlist for prefetch task for asset %@ with cache key %@", urlString, self.cacheKey);
            [[RCTVideoDownloaderDelegate sharedVideoDownloaderDelegate] removeCompletionHandlerForAsset:asset];
            [self completeOperation];
            return;
        }
        NSArray *preferredMediaSelections = [NSArray arrayWithObjects:asset.preferredMediaSelection,nil];
        self.task = [self.session aggregateAssetDownloadTaskWithURLAsset:asset
                                                         mediaSelections:preferredMediaSelections
                                                              assetTitle:@"Video Download"
                                                        assetArtworkData:nil
                                                                 options:nil];
        if (!self.task && self.session.configuration.identifier) {
            for (NSUInteger attempts = 0; !self.task && attempts < 3; attempts++) {
                self.task = [self.session aggregateAssetDownloadTaskWithURLAsset:asset
                                                                 mediaSelections:preferredMediaSelections
                                                                      assetTitle:@"Video Download"
                                                                assetArtworkData:nil
                                                                         options:nil];
            }
        }
        self.task.taskDescription = self.cacheKey;
        [self.task resume];
        NSLog(@"VideoDownloader: Got new prefetch task %lu for asset %@ with cache key %@", (unsigned long)self.task.taskIdentifier, urlString, self.cacheKey);
    }];
    [asset.resourceLoader setDelegate:delegate queue:self.queue];
    asset.resourceLoader.preloadsEligibleContentKeys = YES;
    self.suspended = NO;
}

- (void)retry {
    if(self.task) {
        [self.task cancel];
        self.task = nil;
    }
    [self performSelectorOnMainThread:@selector(scheduleResume) withObject:nil waitUntilDone:YES];
}

- (void)scheduleResume {
    NSTimeInterval waitTime = self.attempt < 5 ? self.attempt * self.attempt : 60;
    NSLog(@"VideoDownloader: Prefetch retry attempt %d for %@ starting in %f seconds", self.attempt, self.cacheKey, waitTime);
    [self performSelector:@selector(resume) withObject:nil afterDelay:waitTime];
    self.attempt++;
}

- (int)attempts {
    return self.attempt;
}

- (void)cancel {
    if(self.task) {
        [self.task cancel];
        self.task = nil;
    }
    [super cancel];
}

- (void)start {
    if (self.isCancelled) {
        QUEUED_DOWNLOAD_BLOCK(@"isFinished", ^{ _finished = YES; });
        return;
    }
    if([self.delegate hasCachedAsset:self.cacheKey]) {
        NSLog(@"VideoDownloader: Prefetch cached asset found for %@ with cache key %@", [self.url absoluteString], self.cacheKey);
        QUEUED_DOWNLOAD_BLOCK(@"isFinished", ^{ _finished = YES; });
        return;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:self.url options:@{AVURLAssetHTTPCookiesKey : self.cookies, AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
    
    RCTVideoDownloaderDelegate *delegate = [RCTVideoDownloaderDelegate sharedVideoDownloaderDelegate];
    [delegate addCompletionHandlerForAsset:asset completionHandler:^(BOOL playlistIsComplete, NSError *error){
        NSString * urlString = [self.url absoluteString];
        if(error) {
            NSLog(@"VideoDownloader: Error starting prefetch task for asset %@ with cache key %@: %@", urlString, self.cacheKey, error.localizedDescription);
            return;
        }
        if(!playlistIsComplete) {
            NSLog(@"VideoDownloader: Incomplete playlist for prefetch task for asset %@ with cache key %@", urlString, self.cacheKey);
            [[RCTVideoDownloaderDelegate sharedVideoDownloaderDelegate] removeCompletionHandlerForAsset:asset];
            [self completeOperation];
            return;
        }
        NSArray *preferredMediaSelections = [NSArray arrayWithObjects:asset.preferredMediaSelection,nil];
        self.task = [self.session aggregateAssetDownloadTaskWithURLAsset:asset
                                                         mediaSelections:preferredMediaSelections
                                                              assetTitle:@"Video Download"
                                                        assetArtworkData:nil
                                                                 options:nil];
        if (!self.task && self.session.configuration.identifier) {
            for (NSUInteger attempts = 0; !self.task && attempts < 3; attempts++) {
                self.task = [self.session aggregateAssetDownloadTaskWithURLAsset:asset
                                                                 mediaSelections:preferredMediaSelections
                                                                      assetTitle:@"Video Download"
                                                                assetArtworkData:nil
                                                                         options:nil];
            }
        }
        self.task.taskDescription = self.cacheKey;
        [self.task resume];
        NSLog(@"VideoDownloader: Got new prefetch task %lu for asset %@ with cache key %@", (unsigned long)self.task.taskIdentifier, urlString, self.cacheKey);
    }];
    [asset.resourceLoader setDelegate:delegate queue:self.queue];
    asset.resourceLoader.preloadsEligibleContentKeys = YES;
    QUEUED_DOWNLOAD_BLOCK(@"isExecuting", ^{
        NSLog(@"VideoDownloader: Prefetch executing for %@ with cache key %@", [self.url absoluteString], self.cacheKey);
        _executing = YES;
    });
}

- (BOOL)isExecuting {
    return _executing;
}

- (BOOL)isFinished {
    return _finished;
}

- (BOOL)isConcurrent {
    return YES;
}

- (void)completeOperation {
    if(_executing && !_finished) {
        [self willChangeValueForKey:@"isFinished"];
        [self willChangeValueForKey:@"isExecuting"];
        
        _executing = NO;
        _finished = YES;
        
        [self didChangeValueForKey:@"isExecuting"];
        [self didChangeValueForKey:@"isFinished"];
        NSLog(@"VideoDownloader: Prefetch finished for %@ with cache key %@", [self.url absoluteString], self.cacheKey);
    }
}

@end


