//
//  RCTVideoDownloaderDelegate.m
//  RCTVideo
//
//  Created by John Wehr on 1/4/19.
//

#import <MobileCoreServices/MobileCoreServices.h>
#import <AVFoundation/AVFoundation.h>
#import "RCTVideoDownloaderDelegate.h"

@interface RCTVideoDownloaderDelegate ()
@property (nonatomic, strong) NSURL *baseUrl;
@property (nonatomic, copy) void (^completionHandler)(NSError *);
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) NSMutableDictionary *responseMap;
@property (nonatomic, strong) NSMutableDictionary *dataMap;
@property (nonatomic, strong) NSMutableDictionary *downloadCompletionHandlerMap;
@property (nonatomic, strong) NSMutableDictionary *completionHandlerMap;
@end

static NSDateFormatter* CreateDateFormatter(NSString *format) {
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US"]];
    [dateFormatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"GMT"]];
    [dateFormatter setDateFormat:format];
    return dateFormatter;
}

@implementation RCTVideoDownloaderDelegate

#pragma mark - Public

+ (NSRegularExpression *)keyRegex {
    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression
                 regularExpressionWithPattern:@"#EXT-X-KEY.*?URI=\"(.*?)\""
                 options:NSRegularExpressionCaseInsensitive
                 error:nil];
    });
    return regex;
}

+ (NSRegularExpression *)playlistRegex {
    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression
                 regularExpressionWithPattern:@"#EXT-X-STREAM-INF:.*?\\n(.*?)\\n"
                 options:NSRegularExpressionCaseInsensitive
                 error:nil];
    });
    return regex;
}

+ (NSRegularExpression *)segmentRegex {
    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression
                 regularExpressionWithPattern:@"#EXTINF:.*?\\n(.*?)\\n"
                 options:NSRegularExpressionCaseInsensitive
                 error:nil];
    });
    return regex;
}

+ (void)setKeyFilePath:(NSURL*)keyUrl baseUrl:(NSURL*)baseUrl {
    NSString *baseUrlPath = [self getUrlFilePath:baseUrl];
    NSString *keyFilePath = [self getUrlFilePath:keyUrl];
    NSError *error;
    [keyFilePath writeToFile:baseUrlPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if(error) {
        NSLog(@"VideoDownloader Delegate: Unable to set key file path for ", [baseUrl absoluteString], error.localizedDescription);
    }
}

+ (void)clearCacheForUrl:(NSURL*)baseUrl {
    NSLog(@"VideoDownloader Delegate: Clearing cache for %@", [baseUrl absoluteString]);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:baseUrl];
    [[NSURLCache sharedURLCache] removeCachedResponseForRequest:request];
    NSString *keyFilePath = [RCTVideoDownloaderDelegate getKeyFilePath:baseUrl];
    if(!keyFilePath) {
        NSLog(@"VideoDownloader Delegate: Unable to remove key file for %@, file reference does not exist.", [baseUrl absoluteString]);
        return;
    }
    NSError *error;
    if(![[NSFileManager defaultManager] fileExistsAtPath:keyFilePath]) {
        NSLog(@"VideoDownloader Delegate: Unable to remove key file for %@, file does not exist.", [baseUrl absoluteString]);
        return;
    }
    [[NSFileManager defaultManager] removeItemAtPath:keyFilePath error:&error];
    if (error) {
        NSLog(@"VideoDownloader Delegate: Error removing cached key for %@ download error: %@", [baseUrl absoluteString], error.localizedDescription);
    }
}

+ (instancetype)sharedVideoDownloaderDelegate {
    static RCTVideoDownloaderDelegate *sharedVideoDownloaderDelegate = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_t queue = dispatch_queue_create("Video Downloader Delegate Queue", DISPATCH_QUEUE_SERIAL);
        sharedVideoDownloaderDelegate = [[self alloc] initWithQueue:queue];
    });
    return sharedVideoDownloaderDelegate;
}

#pragma mark - Private



