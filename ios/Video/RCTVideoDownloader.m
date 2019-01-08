#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <React/RCTBridge.h>
#import <React/RCTLog.h>
#import <Security/Security.h>
#import "RCTVideoDownloader.h"
#import "QueuedDownloadSession.h"
#import "BackgroundDownloadAppDelegate.h"
#import "RCTVideoDownloaderDelegate.h"

@interface MediaSelections : NSObject
@property (nonatomic, nullable) AVMediaSelectionGroup* group;
@property (nonatomic, nullable) AVMediaSelectionOption* option;
@end

@implementation MediaSelections

- (instancetype)initWithGroup:(AVMediaSelectionGroup*)group option:(AVMediaSelectionOption*)option {
  self = [super init];
  if (self) {
    self.group = group;
    self.option = option;
  }
  return self;
}

@end

@interface RCTVideoDownloader ()

@property (nonatomic, strong) RCTVideoDownloaderDelegate *downloaderDelegate;
@property (nonatomic, strong) NSMutableDictionary *mediaSelectionTasks;
@property (nonatomic, strong) NSMutableDictionary *tasks;
@property (nonatomic, strong) NSMutableDictionary *validatedAssets;
@property (nonatomic, strong) NSMutableDictionary *downloadLocationUrls;
@property (nonatomic, strong) NSOperationQueue *mainOperationQueue;
@property (nonatomic, strong) NSMutableSet *cacheKeys;
@property (nonatomic, assign) BOOL suspended;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation RCTVideoDownloader

