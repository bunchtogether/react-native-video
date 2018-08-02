#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <React/RCTBridge.h>
#import <React/RCTLog.h>
#import <Security/Security.h>
#import "RCTVideoDownloader.h"

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

@property (nonatomic, strong) AVAssetDownloadURLSession *avSession;
@property (nonatomic, strong) NSMutableDictionary *mediaSelectionTasks;
@property (nonatomic, strong) NSMutableDictionary *resolves;
@property (nonatomic, strong) NSMutableDictionary *rejects;
@property (nonatomic, strong) NSMutableDictionary *tasks;

@end

@implementation RCTVideoDownloader

- (instancetype)init
{
  self = [super init];
  if (self) {
    self.mediaSelectionTasks = [[NSMutableDictionary alloc] init];
    self.resolves = [[NSMutableDictionary alloc] init];
    self.rejects = [[NSMutableDictionary alloc] init];
    self.tasks = [[NSMutableDictionary alloc] init];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:@"downloadedMedia"];
    config.networkServiceType = NSURLNetworkServiceTypeVideo;
    config.allowsCellularAccess = true;
    config.sessionSendsLaunchEvents = true;
    config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
    self.avSession = [AVAssetDownloadURLSession sessionWithConfiguration:config assetDownloadDelegate:self delegateQueue:nil];
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
  @synchronized(self) {
    AVAssetDownloadTask *existingTask = [self.tasks objectForKey:cacheKey];
    if(existingTask) {
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
  RCTLog(@"Clearing %@", cacheKey);
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:cacheKey];
}

- (AVURLAsset *)getAsset:(NSURL *)url cacheKey:(NSString *)cacheKey {
  /*
   NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
   AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetHTTPCookiesKey : cookies, AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
   return asset;
   */
#if TARGET_IPHONE_SIMULATOR
  NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetHTTPCookiesKey : cookies, AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
  return asset;
#else
  NSString *path = url.path;
  @synchronized(self) {
    AVAssetDownloadTask *existingTask = [self.tasks objectForKey:cacheKey];
    if(existingTask && CMTimeGetSeconds(existingTask.URLAsset.duration) > 0) {
      NSLog(@"Found existing task for asset %@ with key %@", path, cacheKey);
      return existingTask.URLAsset;
    }
  }
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
      if (assetCache && CMTimeGetSeconds(asset.duration) > 0) {
        NSLog(@"Cached hit for asset %@ with key %@", path, cacheKey);
        asset.resourceLoader.preloadsEligibleContentKeys = YES;
        AVAssetDownloadTask *task = [self.avSession assetDownloadTaskWithURLAsset:asset
                                                                       assetTitle:@"Video Download"
                                                                 assetArtworkData:nil
                                                                          options:nil];
        task.taskDescription = cacheKey;
        @synchronized(self) {
          self.tasks[cacheKey] = task;
          [task resume];
          RCTPromiseResolveBlock resolve = [self.resolves objectForKey:cacheKey];
          if(resolve) {
            [self.resolves removeObjectForKey:cacheKey];
            [self.rejects removeObjectForKey:cacheKey];
            resolve(@{@"success":@YES, @"status": @"cached"});
          }
        }
        return asset;
      }
    }
  }
  NSLog(@"Prefetching asset %@ with key %@", path, cacheKey);
  NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetHTTPCookiesKey : cookies, AVURLAssetReferenceRestrictionsKey: @(AVAssetReferenceRestrictionForbidNone)}];
  asset.resourceLoader.preloadsEligibleContentKeys = YES;
  AVAssetDownloadTask *task = [self.avSession assetDownloadTaskWithURLAsset:asset
                                                                 assetTitle:@"Video Download"
                                                           assetArtworkData:nil
                                                                    options:nil];
  task.taskDescription = cacheKey;
  @synchronized(self) {
    self.tasks[cacheKey] = task;
  }
  [task resume];
  return asset;
#endif
}

- (void)prefetch:(NSString *)uri
        cacheKey:(NSString *)cacheKey
         resolve:(RCTPromiseResolveBlock)resolve
          reject:(RCTPromiseRejectBlock)reject {
#if !(TARGET_IPHONE_SIMULATOR)
  NSURL *url = [NSURL URLWithString:uri];
  [self getAsset:url cacheKey:cacheKey];
  @synchronized(self) {
    self.resolves[cacheKey] = resolve;
    self.rejects[cacheKey] = reject;
  }
#else
  resolve(@{@"success":@YES});
#endif
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
    @synchronized(self) {
      RCTPromiseRejectBlock reject = [self.rejects objectForKey:cacheKey];
      if(reject) {
        [self.resolves removeObjectForKey:cacheKey];
        [self.rejects removeObjectForKey:cacheKey];
        [self.tasks removeObjectForKey:cacheKey];
        reject(@"precache_error", @"No assset cache", nil);
      }
    }
    return;
  }
  NSError *error = nil;
  NSData *bookmarkData = [location bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
                            includingResourceValuesForKeys:nil
                                             relativeToURL:nil
                                                     error:&error];
  if(error) {
    NSLog(@"Bookmark error for asset %@ with key %@", path, cacheKey);
    @synchronized(self) {
      RCTPromiseRejectBlock reject = [self.rejects objectForKey:cacheKey];
      if(reject) {
        [self.resolves removeObjectForKey:cacheKey];
        [self.rejects removeObjectForKey:cacheKey];
        [self.tasks removeObjectForKey:cacheKey];
        reject(@"precache_error", @"Bookmark error", nil);
      }
    }
    return;
  }
  @synchronized(self) {
    RCTPromiseResolveBlock resolve = [self.resolves objectForKey:cacheKey];
    if(resolve) {
      [self.resolves removeObjectForKey:cacheKey];
      [self.rejects removeObjectForKey:cacheKey];
      resolve(@{@"success":@YES, @"status": @"saved"});
    }
  }
  NSLog(@"Download saved for asset %@ with key %@", path, cacheKey);
  [[NSUserDefaults standardUserDefaults] setObject:bookmarkData forKey:cacheKey];
  [[NSUserDefaults standardUserDefaults] synchronize];
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
  if (error) {
    NSLog(@"Download error %ld, %@ for asset %@ with key %@: %@", [error code], [error localizedDescription], path, cacheKey, error);
    @synchronized(self) {
      [self.tasks removeObjectForKey:cacheKey];
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
        AVAssetDownloadTask *nextTask = [self.avSession assetDownloadTaskWithURLAsset:assetDownloadTask.URLAsset
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

@end






