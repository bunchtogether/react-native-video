//
//  QueuedDownloadSession.m
//  DownloadSessionOperation
//
// License: https://github.com/travisjeffery/TRVSURLSessionOperation/blob/master/LICENSE
//

#import "QueuedDownloadSession.h"

#define QUEUED_DOWNLOAD_BLOCK(KEYPATH, BLOCK) \
[self willChangeValueForKey:KEYPATH]; \
BLOCK(); \
[self didChangeValueForKey:KEYPATH];

@interface DownloadSessionOperation ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, strong) NSURLSessionUploadTask *task;
@property (nonatomic, assign) int attempt;
@end

@implementation DownloadSessionOperation {
    BOOL _finished;
    BOOL _executing;
}

- (instancetype)initWithSession:(NSURLSession *)session uploadId:(NSString *)uploadId request:(NSURLRequest *)request {
    if (self = [super init]) {
        self.suspended = NO;
        self.request = request;
        self.session = session;
        self.uploadId = uploadId;
        self.attempt = 1;
        _executing = NO;
        _finished = NO;
    }
    return self;
}

- (instancetype)initWithSession:(NSURLSession *)session uploadId:(NSString *)uploadId request:(NSURLRequest *)request fromFileUrl:(NSURL *)fileURL {
    if (self = [super init]) {
        self.suspended = NO;
        self.request = request;
        self.fileURL = fileURL;
        self.session = session;
        self.uploadId = uploadId;
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
    if(self.fileURL && self.request) {
        self.task = [self.session uploadTaskWithRequest:self.request fromFile:self.fileURL];
    } else if(self.request) {
        self.task = [self.session uploadTaskWithRequest:self.request fromData:nil];
    }
    self.task.taskDescription = self.uploadId;
    [self.task resume];
    self.suspended = NO;
}

- (void)retry {
    [self.task cancel];
    [self performSelector:@selector(resume) withObject:self afterDelay:self.attempt * self.attempt * 30];
    NSLog(@"Retry attempt %d for %@ starting in %d seconds", self.attempt, self.uploadId, self.attempt * self.attempt * 30);
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
    if(self.fileURL) {
        self.task = [self.session uploadTaskWithRequest:self.request fromFile:self.fileURL];
        // Retry a failed background task if initial creation did not succeed
        if (!self.task && self.session.configuration.identifier) {
            for (NSUInteger attempts = 0; !self.task && attempts < 3; attempts++) {
                self.task = [self.session uploadTaskWithRequest:self.request fromFile:self.fileURL];
            }
        }
    } else {
        self.task = [self.session uploadTaskWithRequest:self.request fromData:nil];
        // Retry a failed background task if initial creation did not succeed
        if (!self.task && self.session.configuration.identifier) {
            for (NSUInteger attempts = 0; !self.task && attempts < 3; attempts++) {
                self.task = [self.session uploadTaskWithRequest:self.request fromData:nil];
            }
        }
    }
    self.task.taskDescription = self.uploadId;
    QUEUED_DOWNLOAD_BLOCK(@"isExecuting", ^{
        NSLog(@"isExecuting %@", self.task.taskDescription);
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

@end

