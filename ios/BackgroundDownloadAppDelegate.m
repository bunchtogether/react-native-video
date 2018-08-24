//
//  BackgroundDownloadAppDelegate.m
//

#import "BackgroundDownloadAppDelegate.h"

@implementation BackgroundDownloadAppDelegate

- (void)application:(UIApplication *)application handleEventsForBackgroundURLSession:(NSString *)identifier
  completionHandler:(void (^)())completionHandler
{
    self.sessionCompletionHandler = completionHandler;
}

@end

