//
//  BackgroundDownloadAppDelegate.h
//


#import <UIKit/UIKit.h>

@interface BackgroundDownloadAppDelegate : UIResponder <UIApplicationDelegate>

@property (strong, nonatomic) UIWindow *window;
@property (copy) void (^sessionCompletionHandler)();
@end
