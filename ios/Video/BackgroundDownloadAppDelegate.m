//
//  BackgroundDownloadAppDelegate.m
//

#import "BackgroundDownloadAppDelegate.h"

@implementation BackgroundDownloadAppDelegate

- (void)application:(UIApplication *)application handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)())completionHandler {
    [self.sessionCompletionHandlers setObject:completionHandler forKey:identifier];
}

@end


