#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <React/RCTBridge.h>
#import <React/RCTLog.h>
#import <Security/Security.h>
#import "RCTVideoDownloader.h"
#import "QueuedDownloadSession.h"
#import "BackgroundDownloadAppDelegate.h"

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

@property (nonatomic, strong) NSMutableDictionary *mediaSelectionTasks;
@property (nonatomic, strong) NSMutableDictionary *tasks;
@property (nonatomic, strong) NSMutableDictionary *validatedAssets;
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
    self.mediaSelectionTasks = [[NSMutableDictionary alloc] init];
    self.tasks = [[NSMutableDictionary alloc] init];
    self.validatedAssets = [[NSMutableDictionary alloc] init];
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
    AVAssetDownloadTask *activeTask = self.tasks[cacheKey];
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
      AVAssetCache* assetCache = asset.assetCache;
      if (assetCache) {
        return YES;
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
    AVAssetDownloadTask *activeTask = self.tasks[cacheKey];
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
      NSLog(@"VideoDownloader: Validated asset with key %@", cacheKey);
      @synchronized(self.validatedAssets) {
        self.validatedAssets[cacheKey] = asset;
      }
      completion(asset, nil);
      return;
    }
    if(error) {
      NSLog(@"VideoDownloader: Could not validate asset with key %@, %@", cacheKey, error.localizedDescription);
      completion(nil, error);
      return;
    }
    NSLog(@"VideoDownloader: Could not validate asset with key %@, status: %d", cacheKey, (int)status);
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: NSLocalizedString(@"Unable to load duration property", nil)};
    error = [NSError errorWithDomain:@"RCTVideoDownloader"
                                code:(int)status
                            userInfo:userInfo];
    completion(nil, error);
  }];
}

