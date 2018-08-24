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

@property (nonatomic, strong) AVAssetDownloadURLSession *session;
@property (nonatomic, strong) NSMutableDictionary *mediaSelectionTasks;
@property (nonatomic, strong) NSOperationQueue *mainOperationQueue;
@property (nonatomic, strong) NSMutableSet *cacheKeys;
@property (nonatomic, assign) BOOL suspended;

@end

@implementation RCTVideoDownloader

- (instancetype)init
{
  self = [super init];
  if (self) {
    self.mediaSelectionTasks = [[NSMutableDictionary alloc] init];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:@"downloadedMedia"];
    config.networkServiceType = NSURLNetworkServiceTypeVideo;
    config.allowsCellularAccess = true;
    config.sessionSendsLaunchEvents = true;
    config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
    self.session = [AVAssetDownloadURLSession sessionWithConfiguration:config assetDownloadDelegate:self delegateQueue:nil];
    self.mainOperationQueue = [[NSOperationQueue alloc] init];
    self.mainOperationQueue.maxConcurrentOperationCount = 1;
    self.suspended = NO;
    self.cacheKeys = [[NSMutableSet alloc] init];
  } else {
    NSLog(@"RCTVideoDownloader initialization failed.");
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

- (BOOL)hasCachedAsset:(NSString *)cacheKey {
#if TARGET_IPHONE_SIMULATOR
  return NO;
#else
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
  RCTLog(@"Clearing %@", cacheKey);
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:cacheKey];
}

- (void)checkAsset:(AVURLAsset *)asset completion:(void (^)(AVURLAsset *, NSError *))completion {
  [asset loadValuesAsynchronouslyForKeys:@[@"duration"] completionHandler:^{
    NSError *error = nil;
    AVKeyValueStatus status = [asset statusOfValueForKey:@"duration" error:&error];
    if(status == AVKeyValueStatusLoaded) {
      completion(asset, nil);
      return;
    }
    if(error) {
      completion(nil, error);
      return;
    }
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: NSLocalizedString(@"Unable to load duration property", nil)};
    error = [NSError errorWithDomain:@"RCTVideoDownloader"
                                code:-1
                            userInfo:userInfo];
    completion(nil, error);
  }];
}

- (AVURLAsset *)getBookmarkedAsset:(NSString *)path cacheKey:(NSString *)cacheKey {
  NSData *bookmarkData = [[NSUserDefaults standardUserDefaults] objectForKey:cacheKey];
  if(bookmarkData) {
    NSLog(@"Found bookmark for asset %@ with key %@", path, cacheKey);
    NSError *error = nil;
    BOOL stale;
    NSURL *location = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                options:NSURLBookmarkResolutionWithoutUI
                                          relativeToURL:nil
                                    bookmarkDataIsStale:&stale
                                                  error:&error];
    if(error) {
      NSLog(@"Error getting cached asset %@ with key %@: %@", path, cacheKey, error);
    } else if(stale) {
      NSLog(@"Cached asset %@ with key  %@ is stale", path, cacheKey);
    } else if(location) {
      AVURLAsset *asset = [AVURLAsset URLAssetWithURL:location options:@{AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
      AVAssetCache* assetCache = asset.assetCache;
      if (assetCache) {
        NSLog(@"Cached hit for asset %@ with key %@", path, cacheKey);
        asset.resourceLoader.preloadsEligibleContentKeys = YES;
        return asset;
      }
    }
  }
  return nil;
}

- (AVURLAsset *)getNewAsset:(NSURL *)url path:(NSString *)path cacheKey:(NSString *)cacheKey {
  NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetHTTPCookiesKey : cookies, AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
  asset.resourceLoader.preloadsEligibleContentKeys = YES;
  AVAssetDownloadTask *task = [self.session assetDownloadTaskWithURLAsset:asset
                                                                 assetTitle:@"Video Download"
                                                           assetArtworkData:nil
                                                                    options:nil];
  task.taskDescription = cacheKey;
  [task resume];
  return asset;
}

- (void)getAsset:(NSURL *)url cacheKey:(NSString *)cacheKey completion:(void (^)(AVURLAsset *asset, NSError *))completion {
  /*
   NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
   AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetHTTPCookiesKey : cookies, AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
   return asset;
   */
  AVURLAsset *asset;
#if TARGET_IPHONE_SIMULATOR
  NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
  asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetHTTPCookiesKey : cookies, AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
  return [self checkAsset:asset completion:completion];
#else
  NSString *path = url.path;
  asset = [self getBookmarkedAsset:path cacheKey:cacheKey];
  if(asset) {
    [self checkAsset:asset completion:^(AVURLAsset *asset, NSError *error){
      if(error) {
        NSLog(@"Retrying, error for bookmarked asset with path %@ and key %@ - %@", path, cacheKey, error.localizedDescription);
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:cacheKey];
        asset = [self getNewAsset:url path:path cacheKey:cacheKey];
        [self checkAsset:asset completion:completion];
      } else {
        completion(asset, nil);
      }
    }];
    return;
  }
  asset = [self getNewAsset:url path:path cacheKey:cacheKey];
  [self checkAsset:asset completion:completion];
#endif
}

