#import "RCTVideoManager.h"
#import "RCTVideoDownloader.h"
#import "RCTVideo.h"
#import <React/RCTBridge.h>
#import <AVFoundation/AVFoundation.h>

@implementation RCTVideoManager

RCT_EXPORT_MODULE();

@synthesize bridge = _bridge;

- (UIView *)view
{
    return [[RCTVideo alloc] initWithEventDispatcherAndDownloader:self.bridge.eventDispatcher];
}

RCT_EXPORT_METHOD(prefetch:(NSString *)uri
                  cacheKey:(NSString *)cacheKey
                  cookies:(NSArray *)cookieArray
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    if(cookieArray && [cookieArray count] > 0) {
        for (NSDictionary *cookieObject in cookieArray) {
            NSString *domain = cookieObject[@"domain"];
            NSString *path = cookieObject[@"path"];
            if(path == nil) {
                path = @"/";
            }
            NSString *name = cookieObject[@"name"];
            NSString *value = cookieObject[@"value"];
            NSDictionary *properties = [NSDictionary dictionaryWithObjectsAndKeys:
                                        domain, NSHTTPCookieDomain,
                                        path, NSHTTPCookiePath,
                                        name, NSHTTPCookieName,
                                        value, NSHTTPCookieValue,
                                        nil];
            NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:properties];
            [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookie:cookie];
        }
    }
    NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
    NSLog(@"Prefetch cookies: %@", cookies);
    [[RCTVideoDownloader sharedVideoDownloader] prefetch:uri cacheKey:cacheKey cookies:cookies resolve:resolve reject:reject];
}
RCT_EXPORT_VIEW_PROPERTY(src, NSDictionary);
RCT_EXPORT_VIEW_PROPERTY(resizeMode, NSString);
RCT_EXPORT_VIEW_PROPERTY(repeat, BOOL);
RCT_EXPORT_VIEW_PROPERTY(allowsExternalPlayback, BOOL);
RCT_EXPORT_VIEW_PROPERTY(textTracks, NSArray);
RCT_EXPORT_VIEW_PROPERTY(selectedTextTrack, NSDictionary);
RCT_EXPORT_VIEW_PROPERTY(selectedAudioTrack, NSDictionary);
RCT_EXPORT_VIEW_PROPERTY(paused, BOOL);
RCT_EXPORT_VIEW_PROPERTY(muted, BOOL);
RCT_EXPORT_VIEW_PROPERTY(controls, BOOL);
RCT_EXPORT_VIEW_PROPERTY(volume, float);
RCT_EXPORT_VIEW_PROPERTY(playInBackground, BOOL);
RCT_EXPORT_VIEW_PROPERTY(playWhenInactive, BOOL);
RCT_EXPORT_VIEW_PROPERTY(ignoreSilentSwitch, NSString);
RCT_EXPORT_VIEW_PROPERTY(rate, float);
RCT_EXPORT_VIEW_PROPERTY(seek, NSDictionary);
RCT_EXPORT_VIEW_PROPERTY(currentTime, float);
RCT_EXPORT_VIEW_PROPERTY(fullscreen, BOOL);
RCT_EXPORT_VIEW_PROPERTY(progressUpdateInterval, float);
/* Should support: onLoadStart, onLoad, and onError to stay consistent with Image */
RCT_EXPORT_VIEW_PROPERTY(onVideoLoadStart, RCTBubblingEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onVideoLoad, RCTBubblingEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onVideoBuffer, RCTBubblingEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onVideoError, RCTBubblingEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onVideoProgress, RCTBubblingEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onVideoSeek, RCTBubblingEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onVideoEnd, RCTBubblingEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onTimedMetadata, RCTBubblingEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onVideoAudioBecomingNoisy, RCTBubblingEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onVideoFullscreenPlayerWillPresent, RCTBubblingEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onVideoFullscreenPlayerDidPresent, RCTBubblingEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onVideoFullscreenPlayerWillDismiss, RCTBubblingEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onVideoFullscreenPlayerDidDismiss, RCTBubblingEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onReadyForDisplay, RCTBubblingEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onPlaybackStalled, RCTBubblingEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onPlaybackResume, RCTBubblingEventBlock);
RCT_EXPORT_VIEW_PROPERTY(onPlaybackRateChange, RCTBubblingEventBlock);

- (NSDictionary *)constantsToExport
{
    return @{
             @"ScaleNone": AVLayerVideoGravityResizeAspect,
             @"ScaleToFill": AVLayerVideoGravityResize,
             @"ScaleAspectFit": AVLayerVideoGravityResizeAspect,
             @"ScaleAspectFill": AVLayerVideoGravityResizeAspectFill
             };
}

+ (BOOL)requiresMainQueueSetup
{
    return YES;
}

@end