- (AVURLAsset *)getBookmarkedAsset:(NSString *)path cacheKey:(NSString *)cacheKey {
  NSData *bookmarkData = [[NSUserDefaults standardUserDefaults] objectForKey:cacheKey];
  if(bookmarkData) {
    NSLog(@"VideoDownloader: Found bookmark for cached asset %@ with key %@", path, cacheKey);
    NSError *error = nil;
    BOOL stale;
    NSURL *location = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                options:NSURLBookmarkResolutionWithoutUI
                                          relativeToURL:nil
                                    bookmarkDataIsStale:&stale
                                                  error:&error];
    if(error) {
      NSLog(@"VideoDownloader: Error getting cached asset %@ with key %@: %@", path, cacheKey, error);
    } else if(stale) {
      NSLog(@"VideoDownloader: Cached asset %@ with key %@ is stale", path, cacheKey);
    } else if(location) {
      AVURLAsset *asset = [AVURLAsset URLAssetWithURL:location options:@{AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
      AVAssetCache* assetCache = asset.assetCache;
      if (assetCache) {
        return asset;
      }
      NSLog(@"VideoDownloader: Cached asset %@ with key %@ has no asset cache", path, cacheKey);
    }
  }
  return nil;
}

- (AVAssetDownloadTask *)getPrefetchTask:(NSString *)cacheKey path:(NSString *)path {
  for(DownloadSessionOperation *operation in self.mainOperationQueue.operations) {
    if(operation.task && [operation.cacheKey isEqualToString:cacheKey]) {
      NSLog(@"VideoDownloader: Got prefetch task %lu for asset %@ with key %@", (unsigned long)operation.task.taskIdentifier, path, cacheKey);
      return operation.task;
    }
  }
  return nil;
}

- (AVAssetDownloadTask *)getNewTask:(NSURL *)url path:(NSString *)path cacheKey:(NSString *)cacheKey cookies:(NSArray *)cookies {
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetHTTPCookiesKey : cookies, AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
  asset.resourceLoader.preloadsEligibleContentKeys = YES;
  AVAssetDownloadTask *task = [self.session assetDownloadTaskWithURLAsset:asset
                                                               assetTitle:@"Video Download"
                                                         assetArtworkData:nil
                                                                  options:nil];
  task.taskDescription = cacheKey;
  [task resume];
  @synchronized(self.tasks) {
    self.tasks[cacheKey] = task;
  }
  NSLog(@"VideoDownloader: Got new task %lu for asset %@ with key %@", (unsigned long)task.taskIdentifier, path, cacheKey);
  return task;
}

- (void)getAsset:(NSURL *)url cacheKey:(NSString *)cacheKey cookies:(NSArray *)cookies completion:(void (^)(AVURLAsset *asset, NSError *))completion {
  dispatch_async(self.queue, ^{
    NSString *path = url.path;
    AVURLAsset *validatedAsset;
    @synchronized(self.validatedAssets) {
      validatedAsset = self.validatedAssets[cacheKey];
    }
    if(validatedAsset) {
      NSLog(@"VideoDownloader: Found validated asset %@ with key %@", path, cacheKey);
      completion(validatedAsset, nil);
      return;
    }
    AVAssetDownloadTask *activeTask;
    @synchronized(self.tasks) {
      activeTask = self.tasks[cacheKey];
    }
    if(activeTask) {
      [self checkAsset:activeTask.URLAsset cacheKey:cacheKey completion:^(AVURLAsset *asset, NSError *error){
        [activeTask cancel];
        if(error) {
          [[NSUserDefaults standardUserDefaults] removeObjectForKey:cacheKey];
          AVAssetDownloadTask *task = [self getNewTask:url path:path cacheKey:cacheKey cookies:cookies];
          [self checkAsset:task.URLAsset cacheKey:cacheKey completion:completion];
        } else {
          completion(asset, nil);
        }
      }];
      return;
    }
    AVAssetDownloadTask *prefetchTask = [self getPrefetchTask:cacheKey path: path];
    if(prefetchTask) {
      [self checkAsset:prefetchTask.URLAsset cacheKey:cacheKey completion:^(AVURLAsset *asset, NSError *error){
        [prefetchTask cancel];
        if(error) {
          [[NSUserDefaults standardUserDefaults] removeObjectForKey:cacheKey];
          AVAssetDownloadTask *task = [self getNewTask:url path:path cacheKey:cacheKey cookies:cookies];
          [self checkAsset:task.URLAsset cacheKey:cacheKey completion:completion];
        } else {
          completion(asset, nil);
        }
      }];
      return;
    }
    AVURLAsset *bookmarkedAsset = [self getBookmarkedAsset:path cacheKey:cacheKey];
    if(bookmarkedAsset) {
      [self checkAsset:bookmarkedAsset cacheKey:cacheKey completion:^(AVURLAsset *asset, NSError *error){
        if(error) {
          [[NSUserDefaults standardUserDefaults] removeObjectForKey:cacheKey];
          AVAssetDownloadTask *task = [self getNewTask:url path:path cacheKey:cacheKey cookies:cookies];
          [self checkAsset:task.URLAsset cacheKey:cacheKey completion:completion];
        } else {
          completion(asset, nil);
        }
      }];
      return;
    }
    AVAssetDownloadTask *task = [self getNewTask:url path:path cacheKey:cacheKey cookies:cookies];
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
    NSURL *url = [NSURL URLWithString:uri];
    if([self.cacheKeys containsObject: cacheKey]) {
      NSLog(@"VideoDownloader: Redundant cache download skipped for %@", cacheKey);
    } else if(![self hasCachedAsset:cacheKey]) {
      [self.cacheKeys addObject: cacheKey];
      DownloadSessionOperation *operation = [[DownloadSessionOperation alloc] initWithDelegate:self url:url cacheKey:cacheKey cookies:cookies];
      [self.mainOperationQueue addOperation:operation];
    }
  });
  
#endif
  resolve(@{@"success":@YES});
}

-(MediaSelections*)nextMediaSelection:(AVURLAsset*)asset {
  AVAssetCache* assetCache = asset.assetCache;
  if (!assetCache) {
    return nil;
  }
  NSArray* characteristics = @[AVMediaCharacteristicAudible, AVMediaCharacteristicLegible, AVMediaCharacteristicVisual];
  for (NSString* characteristic in characteristics) {
    AVMediaSelectionGroup *mediaSelectionGroup = [asset mediaSelectionGroupForMediaCharacteristic: characteristic];
    if (mediaSelectionGroup) {
      NSArray<AVMediaSelectionOption*>* options = [assetCache mediaSelectionOptionsInMediaSelectionGroup:mediaSelectionGroup];
      if (options.count < mediaSelectionGroup.options.count) {
        for (AVMediaSelectionOption* option in mediaSelectionGroup.options) {
          if (![options containsObject:option]) {
            return [[MediaSelections alloc] initWithGroup:mediaSelectionGroup option:option];
          }
        }
      }
    }
  }
  return nil;
}

- (void)URLSession:(NSURLSession *)session assetDownloadTask:(AVAssetDownloadTask *)assetDownloadTask didFinishDownloadingToURL:(NSURL *)location {
  NSString* path = assetDownloadTask.URLAsset.URL.path;
  NSString* cacheKey = assetDownloadTask.taskDescription;
  if(!cacheKey) {
    NSLog(@"VideoDownloader: Missing cache key for task %lu asset %@ in didFinishDownloadingToURL", (unsigned long)assetDownloadTask.taskIdentifier, path);
    return;
  }
  AVURLAsset *asset = assetDownloadTask.URLAsset;
  AVAssetCache* assetCache = asset.assetCache;
  if (!assetCache) {
    NSLog(@"VideoDownloader: No asset cache for task %lu, asset %@ with key %@", (unsigned long)assetDownloadTask.taskIdentifier, path, cacheKey);
    return;
  }
  NSError *error = nil;
  NSData *bookmarkData = [location bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
                            includingResourceValuesForKeys:nil
                                             relativeToURL:nil
                                                     error:&error];
  if(error) {
    NSLog(@"VideoDownloader: Bookmark error for task %lu, asset %@ with key %@", (unsigned long)assetDownloadTask.taskIdentifier, path, cacheKey);
    return;
  }
  NSLog(@"VideoDownloader: Download saved for task %lu, asset %@ with key %@", (unsigned long)assetDownloadTask.taskIdentifier, path, cacheKey);
  [[NSUserDefaults standardUserDefaults] setObject:bookmarkData forKey:cacheKey];
}

- (void)URLSession:(NSURLSession *)session assetDownloadTask:(AVAssetDownloadTask *)assetDownloadTask didResolveMediaSelection:(AVMediaSelection *)resolvedMediaSelection {
  self.mediaSelectionTasks[assetDownloadTask] = resolvedMediaSelection;
}

-(void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
  AVAssetDownloadTask *assetDownloadTask = (AVAssetDownloadTask *)task;
  NSString* cacheKey = assetDownloadTask.taskDescription;
  NSString* path = assetDownloadTask.URLAsset.URL.path;
  if(!cacheKey) {
    NSLog(@"VideoDownloader: Missing cache key for task %lu, asset %@ in didResolveMediaSelection", (unsigned long)task.taskIdentifier, path);
    return;
  }
  for(DownloadSessionOperation *operation in self.mainOperationQueue.operations) {
    if([operation.cacheKey isEqualToString:cacheKey]) {
      [operation completeOperation];
    }
  }
  if (error) {
    NSLog(@"VideoDownloader: Download error for task %lu, with code %ld, %@ for asset %@ with key %@", (unsigned long)task.taskIdentifier, (long)[error code], [error localizedDescription], path, cacheKey);
    return;
  }
  MediaSelections *selections = [self nextMediaSelection:assetDownloadTask.URLAsset];
  if (selections.group != nil) {
    AVMutableMediaSelection *originalMediaSelection = (AVMutableMediaSelection *)self.mediaSelectionTasks[assetDownloadTask];
    if (originalMediaSelection == nil) {
      return;
    } else {
      AVMutableMediaSelection *localMediaSelection = (AVMutableMediaSelection *)[originalMediaSelection mutableCopy];
      AVMediaSelectionOption *option = selections.option;
      AVMediaSelectionGroup *group = selections.group;
      if (option && group) {
        [localMediaSelection selectMediaOption: option inMediaSelectionGroup: group];
      }
      NSDictionary* downloadOptions = @{AVAssetDownloadTaskMediaSelectionKey: localMediaSelection};
      AVAssetDownloadURLSession *assetDownloadURLSession = (AVAssetDownloadURLSession *)session;
      AVAssetDownloadTask *nextTask = [assetDownloadURLSession assetDownloadTaskWithURLAsset:assetDownloadTask.URLAsset
                                                                                  assetTitle:@"Video Download"
                                                                            assetArtworkData:nil
                                                                                     options:downloadOptions];
      if (nextTask == nil) {
        return;
      } else {
        NSLog(@"VideoDownloader: Starting download of %@", option);
        [nextTask resume];
      }
    }
    
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