- (void)dealloc
{
    NSLog(@"RCTVideoDownloader Delegate: dealloc");
    self.completionHandler = nil;
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    if (self = [super init]) {
        self.responseMap = [NSMutableDictionary dictionary];
        self.dataMap = [NSMutableDictionary dictionary];
        self.downloadCompletionHandlerMap = [NSMutableDictionary dictionary];
        self.completionHandlerMap = [NSMutableDictionary dictionary];
        self.queue = queue;
    }
    return self;
}

- (void)addCompletionHandlerForAsset:(AVURLAsset *)asset completionHandler:(void (^)(NSError *))completionHandler {
    NSString *key = [NSString stringWithFormat:@"%p", asset.resourceLoader];
    self.completionHandlerMap[key] = completionHandler;
}

- (void)runCompletionHandler:(NSError *)error resourceLoader:(AVAssetResourceLoader *)resourceLoader {
    NSString *key = [NSString stringWithFormat:@"%p", resourceLoader];
    __block void (^completionHandler)(NSError *) = self.completionHandlerMap[key];
    if(!completionHandler) {
        NSLog(@"VideoDownloader Delegate: Completion handler does not exist");
        return;
    }
    NSLog(@"VideoDownloader Delegate: Completion handler exists");
    [self.completionHandlerMap removeObjectForKey:key];
    dispatch_async(self.queue, ^{
        completionHandler(error);
    });
}