- (void)prefetch:(NSString *)uri
        cacheKey:(NSString *)cacheKey
         resolve:(RCTPromiseResolveBlock)resolve
          reject:(RCTPromiseRejectBlock)reject {
  NSURL *url = [NSURL URLWithString:uri];
  if([self.cacheKeys containsObject: uri]) {
    NSLog(@"Redundant cache download skipped for %@", cacheKey);
  } else {
    [self.cacheKeys addObject: uri];
    DownloadSessionOperation *operation = [[DownloadSessionOperation alloc] initWithSession:self.session url:url cacheKey:cacheKey];
    [self.mainOperationQueue addOperation:operation];
  }
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
    NSLog(@"Missing cache key for asset %@ in didFinishDownloadingToURL", path);
    return;
  }
  AVURLAsset *asset = assetDownloadTask.URLAsset;
  AVAssetCache* assetCache = asset.assetCache;
  if (!assetCache) {
    NSLog(@"No asset cache for %@ %@", path, cacheKey);
    return;
  }
  NSError *error = nil;
  NSData *bookmarkData = [location bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
                            includingResourceValuesForKeys:nil
                                             relativeToURL:nil
                                                     error:&error];
  if(error) {
    NSLog(@"Bookmark error for asset %@ with key %@", path, cacheKey);
    return;
  }
  NSLog(@"Download saved for asset %@ with key %@", path, cacheKey);
  [[NSUserDefaults standardUserDefaults] setObject:bookmarkData forKey:cacheKey];
}

- (void)URLSession:(NSURLSession *)session assetDownloadTask:(AVAssetDownloadTask *)assetDownloadTask didResolveMediaSelection:(AVMediaSelection *)resolvedMediaSelection {
  @synchronized(self) {
    self.mediaSelectionTasks[assetDownloadTask] = resolvedMediaSelection;
  }
}

-(void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
  AVAssetDownloadTask *assetDownloadTask = (AVAssetDownloadTask *)task;
  NSString* cacheKey = assetDownloadTask.taskDescription;
  NSString* path = assetDownloadTask.URLAsset.URL.path;
  if(!cacheKey) {
    NSLog(@"Missing cache key for asset %@ in didResolveMediaSelection", path);
    return;
  }
  for(DownloadSessionOperation *operation in self.mainOperationQueue.operations) {
    if(operation.cacheKey == cacheKey) {
      [operation completeOperation];
    }
  }
  if (error) {
    NSLog(@"Download error %ld, %@ for asset %@ with key %@: %@", [error code], [error localizedDescription], path, cacheKey, error);
    @synchronized(self) {
      [[NSUserDefaults standardUserDefaults] removeObjectForKey:cacheKey];
    }
    return;
  }
  MediaSelections *selections = [self nextMediaSelection:assetDownloadTask.URLAsset];
  if (selections.group != nil) {
    @synchronized(self) {
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
        AVAssetDownloadTask *nextTask = [self.session assetDownloadTaskWithURLAsset:assetDownloadTask.URLAsset
                               assetTitle:@"Video Download"
                         assetArtworkData:nil
                                  options:downloadOptions];
        if (nextTask == nil) {
          return;
        } else {
          NSLog(@"Starting download of %@", option);
          [nextTask resume];
        }
      }
    }
  }
}

- (void)pauseDownloads {
  if(self.suspended) {
    return;
  }
  NSLog(@"Downloader: pause");
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
  NSLog(@"Downloader: resume");
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
    if (appDelegate.sessionCompletionHandler) {
      void (^completionHandler)() = appDelegate.sessionCompletionHandler;
      appDelegate.sessionCompletionHandler = nil;
      completionHandler();
      [self resumeDownloads];
    }
  });
}

@end






