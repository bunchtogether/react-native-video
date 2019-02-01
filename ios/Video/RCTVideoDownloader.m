#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <React/RCTBridge.h>
#import <React/RCTLog.h>
#import <Security/Security.h>
#import "RCTVideoDownloader.h"
#import "QueuedDownloadSession.h"
#import "BackgroundDownloadAppDelegate.h"
#import "RCTVideoDownloaderDelegate.h"

@interface RCTVideoDownloader ()

@property (nonatomic, strong) NSMutableDictionary *tasks;
@property (nonatomic, strong) RCTVideoDownloaderDelegate *delegate;
@property (nonatomic, strong) NSMutableDictionary *validatedAssets;
@property (nonatomic, strong) NSMutableDictionary *downloadLocationUrls;
@property (nonatomic, strong) NSOperationQueue *prefetchOperationQueue;
@property (nonatomic, strong) NSMutableSet *cacheKeys;
@property (nonatomic, assign) BOOL suspended;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_queue_t delegateQueue;
@end

@implementation RCTVideoDownloader

- (instancetype)init
{
  self = [super init];
  if (self) {
    self.tasks = [[NSMutableDictionary alloc] init];
    self.validatedAssets = [[NSMutableDictionary alloc] init];
    self.downloadLocationUrls = [[NSMutableDictionary alloc] init];
    NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:@"ReactNativeVideoDownloader"];
    sessionConfig.networkServiceType = NSURLNetworkServiceTypeVideo;
    sessionConfig.allowsCellularAccess = true;
    sessionConfig.sessionSendsLaunchEvents = true;
    sessionConfig.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
    sessionConfig.HTTPShouldUsePipelining = YES;
    self.session = [AVAssetDownloadURLSession sessionWithConfiguration:sessionConfig assetDownloadDelegate:self delegateQueue:[NSOperationQueue mainQueue]];
    self.session.sessionDescription = @"ReactNativeVideoDownloader";
    self.prefetchOperationQueue = [[NSOperationQueue alloc] init];
    self.prefetchOperationQueue.maxConcurrentOperationCount = 1;
    self.suspended = NO;
    self.cacheKeys = [[NSMutableSet alloc] init];
    self.queue = dispatch_queue_create("Video Downloader Queue", DISPATCH_QUEUE_SERIAL);
    self.delegateQueue = dispatch_queue_create("Video Downloader Delegate Queue", DISPATCH_QUEUE_SERIAL);
    self.delegate = [RCTVideoDownloaderDelegate sharedVideoDownloaderDelegate];
  }
  return self;
}

+ (instancetype)sharedVideoDownloader {
  static RCTVideoDownloader *sharedVideoDownloader = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedVideoDownloader = [[self alloc] init];
  });
  return sharedVideoDownloader;
}

- (void)dealloc
{
  NSLog(@"RCTVideoDownloader dealloc");
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self.session invalidateAndCancel];
  [self.prefetchOperationQueue cancelAllOperations];
  self.prefetchOperationQueue = nil;
  self.session = nil;
}

- (BOOL)hasCachedAsset:(NSString *)cacheKey {
#if TARGET_IPHONE_SIMULATOR
  return NO;
#else
  @synchronized(self.validatedAssets) {
    AVURLAsset *validatedAsset = self.validatedAssets[cacheKey];
    if(validatedAsset) {
      return YES;
    }
  }
  @synchronized(self.tasks) {
    AVAggregateAssetDownloadTask *activeTask = self.tasks[cacheKey];
    if(activeTask) {
      return YES;
    }
  }
  for(DownloadSessionOperation *operation in self.prefetchOperationQueue.operations) {
    if(operation.task && [operation.cacheKey isEqualToString:cacheKey]) {
      return YES;
    }
  }
  NSData *bookmarkData = [[NSUserDefaults standardUserDefaults] objectForKey:cacheKey];
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

- (void)clearCachedAsset:(NSString *)cacheKey {
  RCTLog(@"VideoDownloader: Clearing cache for %@", cacheKey);
  @synchronized(self.validatedAssets) {
    AVURLAsset *validatedAsset = self.validatedAssets[cacheKey];
    if(validatedAsset) {
      [self.validatedAssets removeObjectForKey:cacheKey];
    }
  }
  @synchronized(self.tasks) {
    AVAggregateAssetDownloadTask *activeTask = self.tasks[cacheKey];
    if(activeTask) {
      [activeTask cancel];
      [self.tasks removeObjectForKey:cacheKey];
    }
  }
  for(DownloadSessionOperation *operation in self.prefetchOperationQueue.operations) {
    if(operation.task && [operation.cacheKey isEqualToString:cacheKey]) {
      [operation cancel];
    }
  }
  [RCTVideoDownloaderDelegate clearCacheForUrl:[NSURL URLWithString:cacheKey]];
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:cacheKey];
}

