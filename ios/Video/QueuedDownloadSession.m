//
//  QueuedDownloadSession.m
//  DownloadSessionOperation
//
// License: https://github.com/travisjeffery/TRVSURLSessionOperation/blob/master/LICENSE
//

#import <AVFoundation/AVFoundation.h>
#import "QueuedDownloadSession.h"
#import "RCTVideoDownloader.h"

#define QUEUED_DOWNLOAD_BLOCK(KEYPATH, BLOCK) \
[self willChangeValueForKey:KEYPATH]; \
BLOCK(); \
[self didChangeValueForKey:KEYPATH];

@interface DownloadSessionOperation ()
@property (nonatomic, strong) AVAssetDownloadURLSession *session;
@property (nonatomic, strong) RCTVideoDownloader *delegate;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) AVAssetDownloadTask *task;
@property (nonatomic, copy) NSArray *cookies;
@property (nonatomic, assign) int attempt;
@end

@implementation DownloadSessionOperation {
    BOOL _finished;
    BOOL _executing;
}

- (instancetype)initWithDelegate:(RCTVideoDownloader *)delegate url:(NSURL *)url cacheKey:(NSString *)cacheKey cookies:(NSArray *)cookies {
    if (self = [super init]) {
        self.suspended = NO;
        self.url = url;
        self.cacheKey = cacheKey;
        self.session = delegate.session;
        self.delegate = delegate;
        self.cookies = cookies;
        self.attempt = 1;
        _executing = NO;
        _finished = NO;
    }
    return self;
}

- (void)suspend {
    [self.task cancel];
    self.suspended = YES;
}

- (void)resume {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:self.url options:@{AVURLAssetHTTPCookiesKey : self.cookies, AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
    asset.resourceLoader.preloadsEligibleContentKeys = YES;
    self.task = [self.session assetDownloadTaskWithURLAsset:asset
                                                 assetTitle:@"Video Download"
                                           assetArtworkData:nil
                                                    options:nil];
    if (!self.task && self.session.configuration.identifier) {
        for (NSUInteger attempts = 0; !self.task && attempts < 3; attempts++) {
            self.task = [self.session assetDownloadTaskWithURLAsset:asset
                                                         assetTitle:@"Video Download"
                                                   assetArtworkData:nil
                                                            options:nil];
        }
    }
    self.task.taskDescription = self.cacheKey;
    [self.task resume];
    self.suspended = NO;
}

- (void)retry {
    [self.task cancel];
    [self performSelector:@selector(resume) withObject:self afterDelay:self.attempt * self.attempt * 30];
    NSLog(@"Retry attempt %d for %@ starting in %d seconds", self.attempt, self.cacheKey, self.attempt * self.attempt * 30);
    self.attempt++;
}

- (int)attempts {
    return self.attempt;
}

- (void)cancel {
    [super cancel];
    [self.task cancel];
}

- (void)start {
    if (self.isCancelled) {
        QUEUED_DOWNLOAD_BLOCK(@"isFinished", ^{ _finished = YES; });
        return;
    }
    if([self.delegate hasCachedAsset:self.cacheKey]) {
        NSLog(@"Downloader prefetch found cached asset for %@", self.cacheKey);
        [self completeOperation];
        return;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:self.url options:@{AVURLAssetHTTPCookiesKey : self.cookies, AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
    asset.resourceLoader.preloadsEligibleContentKeys = YES;
    self.task = [self.session assetDownloadTaskWithURLAsset:asset
                                                 assetTitle:@"Video Download"
                                           assetArtworkData:nil
                                                    options:nil];
    if (!self.task && self.session.configuration.identifier) {
        for (NSUInteger attempts = 0; !self.task && attempts < 3; attempts++) {
            self.task = [self.session assetDownloadTaskWithURLAsset:asset
                                                         assetTitle:@"Video Download"
                                                   assetArtworkData:nil
                                                            options:nil];
        }
    }
    self.task.taskDescription = self.cacheKey;
    QUEUED_DOWNLOAD_BLOCK(@"isExecuting", ^{
        NSLog(@"Downloader prefetch executing for %@", self.task.taskDescription);
        [self.task resume];
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
    }
}

@end