#pragma mark - AVAssetResourceLoaderDelegate delegate

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForRenewalOfRequestedResource:(AVAssetResourceRenewalRequest *)renewalRequest {
    return [self resourceLoader:resourceLoader shouldWaitForLoadingOfRequestedResource:renewalRequest];
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSURLComponents *components = [[NSURLComponents alloc] initWithURL:loadingRequest.request.URL resolvingAgainstBaseURL:YES];
    if(![components.scheme isEqualToString:@"rctvideohttps"] && ![components.scheme isEqualToString:@"rctvideohttp"] && ![components.scheme isEqualToString:@"rctvideokeyhttps"] && ![components.scheme isEqualToString:@"rctvideokeyhttp"]) {
        NSLog(@"VideoDownloader Delegate: Unsupported URL scheme %@ for %@", components.scheme, [components.URL absoluteString]);
        return NO;
    }
    if([components.scheme isEqualToString:@"rctvideokeyhttps"] || [components.scheme isEqualToString:@"rctvideokeyhttp"]) {
        components.scheme = [components.scheme isEqualToString:@"rctvideokeyhttps"] ? @"https" : @"http";
        NSString *keyFilePath = [RCTVideoDownloaderDelegate getUrlFilePath:components.URL];
        if([[NSFileManager defaultManager] fileExistsAtPath:keyFilePath]) {
            NSData *data = [NSData dataWithContentsOfFile:keyFilePath];
            loadingRequest.contentInformationRequest.contentType = AVStreamingKeyDeliveryPersistentContentKeyType;
            loadingRequest.contentInformationRequest.byteRangeAccessSupported = NO;
            loadingRequest.contentInformationRequest.contentLength = data.length;
            [loadingRequest.dataRequest respondWithData: data];
            [loadingRequest finishLoading];
            return YES;
        }
        NSMutableURLRequest *request = loadingRequest.request.mutableCopy;
        request.URL = components.URL;
        request.cachePolicy = NSURLRequestUseProtocolCachePolicy;
        [RCTVideoDownloaderDelegate download:request completionHandler:^(NSData* data, NSHTTPURLResponse* response, NSError* error){
            if(error) {
                NSLog(@"VideoDownloader Delegate: Key %@ download error %@", [request.URL absoluteString], error.localizedDescription);
                [loadingRequest finishLoadingWithError:error];
                return;
            }
            NSLog(@"VideoDownloader Delegate: Key %@ downloaded to %@", [request.URL absoluteString], keyFilePath);
            loadingRequest.contentInformationRequest.contentType = AVStreamingKeyDeliveryPersistentContentKeyType;
            loadingRequest.contentInformationRequest.byteRangeAccessSupported = NO;
            loadingRequest.contentInformationRequest.contentLength = data.length;
            [loadingRequest.dataRequest respondWithData: data];
            [loadingRequest finishLoading];
            [data writeToFile:keyFilePath atomically:YES];
        }];
        return YES;
    }
    components.scheme = [components.scheme isEqualToString:@"rctvideohttps"] ? @"https" : @"http";
    if(![components.path containsString:@".m3u8"]) {
        NSLog(@"VideoDownloader Delegate: Redirecting %@", [components.URL absoluteString]);
        NSURLRequest* redirect = [NSURLRequest requestWithURL:components.URL];
        [loadingRequest setRedirect:redirect];
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[redirect URL] statusCode:301 HTTPVersion:nil headerFields:nil];
        [loadingRequest setResponse:response];
        [loadingRequest finishLoading];
        [self runCompletionHandler:nil resourceLoader:resourceLoader];
        return YES;
    }
    NSLog(@"VideoDownloader Delegate: Downloading %@", [components.URL absoluteString]);
    NSMutableURLRequest *request = loadingRequest.request.mutableCopy;
    request.URL = components.URL;
    request.cachePolicy = NSURLRequestUseProtocolCachePolicy;
    [RCTVideoDownloaderDelegate download:request completionHandler:^(NSData* data, NSHTTPURLResponse* response, NSError* error){
        if(error) {
            NSLog(@"VideoDownloader Delegate: Playlist %@ download error %@", [request.URL absoluteString], error.localizedDescription);
            [loadingRequest finishLoadingWithError:error];
            return;
        }
        NSLog(@"VideoDownloader Delegate: Playlist %@ downloaded", [request.URL absoluteString]);
        NSString *original = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if(!original) {
            NSString* message =  [NSString stringWithFormat:@"VideoDownloader Delegate: Download %@ failed with empty or invalid playlist body", [request.URL absoluteString]];
            NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: NSLocalizedString(message, nil) };
            NSError *responseError = [NSError errorWithDomain:[[NSBundle mainBundle] bundleIdentifier]
                                                         code:-1
                                                     userInfo:userInfo];
            [loadingRequest finishLoadingWithError:responseError];
            return;
        }
        NSLog(@"\n\n%@\n\n", original);
        NSMutableDictionary* replacements = [NSMutableDictionary dictionary];
        NSArray *keyMatches = [[RCTVideoDownloaderDelegate keyRegex] matchesInString:original options:0 range:NSMakeRange(0, [original length])];
        for (NSTextCheckingResult *keyMatch in keyMatches) {
            if(keyMatch.numberOfRanges > 1) {
                NSString* keyUrlString = [original substringWithRange:[keyMatch rangeAtIndex:1]];
                NSURL *keyUrl = [NSURL URLWithString:keyUrlString relativeToURL:request.URL];
                [RCTVideoDownloaderDelegate setKeyFilePath:keyUrl baseUrl:request.URL];
                NSURLComponents *keyUrlComponents = [[NSURLComponents alloc] initWithURL:keyUrl resolvingAgainstBaseURL:YES];
                keyUrlComponents.scheme = [keyUrlComponents.scheme isEqualToString:@"https"] ? @"rctvideokeyhttps" : @"rctvideokeyhttp";
                replacements[keyUrlString] = [keyUrlComponents.URL absoluteString];
            }
        }
        NSArray *segmentMatches = [[RCTVideoDownloaderDelegate segmentRegex] matchesInString:original options:0 range:NSMakeRange(0, [original length])];
        for (NSTextCheckingResult *segmentMatch in segmentMatches) {
            if(segmentMatch.numberOfRanges > 1) {
                NSString* segmentUrlString = [original substringWithRange:[segmentMatch rangeAtIndex:1]];
                NSURL* segmentUrl = [NSURL URLWithString:segmentUrlString relativeToURL:request.URL];
                replacements[segmentUrlString] = [segmentUrl absoluteString];
            }
        }
        NSArray *playlistMatches = [[RCTVideoDownloaderDelegate playlistRegex] matchesInString:original options:0 range:NSMakeRange(0, [original length])];
        for (NSTextCheckingResult *playlistMatch in playlistMatches) {
            if(playlistMatch.numberOfRanges > 1) {
                NSString *playlistUrlString = [original substringWithRange:[playlistMatch rangeAtIndex:1]];
                NSURL *playlistUrl = [NSURL URLWithString:playlistUrlString relativeToURL:request.URL];
                NSURLComponents *playlistUrlComponents = [[NSURLComponents alloc] initWithURL:playlistUrl resolvingAgainstBaseURL:YES];
                playlistUrlComponents.scheme = [playlistUrlComponents.scheme isEqualToString:@"https"] ? @"rctvideohttps" : @"rctvideohttp";
                replacements[playlistUrlString] = [playlistUrlComponents.URL absoluteString];
            }
        }
        NSString* transformed = original;
        for(NSString* urlString in replacements) {
            transformed = [transformed stringByReplacingOccurrencesOfString:urlString
                                                                 withString:[replacements objectForKey:urlString]];
        }
        NSLog(@"\n\n%@\n\n", transformed);
        NSData *transformedData = [transformed dataUsingEncoding:NSUTF8StringEncoding];
        loadingRequest.contentInformationRequest.contentType = [response MIMEType];
        loadingRequest.contentInformationRequest.byteRangeAccessSupported = NO;
        loadingRequest.contentInformationRequest.contentLength = transformedData.length;
        NSDate* renewalDate = [RCTVideoDownloaderDelegate expirationDateFromHeaders:[response allHeaderFields]
                                                                     withStatusCode:[response statusCode]];
        loadingRequest.contentInformationRequest.renewalDate = renewalDate;
        [loadingRequest.dataRequest respondWithData: transformedData];
        [loadingRequest finishLoading];
        return;
    }];
    [self runCompletionHandler:nil resourceLoader:resourceLoader];
    return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: NSLocalizedString(@"Loading request was canceled.", nil) };
    NSError *error = [NSError errorWithDomain:[[NSBundle mainBundle] bundleIdentifier]
                                         code:-999
                                     userInfo:userInfo];
    [self runCompletionHandler:error resourceLoader:resourceLoader];
}