- (void)validateAsset:(AVURLAsset *)asset cacheKey:(NSString *)cacheKey completion:(void (^)(AVURLAsset *, NSError *))completion {
  [asset loadValuesAsynchronouslyForKeys:@[@"playable"] completionHandler:^{
    NSError *error = nil;
    AVKeyValueStatus status = [asset statusOfValueForKey:@"playable" error:&error];
    if(status == AVKeyValueStatusLoaded) {
      NSLog(@"VideoDownloader: Validated asset with cache key %@", cacheKey);
      @synchronized(self.validatedAssets) {
        self.validatedAssets[cacheKey] = asset;
      }
      
      AVAssetCache *assetCache = asset.assetCache;
      if(completion){
        completion(asset, nil);
      }
      return;
    }
    if(error) {
      NSLog(@"VideoDownloader: Could not validate asset with cache key %@, %@", cacheKey, error.localizedDescription);
      if(completion) {
        completion(nil, error);
      }
      return;
    }
    NSLog(@"VideoDownloader: Could not validate asset with cache key %@, status: %d", cacheKey, (int)status);
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: NSLocalizedString(@"Unable to load duration property", nil)};
    error = [NSError errorWithDomain:@"RCTVideoDownloader"
                                code:(int)status
                            userInfo:userInfo];
    if(completion) {
      completion(nil, error);
    }
  }];
}

