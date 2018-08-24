//
//  QueuedDownloadSession.m
//  DownloadSessionOperation
//
// License: https://github.com/travisjeffery/TRVSURLSessionOperation/blob/master/LICENSE
//

#import <AVFoundation/AVFoundation.h>
#import "QueuedDownloadSession.h"

#define QUEUED_DOWNLOAD_BLOCK(KEYPATH, BLOCK) \
[self willChangeValueForKey:KEYPATH]; \
BLOCK(); \
[self didChangeValueForKey:KEYPATH];

@interface DownloadSessionOperation ()
@property (nonatomic, strong) AVAssetDownloadURLSession *session;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) AVAssetDownloadTask *task;
@property (nonatomic, assign) int attempt;
@end

@implementation DownloadSessionOperation {
    BOOL _finished;
    BOOL _executing;
}

- (instancetype)initWithSession:(AVAssetDownloadURLSession *)session url:(NSURL *)url cacheKey:(NSString *)cacheKey {
    if (self = [super init]) {
        self.suspended = NO;
        self.url = url;
        self.cacheKey = cacheKey;
        self.session = session;
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
    NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:self.url options:@{AVURLAssetHTTPCookiesKey : cookies, AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
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
    if([self hasCachedAsset]) {
        NSLog(@"Downloader prefetch found cached asset for %@", self.cacheKey);
        [self completeOperation];
        return;
    }
    NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:self.url options:@{AVURLAssetHTTPCookiesKey : cookies, AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
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
    [self willChangeValueForKey:@"isFinished"];
    [self willChangeValueForKey:@"isExecuting"];
    
    _executing = NO;
    _finished = YES;
    
    [self didChangeValueForKey:@"isExecuting"];
    [self didChangeValueForKey:@"isFinished"];
}

- (BOOL)hasCachedAsset {
#if TARGET_IPHONE_SIMULATOR
    return NO;
#else
    NSData *bookmarkData = [[NSUserDefaults standardUserDefaults] objectForKey:self.cacheKey];
    if(bookmarkData) {
        NSError *error = nil;
        BOOL stale;
        NSURL *location = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                    options:NSURLBookmarkResolutionWithoutUI
                                              relativeToURL:nil
                                        bookmarkDataIsStale:&stale
                                                      error:&error];
        if(error) {
            return NO;
        } else if(stale) {
            return NO;
        } else if(location) {
            return YES;
        }
    }
    return NO;
#endif
}

@end