#pragma mark - Key path methods

+ (NSString*)getKeyFilePath:(NSURL*)baseUrl {
    NSString *baseUrlPath = [RCTVideoDownloaderDelegate getUrlFilePath:baseUrl];
    if(![[NSFileManager defaultManager] fileExistsAtPath:baseUrlPath]) {
        return nil;
    }
    NSError *error;
    NSString *keyFilePath = [NSString stringWithContentsOfFile:baseUrlPath encoding:NSUTF8StringEncoding error:&error];
    if(error) {
        NSLog(@"VideoDownloader Delegate: Unable to get key file path for %@: %@", [baseUrl absoluteString], error.localizedDescription);
        return nil;
    }
    return keyFilePath;
}

+ (NSString*)getUrlFilePath:(NSURL*)url {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *applicationSupportDirectory = [paths firstObject];
    NSArray *components = [NSArray arrayWithObjects:applicationSupportDirectory, [@([url absoluteString].hash) stringValue], nil];
    return [NSString pathWithComponents:components];
}

+ (void)download:(NSMutableURLRequest *)request completionHandler:(void(^)(NSData*, NSHTTPURLResponse*, NSError*))completionHandler {
    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
            if (error) {
                return completionHandler(data, httpResponse, error);
            }
            NSInteger status = [httpResponse statusCode];
            if (status == 200) {
                return completionHandler(data, httpResponse, nil);
            }
            NSString* message =  [NSString stringWithFormat:@"VideoDownloader Delegate: Download %@ failed with status %ld", [request.URL absoluteString], (long)status];
            NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: NSLocalizedString(message, nil) };
            NSError *responseError = [NSError errorWithDomain:[[NSBundle mainBundle] bundleIdentifier]
                                                         code:-1
                                                     userInfo:userInfo];
            return completionHandler(data, httpResponse, responseError);
        }
        NSString* message =  [NSString stringWithFormat:@"VideoDownloader Delegate: Download %@ failed with invalid response", [request.URL absoluteString]];
        NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: NSLocalizedString(message, nil) };
        NSError *responseError = [NSError errorWithDomain:[[NSBundle mainBundle] bundleIdentifier]
                                                     code:-2
                                                 userInfo:userInfo];
        return completionHandler(nil, nil, responseError);
    }] resume];
}

