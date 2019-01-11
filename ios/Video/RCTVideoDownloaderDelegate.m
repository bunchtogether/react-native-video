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
@property (nonatomic, strong) NSMutableData *responseData;
@property (nonatomic, strong) NSURL *baseUrl;
@property (nonatomic, strong) AVAssetResourceLoadingRequest *loadingRequest;
@property (nonatomic, copy) void (^completionHandler)(NSError *);
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

+ (NSMutableDictionary *)delegates {
    static NSMutableDictionary *delegates = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        delegates = [NSMutableDictionary dictionary];
    });
    return delegates;
}

+ (void)cacheKeys:(AVURLAsset *)asset queue:(dispatch_queue_t)queue completionHandler:(void (^)(NSError *))completionHandler {
    NSURLComponents *components = [[NSURLComponents alloc] initWithURL:asset.URL resolvingAgainstBaseURL:YES];
    if([components.path containsString:@".m3u8"]) {
        __block RCTVideoDownloaderDelegate *delegate;
        delegate = [[self alloc] initWithCompletionHandler:^(NSError *error){
            dispatch_async(dispatch_get_main_queue(), ^{
                delegate.completionHandler = nil;
                if(completionHandler) {
                    NSLog(@"VideoDownloader Delegate: Completion handler for %@", [asset.URL absoluteString]);
                    completionHandler(error);
                }
            });
        }];
        [self delegates][[NSString stringWithFormat:@"%p", delegate]] = delegate;
        [asset.resourceLoader setDelegate:delegate queue:queue];
        asset.resourceLoader.preloadsEligibleContentKeys = YES;
    } else {
        NSLog(@"VideoDownloader Delegate: Not assigning delegate to %@", [asset.URL absoluteString]);
        if(completionHandler) {
            completionHandler(nil);
        }
    }
}

#pragma mark - Private

- (void)dealloc
{
    NSLog(@"RCTVideoDownloader Delegate: dealloc");
    self.responseData = nil;
    self.completionHandler = nil;
}

- (instancetype)initWithCompletionHandler:(void (^)(NSError *))completionHandler {
    if (self = [super init]) {
        self.completionHandler = completionHandler;
        self.responseData = [NSMutableData data];
    }
    return self;
}

- (NSData *)transformResponseData:(NSData *)data {
    return data;
}

#pragma mark - AVAssetResourceLoaderDelegate delegate

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForRenewalOfRequestedResource:(AVAssetResourceRenewalRequest *)renewalRequest {
    NSLog(@"VideoDownloader Delegate: shouldWaitForRenewalOfRequestedResource");
    return YES;
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSURLComponents *components = [[NSURLComponents alloc] initWithURL:loadingRequest.request.URL resolvingAgainstBaseURL:YES];
    if(![components.scheme isEqualToString:@"rctvideohttps"] && ![components.scheme isEqualToString:@"rctvideohttp"] && ![components.scheme isEqualToString:@"rctvideokeyhttps"] && ![components.scheme isEqualToString:@"rctvideokeyhttp"]) {
        NSLog(@"VideoDownloader Delegate: Unsupported URL scheme %@ for %@", components.scheme, [components.URL absoluteString]);
        return NO;
    }
    components.scheme = [components.scheme isEqualToString:@"rctvideohttps"] ? @"https" : @"http";
    NSLog(@"VideoDownloader Delegate: Redirecting %@", [components.URL absoluteString]);
    NSURLRequest* redirect = [NSURLRequest requestWithURL:components.URL];
    [loadingRequest setRedirect:redirect];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[redirect URL] statusCode:301 HTTPVersion:nil headerFields:nil];
    [loadingRequest setResponse:response];
    [loadingRequest finishLoading];
    if(self.completionHandler) {
        self.completionHandler(nil);
    }
    return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: NSLocalizedString(@"Loading request was canceled.", nil) };
    NSError *error = [NSError errorWithDomain:[[NSBundle mainBundle] bundleIdentifier]
                                         code:-999
                                     userInfo:userInfo];
    if(self.completionHandler) {
        self.completionHandler(error);
    }
}


#pragma mark - NSURL Connection delegate
/*
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSLog(@"VideoDownloader Delegate: Invalid response response type for %@", [self.baseUrl absoluteString]);
    }
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
    NSString *contentType = [httpResponse MIMEType];
    [self.responseData setLength:0];
    self.loadingRequest.response = response;
    self.loadingRequest.contentInformationRequest.contentType = contentType;
    self.loadingRequest.contentInformationRequest.byteRangeAccessSupported = NO;
    NSDate* renewalDate = [RCTVideoDownloaderDelegate expirationDateFromHeaders:[httpResponse allHeaderFields] withStatusCode:[httpResponse statusCode]];
    self.loadingRequest.contentInformationRequest.renewalDate = renewalDate;
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSLog(@"VideoDownloader Delegate: Got response for %@, expires %@", [self.baseUrl absoluteString], [dateFormatter stringFromDate:renewalDate]);
}

- (void)connection:(NSURLConnection*)connection didReceiveData:(NSData *)data {
    [self.responseData appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection*)connection {
    self.loadingRequest.contentInformationRequest.contentLength = self.responseData.length;
    [self.loadingRequest.dataRequest respondWithData: [self transformResponseData:self.responseData]];
    [self.loadingRequest finishLoading];
    self.completionHandler(nil);
}

- (void)connection:(NSURLConnection*)connection didFailWithError:(NSError *)error {
    [self.loadingRequest finishLoadingWithError:error];
    self.completionHandler(error);
}

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response {
    self.loadingRequest.redirect = request;
    return request;
}
*/

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

+ (void)downloadKey:(NSMutableURLRequest *)keyRequest completionHandler:(void(^)(NSData*, NSError*))completionHandler {
    NSString *keyFilePath = [RCTVideoDownloaderDelegate getUrlFilePath:keyRequest.URL];
    if([[NSFileManager defaultManager] fileExistsAtPath:keyFilePath]) {
        NSLog(@"VideoDownloader Delegate: Key for %@ exists at %@", [keyRequest.URL absoluteString], keyFilePath);
        if(completionHandler) {
            completionHandler([NSData dataWithContentsOfFile:keyFilePath], nil);
        }
        return;
    }
    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:keyRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
            NSInteger status = [httpResponse statusCode];
            if (error) {
                NSLog(@"VideoDownloader Delegate: Key for %@ download error: %@", [keyRequest.URL absoluteString], error.localizedDescription);
                if(completionHandler) {
                    return completionHandler(nil, error);
                }
            } else if (data && status == 200) {
                [data writeToFile:keyFilePath atomically:YES];
                NSLog(@"VideoDownloader Delegate: Key for %@ saved to %@", [keyRequest.URL absoluteString], keyFilePath);
                if(completionHandler) {
                    return completionHandler(data, nil);
                }
            } else {
                NSLog(@"VideoDownloader Delegate: Key for %@ download failed with status %ld", [keyRequest.URL absoluteString], (long)status);
                if(completionHandler) {
                    return completionHandler(nil, nil);
                }
            }
        } else {
            NSLog(@"VideoDownloader Delegate: Invalid key response type for %@", [keyRequest.URL absoluteString]);
            if(completionHandler) {
                return completionHandler(nil, nil);
            }
        }
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