- (AVURLAsset *)getBookmarkedAsset:(NSString *)urlString cacheKey:(NSString *)cacheKey {
  NSData *bookmarkData = [[NSUserDefaults standardUserDefaults] objectForKey:cacheKey];
  if(bookmarkData) {
    NSError *error = nil;
    BOOL stale;
    NSURL *location = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                options:NSURLBookmarkResolutionWithoutUI
                                          relativeToURL:nil
                                    bookmarkDataIsStale:&stale
                                                  error:&error];
    
    if(error) {
      NSLog(@"VideoDownloader: Error getting cached asset %@ with cache key %@: %@", urlString, cacheKey, error);
    } else if(stale) {
      NSLog(@"VideoDownloader: Cached asset %@ with cache key %@ is stale", urlString, cacheKey);
    } else if(location) {
      AVURLAsset *asset = [AVURLAsset URLAssetWithURL:location options:@{AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
      [self.delegate addCompletionHandlerForAsset:asset completionHandler:^(BOOL playlistIsComplete, NSError *error){
        if(error) {
          NSLog(@"VideoDownloader: Error starting task for bookmarked asset %@ with cache key %@: %@", urlString, cacheKey, error.localizedDescription);
          return;
        }
        if(!playlistIsComplete) {
          NSLog(@"VideoDownloader: Incomplete playlist for bookmarked asset %@ with cache key %@", urlString, cacheKey);
          return;
        }
        NSArray *preferredMediaSelections = [NSArray arrayWithObjects:asset.preferredMediaSelection,nil];
        AVAggregateAssetDownloadTask *task = [self.session aggregateAssetDownloadTaskWithURLAsset:asset
                                                                                  mediaSelections:preferredMediaSelections
                                                                                       assetTitle:@"Video Download"
                                                                                 assetArtworkData:nil
                                                                                          options:nil];
        task.taskDescription = cacheKey;
        @synchronized(self.tasks) {
          self.tasks[cacheKey] = task;
        }
        [task resume];
        NSLog(@"VideoDownloader: Got new task %lu for bookmarked asset %@ with cache key %@", (unsigned long)task.taskIdentifier, urlString, cacheKey);
      }];
      [asset.resourceLoader setDelegate:self.delegate queue:self.delegateQueue];
      asset.resourceLoader.preloadsEligibleContentKeys = YES;
      return asset;
    }
  }
  return nil;
}

- (AVAggregateAssetDownloadTask *)getPrefetchTask:(NSString *)cacheKey urlString:(NSString *)urlString {
  for(DownloadSessionOperation *operation in self.prefetchOperationQueue.operations) {
    if(operation.task && [operation.cacheKey isEqualToString:cacheKey]) {
      AVAggregateAssetDownloadTask *task = operation.task;
      operation.task = nil;
      [operation cancel];
      return task;
    }
  }
  return nil;
}

- (AVURLAsset *)getNewAsset:(NSURL *)url urlString:(NSString *)urlString cacheKey:(NSString *)cacheKey cookies:(NSArray *)cookies {
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url
                                          options:@{
                                                    AVURLAssetHTTPCookiesKey:cookies,
                                                    AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)
                                                    }];
  [self.delegate addCompletionHandlerForAsset:asset completionHandler:^(BOOL playlistIsComplete, NSError *error){
    if(error) {
      NSLog(@"VideoDownloader: Error starting task for asset %@ with cache key %@: %@", urlString, cacheKey, error.localizedDescription);
      return;
    }
    if(!playlistIsComplete) {
      NSLog(@"VideoDownloader: Incomplete playlist for asset %@ with cache key %@", urlString, cacheKey);
      return;
    }
    NSArray *preferredMediaSelections = [NSArray arrayWithObjects:asset.preferredMediaSelection,nil];
    AVAggregateAssetDownloadTask *task = [self.session aggregateAssetDownloadTaskWithURLAsset:asset
                                                                              mediaSelections:preferredMediaSelections
                                                                                   assetTitle:@"Video Download"
                                                                             assetArtworkData:nil
                                                                                      options:nil];
    task.taskDescription = cacheKey;
    @synchronized(self.tasks) {
      self.tasks[cacheKey] = task;
    }
    [task resume];
    NSLog(@"VideoDownloader: Got new task %lu for asset %@ with cache key %@, suspending prefetch queue", (unsigned long)task.taskIdentifier, urlString, cacheKey);
  }];
  [asset.resourceLoader setDelegate:self.delegate queue:self.delegateQueue];
  asset.resourceLoader.preloadsEligibleContentKeys = YES;
  return asset;
}