#pragma mark - Date Header methods

+ (NSDate *)expirationDateFromHeaders:(NSDictionary *)headers withStatusCode:(NSInteger)status {
    if (status != 200 && status != 203 && status != 300 && status != 301 && status != 302 && status != 307 && status != 410) {
        return nil;
    }
    
    NSString *pragma = [headers objectForKey:@"Pragma"];
    if (pragma && [pragma isEqualToString:@"no-cache"]) {
        return nil;
    }
    
    NSString *date = [headers objectForKey:@"Date"];
    NSDate *now;
    if (date) {
        now = [RCTVideoDownloaderDelegate dateFromHttpDateString:date];
    } else {
        now = [NSDate date];
    }
    
    NSString *cacheControl = [headers objectForKey:@"Cache-Control"];
    if (cacheControl) {
        NSRange foundRange = [cacheControl rangeOfString:@"no-store"];
        if (foundRange.length > 0) {
            return nil;
        }
        
        NSInteger maxAge;
        foundRange = [cacheControl rangeOfString:@"max-age="];
        if (foundRange.length > 0) {
            NSScanner *cacheControlScanner = [NSScanner scannerWithString:cacheControl];
            [cacheControlScanner setScanLocation:foundRange.location + foundRange.length];
            if ([cacheControlScanner scanInteger:&maxAge]) {
                if (maxAge > 0) {
                    return [[NSDate alloc] initWithTimeInterval:maxAge sinceDate:now];
                } else {
                    return nil;
                }
            }
        }
    }
    
    NSString *expires = [headers objectForKey:@"Expires"];
    if (expires) {
        NSTimeInterval expirationInterval = 0;
        NSDate *expirationDate = [RCTVideoDownloaderDelegate dateFromHttpDateString:expires];
        if (expirationDate) {
            expirationInterval = [expirationDate timeIntervalSinceDate:now];
        }
        if (expirationInterval > 0) {
            return [NSDate dateWithTimeIntervalSinceNow:expirationInterval];
        } else {
            return nil;
        }
    }
    
    if (status == 302 || status == 307) {
        return nil;
    }
    
    NSString *lastModified = [headers objectForKey:@"Last-Modified"];
    if (lastModified) {
        NSTimeInterval age = 0;
        NSDate *lastModifiedDate = [RCTVideoDownloaderDelegate dateFromHttpDateString:lastModified];
        if (lastModifiedDate) {
            age = [now timeIntervalSinceDate:lastModifiedDate];
        }
        if (age > 0) {
            return [NSDate dateWithTimeIntervalSinceNow:(age *  0.1f)];
        } else {
            return nil;
        }
    }
    return nil;
}


+ (NSDate *)dateFromHttpDateString:(NSString *)httpDate {
    
    static NSDateFormatter *RFC1123DateFormatter;
    static NSDateFormatter *ANSICDateFormatter;
    static NSDateFormatter *RFC850DateFormatter;
    NSDate *date = nil;
    
    @synchronized(self) {
        if (!RFC1123DateFormatter) RFC1123DateFormatter = CreateDateFormatter(@"EEE, dd MMM yyyy HH:mm:ss z");
        date = [RFC1123DateFormatter dateFromString:httpDate];
        if (!date) {
            if (!ANSICDateFormatter) ANSICDateFormatter = CreateDateFormatter(@"EEE MMM d HH:mm:ss yyyy");
            date = [ANSICDateFormatter dateFromString:httpDate];
            if (!date) {
                if (!RFC850DateFormatter) RFC850DateFormatter = CreateDateFormatter(@"EEEE, dd-MMM-yy HH:mm:ss z");
                date = [RFC850DateFormatter dateFromString:httpDate];
            }
        }
    }
    
    return date;
}

@end