- (instancetype)init
{
  self = [super init];
  if (self) {
    self.downloaderDelegate = [RCTVideoDownloaderDelegate sharedVideoDownloaderDelegate];
    self.mediaSelectionTasks = [[NSMutableDictionary alloc] init];
    self.tasks = [[NSMutableDictionary alloc] init];
    self.validatedAssets = [[NSMutableDictionary alloc] init];
    self.downloadLocationUrls = [[NSMutableDictionary alloc] init];
    NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:@"ReactNativeVideoDownloader"];
    sessionConfig.networkServiceType = NSURLNetworkServiceTypeVideo;
    sessionConfig.allowsCellularAccess = true;
    sessionConfig.sessionSendsLaunchEvents = true;
    sessionConfig.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
    sessionConfig.shouldUseExtendedBackgroundIdleMode = YES;
    sessionConfig.HTTPShouldUsePipelining = YES;
    self.session = [AVAssetDownloadURLSession sessionWithConfiguration:sessionConfig assetDownloadDelegate:self delegateQueue:nil];
    self.session.sessionDescription = @"ReactNativeVideoDownloader";
    self.mainOperationQueue = [[NSOperationQueue alloc] init];
    self.mainOperationQueue.maxConcurrentOperationCount = 1;
    self.suspended = NO;
    self.cacheKeys = [[NSMutableSet alloc] init];
    self.queue = dispatch_queue_create("Video Downloader Queue", DISPATCH_QUEUE_SERIAL);
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
  [self.mainOperationQueue cancelAllOperations];
  self.mainOperationQueue = nil;
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
  for(DownloadSessionOperation *operation in self.mainOperationQueue.operations) {
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
      AVURLAsset *asset = [AVURLAsset URLAssetWithURL:location options:@{AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
      [asset.resourceLoader setDelegate:self.downloaderDelegate queue:dispatch_get_main_queue()];
      asset.resourceLoader.preloadsEligibleContentKeys = YES;
      AVAssetCache* assetCache = asset.assetCache;
      if (assetCache) {
        return YES;
      } else {
        NSLog(@"VideoDownloader: Missing asset cache for %@", cacheKey);
      }
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
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:cacheKey];
}

- (void)checkAsset:(AVURLAsset *)asset cacheKey:(NSString *)cacheKey completion:(void (^)(AVURLAsset *, NSError *))completion {
  [asset loadValuesAsynchronouslyForKeys:@[@"duration"] completionHandler:^{
    @synchronized(self.tasks) {
      [self.tasks removeObjectForKey:cacheKey];
    }
    NSError *error = nil;
    AVKeyValueStatus status = [asset statusOfValueForKey:@"duration" error:&error];
    if(status == AVKeyValueStatusLoaded) {
      NSLog(@"VideoDownloader: Validated asset with cache key %@", cacheKey);
      @synchronized(self.validatedAssets) {
        self.validatedAssets[cacheKey] = asset;
      }
      completion(asset, nil);
      return;
    }
    if(error) {
      NSLog(@"VideoDownloader: Could not validate asset with cache key %@, %@", cacheKey, error.localizedDescription);
      completion(nil, error);
      return;
    }
    NSLog(@"VideoDownloader: Could not validate asset with cache key %@, status: %d", cacheKey, (int)status);
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: NSLocalizedString(@"Unable to load duration property", nil)};
    error = [NSError errorWithDomain:@"RCTVideoDownloader"
                                code:(int)status
                            userInfo:userInfo];
    completion(nil, error);
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
      [asset.resourceLoader setDelegate:self.downloaderDelegate queue:dispatch_get_main_queue()];
      asset.resourceLoader.preloadsEligibleContentKeys = YES;
      AVAssetCache* assetCache = asset.assetCache;
      if (assetCache) {
        NSLog(@"VideoDownloader: Found bookmark for cached asset %@ with cache key %@ at %@", urlString, cacheKey, [location absoluteString]);
        return asset;
      }
      NSLog(@"VideoDownloader: Found bookmark for cached asset %@ with cache key %@ at %@, has no asset cache", urlString, cacheKey, [location absoluteString]);
    }
  }
  return nil;
}

- (AVAggregateAssetDownloadTask *)getPrefetchTask:(NSString *)cacheKey urlString:(NSString *)urlString {
  for(DownloadSessionOperation *operation in self.mainOperationQueue.operations) {
    if(operation.task && [operation.cacheKey isEqualToString:cacheKey]) {
      NSLog(@"VideoDownloader: Got prefetch task %lu for asset %@ with cache key %@", (unsigned long)operation.task.taskIdentifier, urlString, cacheKey);
      return operation.task;
    }
  }
  return nil;
}

- (AVAggregateAssetDownloadTask *)getNewTask:(NSURL *)url urlString:(NSString *)urlString cacheKey:(NSString *)cacheKey cookies:(NSArray *)cookies {
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetHTTPCookiesKey:cookies, AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
  [asset.resourceLoader setDelegate:self.downloaderDelegate queue:dispatch_get_main_queue()];
  asset.resourceLoader.preloadsEligibleContentKeys = YES;
  NSArray *preferredMediaSelections = [NSArray arrayWithObjects:asset.preferredMediaSelection,nil];
  AVAggregateAssetDownloadTask *task = [self.session aggregateAssetDownloadTaskWithURLAsset:asset
                                                                            mediaSelections:preferredMediaSelections
                                                                                 assetTitle:@"Video Download"
                                                                           assetArtworkData:nil
                                                                                    options:nil];
  task.taskDescription = cacheKey;
  [task resume];
  @synchronized(self.tasks) {
    self.tasks[cacheKey] = task;
  }
  NSLog(@"VideoDownloader: Got new task %lu for asset %@ with cache key %@", (unsigned long)task.taskIdentifier, urlString, cacheKey);
  return task;
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
      [self checkAsset:activeTask.URLAsset cacheKey:cacheKey completion:^(AVURLAsset *asset, NSError *error){
        [activeTask cancel];
        if(error) {
          [[NSUserDefaults standardUserDefaults] removeObjectForKey:cacheKey];
          AVAggregateAssetDownloadTask *task = [self getNewTask:url urlString:urlString cacheKey:cacheKey cookies:cookies];
          [self checkAsset:task.URLAsset cacheKey:cacheKey completion:completion];
        } else {
          completion(asset, nil);
        }
      }];
      return;
    }
    AVAggregateAssetDownloadTask *prefetchTask = [self getPrefetchTask:cacheKey urlString: urlString];
    if(prefetchTask) {
      [self checkAsset:prefetchTask.URLAsset cacheKey:cacheKey completion:^(AVURLAsset *asset, NSError *error){
        [prefetchTask cancel];
        if(error) {
          [[NSUserDefaults standardUserDefaults] removeObjectForKey:cacheKey];
          AVAggregateAssetDownloadTask *task = [self getNewTask:url urlString:urlString cacheKey:cacheKey cookies:cookies];
          [self checkAsset:task.URLAsset cacheKey:cacheKey completion:completion];
        } else {
          completion(asset, nil);
        }
      }];
      return;
    }
    
    AVURLAsset *bookmarkedAsset = [self getBookmarkedAsset:urlString cacheKey:cacheKey];
    if(bookmarkedAsset) {
      [self checkAsset:bookmarkedAsset cacheKey:cacheKey completion:^(AVURLAsset *asset, NSError *error){
        if(error) {
          [[NSUserDefaults standardUserDefaults] removeObjectForKey:cacheKey];
          AVAggregateAssetDownloadTask *task = [self getNewTask:url urlString:urlString cacheKey:cacheKey cookies:cookies];
          [self checkAsset:task.URLAsset cacheKey:cacheKey completion:completion];
        } else {
          completion(asset, nil);
        }
      }];
      return;
    }
    
    AVAggregateAssetDownloadTask *task = [self getNewTask:url urlString:urlString cacheKey:cacheKey cookies:cookies];
    [self checkAsset:task.URLAsset cacheKey:cacheKey completion:completion];
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
      DownloadSessionOperation *operation = [[DownloadSessionOperation alloc] initWithDelegate:self url:url cacheKey:cacheKey cookies:cookies queue:dispatch_get_main_queue()];
      [self.mainOperationQueue addOperation:operation];
    }
  });
  
