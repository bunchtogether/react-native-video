#import <React/RCTViewManager.h>
#import "RCTVideoDownloader.h"

@interface RCTVideoManager : RCTViewManager
    @property (nonatomic, strong) RCTVideoDownloader *downloader;
@end