- (void)getAsset:(NSURL *)originalUrl cacheKey:(NSString *)cacheKey cookies:(NSArray *)cookies completion:(void (^)(AVURLAsset *asset, NSError *))completion {
  dispatch_async(self.queue, ^{
    NSURL *url = originalUrl;
    NSURLComponents *urlComponents = [NSURLComponents componentsWithURL:originalUrl resolvingAgainstBaseURL:YES];
    if([urlComponents.path containsString:@".m3u8"]) {
      if([urlComponents.scheme isEqualToString:@"https"]) {
        urlComponents.scheme = @"rctvideohttps";
      } else if([urlComponents.scheme isEqualToString:@"http"]) {
        urlComponents.scheme = @"rctvideohttp";
      }
      url = urlComponents.URL;
    }
    NSString *urlString = [url absoluteString];
    AVURLAsset *validatedAsset;
    @synchronized(self.validatedAssets) {
      validatedAsset = self.validatedAssets[cacheKey];
    }
    if(validatedAsset) {
      NSLog(@"VideoDownloader: Found validated asset %@ with cache key %@", urlString, cacheKey);
      completion(validatedAsset, nil);
      return;
    }
    AVAggregateAssetDownloadTask *activeTask;
    @synchronized(self.tasks) {
      activeTask = self.tasks[cacheKey];
    }
    if(activeTask) {
      NSLog(@"VideoDownloader: Found active task %lu for asset %@ with cache key %@", (unsigned long)activeTask.taskIdentifier, urlString, cacheKey);
      [self validateAsset:activeTask.URLAsset cacheKey:cacheKey completion:^(AVURLAsset *asset, NSError *error){
        if(error) {
          NSLog(@"VideoDownloader: Active task %lu for %@ contains error: %@", (unsigned long)activeTask.taskIdentifier, urlString, error.localizedDescription);
          [self clearCachedAsset:cacheKey];
          AVURLAsset* asset = [self getNewAsset:url urlString:urlString cacheKey:cacheKey cookies:cookies];
          [self validateAsset:asset cacheKey:cacheKey completion:completion];
        } else {
          completion(asset, nil);
        }
      }];
      return;
    }
    
    AVAggregateAssetDownloadTask *prefetchTask = [self getPrefetchTask:cacheKey urlString: urlString];
    if(prefetchTask) {
      NSLog(@"VideoDownloader: Found prefetch task %lu for asset %@ with cache key %@", (unsigned long)prefetchTask.taskIdentifier, urlString, cacheKey);
      [self validateAsset:prefetchTask.URLAsset cacheKey:cacheKey completion:^(AVURLAsset *asset, NSError *error){
        if(error) {
          NSLog(@"VideoDownloader: Prefetch task for %@ contains error: %@", urlString, error.localizedDescription);
          [self clearCachedAsset:cacheKey];
          AVURLAsset* asset = [self getNewAsset:url urlString:urlString cacheKey:cacheKey cookies:cookies];
          [self validateAsset:asset cacheKey:cacheKey completion:completion];
        } else {
          completion(asset, nil);
        }
      }];
      return;
    }
  
    AVURLAsset *bookmarkedAsset = [self getBookmarkedAsset:urlString cacheKey:cacheKey];
    if(bookmarkedAsset) {
      NSLog(@"VideoDownloader: Found bookmark for asset %@ with cache key %@", urlString, cacheKey);
      [self validateAsset:bookmarkedAsset cacheKey:cacheKey completion:^(AVURLAsset *asset, NSError *error){
        if(error) {
          NSLog(@"VideoDownloader: Bookmark for %@ contains error: %@", urlString, error.localizedDescription);
          [self clearCachedAsset:cacheKey];
          AVURLAsset* asset = [self getNewAsset:url urlString:urlString cacheKey:cacheKey cookies:cookies];
          [self validateAsset:asset cacheKey:cacheKey completion:completion];
        } else {
          completion(asset, nil);
        }
      }];
      return;
    }

    
    AVURLAsset *asset = [self getNewAsset:url
                               urlString:urlString
                                cacheKey:cacheKey
                                 cookies:cookies];
    
    NSLog(@"VideoDownloader: Got new asset %@ with cache key %@", urlString, cacheKey);
    [self validateAsset:asset
            cacheKey:cacheKey
          completion:completion];
  });
}