#endif
  
  resolve(@{@"success":@YES});
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
  NSLog(@"VideoDownloader: Saving location for %@", cacheKey);
  self.downloadLocationUrls[cacheKey] = location;
}

-(void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
  AVAggregateAssetDownloadTask *assetDownloadTask = (AVAggregateAssetDownloadTask *)task;
  NSString* cacheKey = assetDownloadTask.taskDescription;
  NSString* urlString = [assetDownloadTask.URLAsset.URL absoluteString];
  if(!cacheKey) {
    NSLog(@"VideoDownloader: Missing cache key for task %lu, asset %@ in didResolveMediaSelection", (unsigned long)task.taskIdentifier, urlString);
    return;
  }
  for(DownloadSessionOperation *operation in self.mainOperationQueue.operations) {
    if([operation.cacheKey isEqualToString:cacheKey]) {
      [operation completeOperation];
    }
  }
  if (error) {
    NSLog(@"VideoDownloader: Download error for task %lu, with code %ld, %@ for asset %@ with cache key %@", (unsigned long)task.taskIdentifier, (long)[error code], [error localizedDescription], urlString, cacheKey);
    [self.downloaderDelegate clearCacheForUrl:assetDownloadTask.URLAsset.URL];
    [self.downloadLocationUrls removeObjectForKey:cacheKey];
    return;
  }
  NSURL *location = self.downloadLocationUrls[cacheKey];
  [self.downloadLocationUrls removeObjectForKey:cacheKey];
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
    NSLog(@"VideoDownloader: Download saved for task %lu, asset %@ with cache key %@", (unsigned long)task.taskIdentifier, urlString, cacheKey);
    [[NSUserDefaults standardUserDefaults] setObject:bookmarkData forKey:cacheKey];
  } else {
    NSLog(@"VideoDownloader: Unable to save download for task %lu, asset %@ with cache key %@", (unsigned long)task.taskIdentifier, urlString, cacheKey);
  }
}

- (void)pauseDownloads {
  if(self.suspended) {
    return;
  }
  NSLog(@"VideoDownloader: paused");
  self.suspended = YES;
  self.mainOperationQueue.suspended = YES;
  for(DownloadSessionOperation *operation in self.mainOperationQueue.operations) {
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
  self.mainOperationQueue.suspended = NO;
  for(DownloadSessionOperation *operation in self.mainOperationQueue.operations) {
    if([operation isExecuting] && operation.suspended) {
      [operation resume];
    }
  }
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session
{
  dispatch_async(dispatch_get_main_queue(), ^{
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












