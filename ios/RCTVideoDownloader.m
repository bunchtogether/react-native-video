#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <React/RCTLog.h>
#import <React/RCTBridge.h>

@interface RCTVideoDownloader : NSObject <AVAssetDownloadDelegate> {
    AVAssetDownloadURLSession *session;
    AVAssetDownloadTask *lastTask;
}
@end;

@implementation RCTVideoDownloader : NSObject

- (instancetype)init
{
    self = [super init];
    if (self) {
        NSLog(@"Initializing RCTVideoDownloader");
    } else {
        NSLog(@"RCTVideoDownloader initialization failed.");
    }
    return self;
}

- (AVURLAsset *)getAsset:(NSURL *)url {
    if (session == nil) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:@"downloadedMedia"];
        config.networkServiceType = NSURLNetworkServiceTypeVideo;
        config.allowsCellularAccess = true;
        config.sessionSendsLaunchEvents = true;
        session = [AVAssetDownloadURLSession sessionWithConfiguration:config assetDownloadDelegate:self delegateQueue:[NSOperationQueue mainQueue]];
    }
    NSString *path = url.path;
    NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetHTTPCookiesKey : cookies}];
    AVAssetDownloadTask *task = [session assetDownloadTaskWithURLAsset:asset
                                                            assetTitle:path
                                                      assetArtworkData:nil
                                                               options:@{AVAssetDownloadTaskMinimumRequiredMediaBitrateKey : @0}];
    [task resume];
    lastTask = task;
    return asset;
}

- (void)prefetch:(NSString *)uri
        resolve:(RCTPromiseResolveBlock)resolve
        reject:(RCTPromiseRejectBlock)reject {

    RCTLog(@"Prefetching %@", uri);
    
    [self getAsset:[NSURL URLWithString:uri]];
    
    resolve(@{@"success":@YES});
}


- (void)URLSession:(NSURLSession *)session assetDownloadTask:(AVAssetDownloadTask *)assetDownloadTask didFinishDownloadingToURL:(NSURL *)location;
{
    NSError *error = nil;
    NSData *bookmarkData = [location bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
                              includingResourceValuesForKeys:nil
                                               relativeToURL:nil
                                                       error:&error];
    if(error) {
        NSLog(@"%s: %@", __func__, error);
        return;
    }
    NSLog(@"Downloaded %@", assetDownloadTask.URLAsset.URL);
    //[[NSUserDefaults standardUserDefaults] setObject:bookmarkData forKey:key];
}

- (void)URLSession:(NSURLSession *)session assetDownloadTask:(AVAssetDownloadTask *)assetDownloadTask didLoadTimeRange:(CMTimeRange)timeRange totalTimeRangesLoaded:(NSArray<NSValue *> *)loadedTimeRanges timeRangeExpectedToLoad:(CMTimeRange)timeRangeExpectedToLoad {
    {
        NSLog(@"Loaded");
    }
}

- (void)URLSession:(NSURLSession *)session assetDownloadTask:(AVAssetDownloadTask *)assetDownloadTask didResolveMediaSelection:(AVMediaSelection *)resolvedMediaSelection {
    NSLog(@"Resolved");
}

@end

