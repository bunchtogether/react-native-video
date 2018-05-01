#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <React/RCTLog.h>
#import <React/RCTBridge.h>
#import <Security/Security.h>

@interface MediaSelectionPair : NSObject
@property (nonatomic, nullable) AVMediaSelectionGroup* group;
@property (nonatomic, nullable) AVMediaSelectionOption* option;
@end

@implementation MediaSelectionPair

- (instancetype)initWithGroup:(AVMediaSelectionGroup*)group option:(AVMediaSelectionOption*)option {
  self = [super init];
  if (self) {
    self.group = group;
    self.option = option;
  }
  return self;
}

@end

@interface RCTVideoDownloader : NSObject <AVAssetDownloadDelegate> {
  AVAssetDownloadURLSession *avSession;
  AVAssetDownloadTask *lastTask;
  NSMutableDictionary *mediaSelection;
  NSMutableDictionary *tasks;
}
@end;

@implementation RCTVideoDownloader : NSObject

- (instancetype)init
{
  self = [super init];
  if (self) {
    mediaSelection = [[NSMutableDictionary alloc] init];
    tasks = [[NSMutableDictionary alloc] init];
  } else {
    RCTLogError(@"RCTVideoDownloader initialization failed.");
  }
  return self;
}

- (AVURLAsset *)getAsset:(NSURL *)url {
  NSString *path = url.path;
  NSData *bookmarkData = [[NSUserDefaults standardUserDefaults] objectForKey:path];
  if(bookmarkData) {
    NSError *error = nil;
    BOOL stale;
    NSURL *location = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                options:NSURLBookmarkResolutionWithoutUI
                                          relativeToURL:nil
                                    bookmarkDataIsStale:&stale
                                                  error:&error];
    if(error) {
      RCTLog(@"Error getting cached asset %@: %@", path, error);
    } else if(stale) {
      RCTLog(@"Cached asset is stale: %@", path);
    } else if(location) {
      RCTLog(@"Cache hit %@", path);
      AVURLAsset *asset = [AVURLAsset URLAssetWithURL:location options:nil];
      AVAssetCache *assetCache = [asset assetCache];
      if(assetCache) {
        if(assetCache.isPlayableOffline) {
          RCTLog(@"PlayableOffline!");
        } else {
          RCTLog(@"Not playableOffline.");
        }
        return asset;
      }
    }
  }
  /*
  AVAssetDownloadTask *existingTask = [tasks objectForKey:path];
  if(existingTask) {
    RCTLog(@"Found existing task for %@", path);
    return existingTask.URLAsset;
  }
  */
  if (avSession == nil) {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:@"downloadedMedia"];
    config.networkServiceType = NSURLNetworkServiceTypeVideo;
    config.allowsCellularAccess = true;
    config.sessionSendsLaunchEvents = true;
    config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
    avSession = [AVAssetDownloadURLSession sessionWithConfiguration:config assetDownloadDelegate:self delegateQueue:[NSOperationQueue mainQueue]];
  }
  RCTLog(@"Prefetching %@", path);
  NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetHTTPCookiesKey : cookies}];
  asset.resourceLoader.preloadsEligibleContentKeys = YES;
  AVAssetDownloadTask *task = [avSession assetDownloadTaskWithURLAsset:asset
                                                          assetTitle:@"Video Download"
                                                    assetArtworkData:nil
                                                             options:nil];
  task.taskDescription = path;
  //tasks[path] = task;
  [task resume];
  lastTask = task;
  return asset;
}

- (void)prefetch:(NSString *)uri
         resolve:(RCTPromiseResolveBlock)resolve
          reject:(RCTPromiseRejectBlock)reject {
  
  NSURL *url = [NSURL URLWithString:uri];
  NSString *path = url.path;
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:path];
  [self getAsset:url];
  
  resolve(@{@"success":@YES});
}