- (void)prefetch:(NSString *)uri
        cacheKey:(NSString *)cacheKey
         cookies:(NSArray *)cookies
         resolve:(RCTPromiseResolveBlock)resolve
          reject:(RCTPromiseRejectBlock)reject {
#if !TARGET_IPHONE_SIMULATOR
  dispatch_async(self.queue, ^{
    if([self.cacheKeys containsObject: cacheKey]) {
      NSLog(@"VideoDownloader: Redundant cache download skipped for %@ with cache key %@", uri, cacheKey);
    } else if(![self hasCachedAsset:cacheKey]) {
      NSLog(@"VideoDownloader: Prefetch download started for %@ with cache key %@", uri, cacheKey);
      NSURL *url = [NSURL URLWithString:uri];
      NSURLComponents *urlComponents = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
      if([urlComponents.path containsString:@".m3u8"]) {
        if([urlComponents.scheme isEqualToString:@"https"]) {
          urlComponents.scheme = @"rctvideohttps";
        } else if([urlComponents.scheme isEqualToString:@"http"]) {
          urlComponents.scheme = @"rctvideohttp";
        }
        url = urlComponents.URL;
      }
      [self.cacheKeys addObject: cacheKey];
      DownloadSessionOperation *operation = [[DownloadSessionOperation alloc] initWithDelegate:self url:url cacheKey:cacheKey cookies:cookies queue:self.delegateQueue];
      [self.prefetchOperationQueue addOperation:operation];
    }
  });
#endif
  resolve(@{@"success":@YES});
}

- (void)URLSession:(NSURLSession *)session
didBecomeInvalidWithError:(NSError *)error {
  NSLog(@"VideoDownloader: didBecomeInvalidWithError");
}

- (void)URLSession:(NSURLSession *)session
taskIsWaitingForConnectivity:(NSURLSessionTask *)task {
  NSLog(@"VideoDownloader: taskIsWaitingForConnectivity");
}

- (void)URLSession:(NSURLSession *)session
 assetDownloadTask:(AVAssetDownloadTask *)assetDownloadTask
didFinishDownloadingToURL:(NSURL *)location {
  NSLog(@"VideoDownloader: didFinishDownloadingToURL");
}

- (void)URLSession:(NSURLSession *)session
aggregateAssetDownloadTask:(AVAggregateAssetDownloadTask *)aggregateAssetDownloadTask
didCompleteForMediaSelection:(AVMediaSelection *)mediaSelection {
  NSLog(@"VideoDownloader: didCompleteForMediaSelection");
  NSString* urlString = [aggregateAssetDownloadTask.URLAsset.URL absoluteString];
  NSString* cacheKey = aggregateAssetDownloadTask.taskDescription;
  if(!cacheKey) {
    NSLog(@"VideoDownloader: Missing cache key for task %lu asset %@ in didCompleteForMediaSelection", (unsigned long)aggregateAssetDownloadTask.taskIdentifier, urlString);
    return;
  }
  
  [aggregateAssetDownloadTask resume];
}

- (void)URLSession:(NSURLSession *)session
 assetDownloadTask:(AVAssetDownloadTask *)assetDownloadTask
didResolveMediaSelection:(AVMediaSelection *)resolvedMediaSelection {
  NSLog(@"VideoDownloader: didResolveMediaSelection");
}

- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler {
  NSLog(@"VideoDownloader: didReceiveChallenge");
}

- (void)URLSession:(NSURLSession *)session
aggregateAssetDownloadTask:(AVAggregateAssetDownloadTask *)aggregateAssetDownloadTask
 willDownloadToURL:(NSURL *)location {
  
  NSString* urlString = [aggregateAssetDownloadTask.URLAsset.URL absoluteString];
  NSString* cacheKey = aggregateAssetDownloadTask.taskDescription;
  if(!cacheKey) {
    NSLog(@"VideoDownloader: Missing cache key for task %lu asset %@ in willDownloadToURL", (unsigned long)aggregateAssetDownloadTask.taskIdentifier, urlString);
    return;
  }
  NSLog(@"VideoDownloader: Saving location for %@: %@", cacheKey, [location absoluteString]);
  self.downloadLocationUrls[cacheKey] = location;
}

-(void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
  AVAggregateAssetDownloadTask *assetDownloadTask = (AVAggregateAssetDownloadTask *)task;
  NSString* cacheKey = assetDownloadTask.taskDescription;
  NSString* urlString = [assetDownloadTask.URLAsset.URL absoluteString];
  if(!cacheKey) {
    NSLog(@"VideoDownloader: Missing cache key for task %lu, asset %@ in didCompleteWithError", (unsigned long)task.taskIdentifier, urlString);
    return;
  }
  for(DownloadSessionOperation *operation in self.prefetchOperationQueue.operations) {
    if([operation.cacheKey isEqualToString:cacheKey]) {
      [operation completeOperation];
      if(!self.validatedAssets[cacheKey]) {
        // Validate after prefetching
        // [self validateAsset:assetDownloadTask.URLAsset cacheKey:cacheKey completion:nil];
      }
    }
  }
  NSURL *location = self.downloadLocationUrls[cacheKey];
  [self.tasks removeObjectForKey:cacheKey];
  [self.downloadLocationUrls removeObjectForKey:cacheKey];
  if (error) {
    NSLog(@"VideoDownloader: Download error for task %lu, with code %ld, %@ for asset %@ with cache key %@", (unsigned long)task.taskIdentifier, (long)[error code], [error localizedDescription], urlString, cacheKey);
    if(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled && location) {
      [[NSFileManager defaultManager] removeItemAtURL:location error:nil];
    }
    if(assetDownloadTask.error) {
      NSLog(@"VideoDownloader: AVAggregateAssetDownloadTask error for task %lu, with code %ld, %@ for asset %@ with cache key %@", (unsigned long)task.taskIdentifier, (long)[assetDownloadTask.error code], [assetDownloadTask.error localizedDescription], urlString, cacheKey);
    }
    return;
  }
  if(location) {
    NSError *bookmarkError = nil;
    NSData *bookmarkData = [location bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
                              includingResourceValuesForKeys:nil
                                               relativeToURL:nil
                                                       error:&bookmarkError];
    if(bookmarkError) {
      NSLog(@"VideoDownloader: Bookmark error for task %lu, asset %@ with cache key %@: %@", (unsigned long)task.taskIdentifier, urlString, cacheKey, bookmarkError.localizedDescription);
      return;
    }
    [self.validatedAssets removeObjectForKey:cacheKey];
    NSLog(@"VideoDownloader: Bookmark saved for task %lu, asset %@ with cache key %@", (unsigned long)task.taskIdentifier, urlString, cacheKey);
    [[NSUserDefaults standardUserDefaults] setObject:bookmarkData forKey:cacheKey];
  } else {
    NSLog(@"VideoDownloader: Unable to save bookmark for task %lu, asset %@ with cache key %@", (unsigned long)task.taskIdentifier, urlString, cacheKey);
  }
}

- (void)pauseDownloads {
  if(self.suspended) {
    return;
  }
  NSLog(@"VideoDownloader: paused");
  self.suspended = YES;
  [self.prefetchOperationQueue setSuspended:YES];
  for(DownloadSessionOperation *operation in self.prefetchOperationQueue.operations) {
    if([operation isExecuting] && !operation.suspended) {
      [operation suspend];
    }
  }
}

- (void)resumeDownloads {
  if(!self.suspended) {
    return;
  }
  NSLog(@"VideoDownloader: resumed");
  self.suspended = NO;
  [self.prefetchOperationQueue setSuspended:NO];
  for(DownloadSessionOperation *operation in self.prefetchOperationQueue.operations) {
    if([operation isExecuting] && operation.suspended) {
      [operation resume];
    }
  }
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session
{
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"VideoDownloader: URLSessionDidFinishEventsForBackgroundURLSession");
    BackgroundDownloadAppDelegate *appDelegate = (BackgroundDownloadAppDelegate *)[[UIApplication sharedApplication] delegate];
    if (appDelegate.sessionCompletionHandlers && appDelegate.sessionCompletionHandlers[@"ReactNativeVideoDownloader"]) {
      void (^completionHandler)() = appDelegate.sessionCompletionHandlers[@"ReactNativeVideoDownloader"];
      [appDelegate.sessionCompletionHandlers removeObjectForKey:@"ReactNativeVideoDownloader"];
      completionHandler();
      [self resumeDownloads];
    }
  });
}

@end