-(MediaSelectionPair*)nextMediaSelection:(AVURLAsset*)asset {
  AVAssetCache* assetCache = asset.assetCache;
  if (!assetCache) {
    return nil;
  }
  RCTLog(@"nextMediaSelection %s", assetCache.isPlayableOffline ? "YES" : "NO");
  NSArray* characteristics = @[AVMediaCharacteristicAudible, AVMediaCharacteristicLegible, AVMediaCharacteristicVisual];
  for (NSString* characteristic in characteristics) {
    AVMediaSelectionGroup *mediaSelectionGroup = [asset mediaSelectionGroupForMediaCharacteristic: characteristic];
    if (mediaSelectionGroup) {
      NSArray<AVMediaSelectionOption*>* savedOptions = [assetCache mediaSelectionOptionsInMediaSelectionGroup:mediaSelectionGroup];
      if (savedOptions.count < mediaSelectionGroup.options.count) {
        for (AVMediaSelectionOption* option in mediaSelectionGroup.options) {
          if (![savedOptions containsObject:option]) {
             RCTLog(@"new pair");
            return [[MediaSelectionPair alloc] initWithGroup:mediaSelectionGroup option:option];
          }
        }
      }
    }
  }
  return nil;
}

@end

@implementation RCTVideoDownloader (AssetDownload)

- (void)URLSession:(NSURLSession *)session assetDownloadTask:(AVAssetDownloadTask *)assetDownloadTask didFinishDownloadingToURL:(NSURL *)location {
  
  NSString* path = assetDownloadTask.taskDescription;
  
  NSError *error = nil;
  NSData *bookmarkData = [location bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
                            includingResourceValuesForKeys:nil
                                             relativeToURL:nil
                                                     error:&error];
  
  if(error) {
    RCTLogError(@"Bookmark failed for %@", path);
    //[tasks removeObjectForKey: path];
    return;
  }
  
  if (path != nil) {
    //[tasks removeObjectForKey: path];
    RCTLog(@"Download saved %@", path);
    [[NSUserDefaults standardUserDefaults] setObject:bookmarkData forKey:path];
    [[NSUserDefaults standardUserDefaults] synchronize];
  }
}

/*
-(void)URLSession:(NSURLSession *)session assetDownloadTask:(AVAssetDownloadTask *)assetDownloadTask didLoadTimeRange:(CMTimeRange)timeRange totalTimeRangesLoaded:(NSArray<NSValue *> *)loadedTimeRanges timeRangeExpectedToLoad:(CMTimeRange)timeRangeExpectedToLoad {
  RCTLog(@"DidLoadTimeRange: %lld (%lld); expected:  %lld",
         timeRange.start.value/timeRange.start.timescale, timeRange.duration.value/timeRange.duration.timescale,
         timeRangeExpectedToLoad.duration.value/timeRangeExpectedToLoad.duration.timescale);
}
 */

- (void)URLSession:(NSURLSession *)session assetDownloadTask:(AVAssetDownloadTask *)assetDownloadTask didResolveMediaSelection:(AVMediaSelection *)resolvedMediaSelection {
  mediaSelection[assetDownloadTask] = resolvedMediaSelection;
}

-(void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
  AVAssetDownloadTask *assetDownloadTask = (AVAssetDownloadTask *)task;
  NSString* path = assetDownloadTask.taskDescription;
  if (error) {
    RCTLog(@"Download error %@: %@", path, error);
    //[tasks removeObjectForKey: path];
    return;
  }
  MediaSelectionPair *pair = [self nextMediaSelection:assetDownloadTask.URLAsset];
  if (pair.group != nil) {
    AVMutableMediaSelection *originalMediaSelection = (AVMutableMediaSelection *)mediaSelection[assetDownloadTask];
    if (originalMediaSelection == nil) {
      return;
    } else {
      AVMutableMediaSelection *localMediaSelection = (AVMutableMediaSelection *)[originalMediaSelection mutableCopy];
      AVMediaSelectionOption *option = pair.option;
      AVMediaSelectionGroup *group = pair.group;
      if (option && group) {
        [localMediaSelection selectMediaOption: option inMediaSelectionGroup: group];
      }
      NSDictionary* downloadOptions = @{AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: @0, AVAssetDownloadTaskMediaSelectionKey: localMediaSelection};
      AVAssetDownloadTask *nextTask = [avSession assetDownloadTaskWithURLAsset: assetDownloadTask.URLAsset
                                                                  assetTitle:@"Video Download"
                                                            assetArtworkData:nil
                                                                     options:downloadOptions];
      if (nextTask == nil) {
        return;
      } else {
        RCTLog(@"Starting download of %@", option);
        nextTask.taskDescription = path;
        [nextTask resume];
      }
    }
  }
}

@end



