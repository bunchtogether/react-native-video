//
//  RCTVideoDownloaderDelegateOld.m
//  RCTVideo
//
//  Created by John Wehr on 1/4/19.
//

#import <MobileCoreServices/MobileCoreServices.h>
#import <AVFoundation/AVMediaFormat.h>
#import "RCTVideoDownloaderDelegate.old.h"

@interface RCTVideoDownloaderDelegateOld () <NSURLConnectionDelegate, NSURLConnectionDataDelegate>
@property (nonatomic, strong) NSMutableDictionary *connectionMap;
@property (nonatomic, strong) NSMutableDictionary *requestMap;
@property (nonatomic, strong) NSMutableDictionary *contentTypeMap;
@property (nonatomic, strong) NSMutableDictionary *baseUrlMap;
@property (nonatomic, strong) NSMutableDictionary *responseDataMap;
@property (nonatomic, strong) NSRegularExpression *keyRegex;
@property (nonatomic, strong) NSRegularExpression *segmentRegex;
@property (nonatomic, strong) NSRegularExpression *playlistRegex;
@end

static NSDateFormatter* CreateDateFormatter(NSString *format) {
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US"]];
    [dateFormatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"GMT"]];
    [dateFormatter setDateFormat:format];
    return dateFormatter;
}

@implementation RCTVideoDownloaderDelegateOld

+ (instancetype)sharedVideoDownloaderDelegate {
    static RCTVideoDownloaderDelegateOld *sharedVideoDownloaderDelegate = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedVideoDownloaderDelegate = [[self alloc] init];
    });
    return sharedVideoDownloaderDelegate;
}

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
        now = [RCTVideoDownloaderDelegateOld dateFromHttpDateString:date];
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
        NSDate *expirationDate = [RCTVideoDownloaderDelegateOld dateFromHttpDateString:expires];
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
        NSDate *lastModifiedDate = [RCTVideoDownloaderDelegateOld dateFromHttpDateString:lastModified];
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

- (instancetype)init
{
    if (self = [super init]) {
        [NSURLCache sharedURLCache];
        self.connectionMap = [NSMutableDictionary dictionary];
        self.requestMap = [NSMutableDictionary dictionary];
        self.contentTypeMap = [NSMutableDictionary dictionary];
        self.baseUrlMap = [NSMutableDictionary dictionary];
        self.responseDataMap = [NSMutableDictionary dictionary];
        NSError *regexError = NULL;
        NSRegularExpressionOptions regexOptions = NSRegularExpressionCaseInsensitive;
        NSString* keyRegexPattern = @"#EXT-X-KEY.*?URI=\"(.*?)\"";
        self.keyRegex = [NSRegularExpression regularExpressionWithPattern:keyRegexPattern options:regexOptions error:&regexError];
        if (regexError) {
            NSLog(@"VideoDownloader Delegate:  Couldn't create key regex");
        }
        //        NSString* segmentRegexPattern = @"#EXTINF:.*?\\n(.*?)\\n";
        //        self.segmentRegex = [NSRegularExpression regularExpressionWithPattern:segmentRegexPattern options:regexOptions error:&regexError];
        //        if (regexError) {
        //            NSLog(@"VideoDownloader Delegate:  Couldn't create segment regex");
        //        }
        NSString* playlistRegexPattern = @"#EXT-X-STREAM-INF:.*?\\n(.*?)\\n";
        self.playlistRegex = [NSRegularExpression regularExpressionWithPattern:playlistRegexPattern options:regexOptions error:&regexError];
        if (regexError) {
            NSLog(@"VideoDownloader Delegate:  Couldn't create playlist regex");
        }
    }
    return self;
}

- (NSString*)getLoadingRequestKey:(AVAssetResourceLoadingRequest *)loadingRequest {
    return [NSString stringWithFormat:@"%p", loadingRequest];
}

- (NSString*)getContentType:(NSURL *)url {
    NSString *extension = [url pathExtension];
    NSString *UTI = (__bridge_transfer NSString *)UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)extension, NULL);
    return (__bridge_transfer NSString *)UTTypeCopyPreferredTagWithClass((__bridge CFStringRef)UTI, kUTTagClassMIMEType);
}

- (void)removeRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    if (!loadingRequest) {
        return;
    }
    NSString* loadingRequestKey = [self getLoadingRequestKey:loadingRequest];
    NSURLConnection* connection = self.connectionMap[loadingRequestKey];
    if(connection) {
        [connection cancel];
    }
    [self.connectionMap removeObjectForKey:loadingRequestKey];
    [self.requestMap removeObjectForKey:loadingRequestKey];
    [self.contentTypeMap removeObjectForKey:loadingRequestKey];
    [self.baseUrlMap removeObjectForKey:loadingRequestKey];
    [self.responseDataMap removeObjectForKey:loadingRequestKey];
}

- (NSURLConnection *)connectionForLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    if (!loadingRequest) {
        return nil;
    }
    return self.connectionMap[[self getLoadingRequestKey:loadingRequest]];
}

- (AVAssetResourceLoadingRequest *)loadingRequestForConnection:(NSURLConnection *)connection {
    if (!connection) {
        return nil;
    }
    for (NSString *loadingRequestKey in self.connectionMap) {
        NSURLConnection* value = self.connectionMap[loadingRequestKey];
        if (value == connection) {
            return self.requestMap[loadingRequestKey];
        }
    }
    return nil;
}

- (NSString*)getUrlFilePath:(NSURL*)url {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *applicationSupportDirectory = [paths firstObject];
    NSArray *components = [NSArray arrayWithObjects:applicationSupportDirectory, [@([url absoluteString].hash) stringValue], nil];
    return [NSString pathWithComponents:components];
}

- (void)setKeyFilePath:(NSURL*)keyUrl baseUrl:(NSURL*)baseUrl {
    NSString *baseUrlPath = [self getUrlFilePath:baseUrl];
    NSString *keyFilePath = [self getUrlFilePath:keyUrl];
    NSError *error;
    [keyFilePath writeToFile:baseUrlPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if(error) {
        NSLog(@"VideoDownloader Delegate:  Unable to set key file path for ", [baseUrl absoluteString], error.localizedDescription);
    }
}

- (NSString*)getKeyFilePath:(NSURL*)baseUrl {
    NSString *baseUrlPath = [self getUrlFilePath:baseUrl];
    if(![[NSFileManager defaultManager] fileExistsAtPath:baseUrlPath]) {
        return nil;
    }
    NSError *error;
    NSString *keyFilePath = [NSString stringWithContentsOfFile:baseUrlPath encoding:NSUTF8StringEncoding error:&error];
    if(error) {
        NSLog(@"VideoDownloader Delegate:  Unable to get key file path for ", [baseUrl absoluteString], error.localizedDescription);
        return nil;
    }
    return keyFilePath;
}

- (void)downloadKey:(NSMutableURLRequest *)keyRequest completionHandler:(void(^)(NSData* data, NSError *error))completionHandler {
    NSString *keyFilePath = [self getUrlFilePath:keyRequest.URL];
    if([[NSFileManager defaultManager] fileExistsAtPath:keyFilePath]) {
        NSLog(@"VideoDownloader Delegate:  Key for %@ exists at %@", [keyRequest.URL absoluteString], keyFilePath);
        if(completionHandler) {
            completionHandler([NSData dataWithContentsOfFile:keyFilePath], nil);
        }
        return;
    }
    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:keyRequest
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
                        NSInteger status = [httpResponse statusCode];
                        if (error) {
                            NSLog(@"VideoDownloader Delegate:  Key for %@ download error: %@", [keyRequest.URL absoluteString], error.localizedDescription);
                            if(completionHandler) {
                                return completionHandler(nil, error);
                            }
                        } else if (data && status == 200) {
                            [data writeToFile:keyFilePath atomically:YES];
                            NSLog(@"VideoDownloader Delegate:  Key for %@ saved to %@", [keyRequest.URL absoluteString], keyFilePath);
                            if(completionHandler) {
                                return completionHandler(data, nil);
                            }
                        } else {
                            NSLog(@"VideoDownloader Delegate:  Key for %@ download failed with status %ld", [keyRequest.URL absoluteString], (long)status);
                            if(completionHandler) {
                                return completionHandler(nil, nil);
                            }
                        }
                    } else {
                        NSLog(@"VideoDownloader Delegate:  Invalid key response type for %@", [keyRequest.URL absoluteString]);
                        if(completionHandler) {
                            return completionHandler(nil, nil);
                        }
                    }
                }] resume];
}

- (NSData *)transformResponseData:(NSData *)data loadingRequest:(AVAssetResourceLoadingRequest*)loadingRequest {
    NSString* loadingRequestKey = [self getLoadingRequestKey:loadingRequest];
    NSURL* baseUrl = self.baseUrlMap[loadingRequestKey];
    NSString *original = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if(!original) {
        return data;
    }
    NSLog(@"%@", original);
    NSArray *keyMatches = [self.keyRegex matchesInString:original options:0 range:NSMakeRange(0, [original length])];
    NSMutableDictionary* replacements = [NSMutableDictionary dictionary];
    for (NSTextCheckingResult *keyMatch in keyMatches) {
        if(keyMatch.numberOfRanges > 1) {
            NSString* keyUrlString = [original substringWithRange:[keyMatch rangeAtIndex:1]];
            NSMutableURLRequest *keyRequest = loadingRequest.request.mutableCopy;
            keyRequest.URL = [NSURL URLWithString:keyUrlString relativeToURL:baseUrl];
            keyRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
            [self downloadKey:keyRequest completionHandler:nil];
            [self setKeyFilePath:keyRequest.URL baseUrl:baseUrl];
            NSURLComponents *keyUrlComponents = [[NSURLComponents alloc] initWithURL:keyRequest.URL resolvingAgainstBaseURL:YES];
            keyUrlComponents.scheme = [keyUrlComponents.scheme isEqualToString:@"https"] ? @"rctvideokeyhttps" : @"rctvideokeyhttp";
            replacements[keyUrlString] = [keyUrlComponents.URL absoluteString];
        }
    }
    //    NSArray *segmentMatches = [self.segmentRegex matchesInString:original options:0 range:NSMakeRange(0, [original length])];
    //    for (NSTextCheckingResult *segmentMatch in segmentMatches) {
    //        if(segmentMatch.numberOfRanges > 1) {
    //            NSString* segmentUrlString = [original substringWithRange:[segmentMatch rangeAtIndex:1]];
    //            NSURL* segmentUrl = [NSURL URLWithString:segmentUrlString relativeToURL:baseUrl];
    //            replacements[segmentUrlString] = [segmentUrl absoluteString];
    //        }
    //    }
    NSArray *playlistMatches = [self.playlistRegex matchesInString:original options:0 range:NSMakeRange(0, [original length])];
    for (NSTextCheckingResult *playlistMatch in playlistMatches) {
        if(playlistMatch.numberOfRanges > 1) {
            NSString* playlistUrlString = [original substringWithRange:[playlistMatch rangeAtIndex:1]];
            NSURLComponents *playlistUrlComponents = [[NSURLComponents alloc] initWithURL:[NSURL URLWithString:playlistUrlString relativeToURL:baseUrl] resolvingAgainstBaseURL:YES];
            playlistUrlComponents.scheme = [playlistUrlComponents.scheme isEqualToString:@"https"] ? @"rctvideohttps" : @"rctvideohttp";
            replacements[playlistUrlString] = [playlistUrlComponents.URL absoluteString];
        }
    }
    NSString* transformed = original;
    for(NSString* urlString in replacements) {
        transformed = [transformed stringByReplacingOccurrencesOfString:urlString
                                                             withString:[replacements objectForKey:urlString]];
    }
    NSLog(@"%@", transformed);
    return [transformed dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - Public

- (void)clearCacheForUrl:(NSURL*)baseUrl {
    NSLog(@"VideoDownloader Delegate:  Clearing cache for %@", [baseUrl absoluteString]);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:baseUrl];
    [[NSURLCache sharedURLCache] removeCachedResponseForRequest:request];
    NSString *keyFilePath = [self getKeyFilePath:baseUrl];
    if(!keyFilePath) {
        NSLog(@"VideoDownloader Delegate:  Unable to remove key file for %@, file reference does not exist.", [baseUrl absoluteString]);
        return;
    }
    NSError *error;
    if(![[NSFileManager defaultManager] fileExistsAtPath:keyFilePath]) {
        NSLog(@"VideoDownloader Delegate:  Unable to remove key file for %@, file does not exist.", [baseUrl absoluteString]);
        return;
    }
    [[NSFileManager defaultManager] removeItemAtPath:keyFilePath error:&error];
    if (error) {
        NSLog(@"VideoDownloader Delegate:  Error removing cached key for %@ download error: %@", [baseUrl absoluteString], error.localizedDescription);
    }
}

#pragma mark - Resource loader delegate

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSURLComponents *components = [[NSURLComponents alloc] initWithURL:loadingRequest.request.URL resolvingAgainstBaseURL:YES];
    if(![components.scheme isEqualToString:@"rctvideohttps"] && ![components.scheme isEqualToString:@"rctvideohttp"] && ![components.scheme isEqualToString:@"rctvideokeyhttps"] && ![components.scheme isEqualToString:@"rctvideokeyhttp"]) {
        return NO;
    }
    if([components.scheme isEqualToString:@"rctvideokeyhttps"] || [components.scheme isEqualToString:@"rctvideokeyhttp"]) {
        NSMutableURLRequest *keyRequest = loadingRequest.request.mutableCopy;
        components.scheme = [components.scheme isEqualToString:@"rctvideokeyhttps"] ? @"https" : @"http";
        keyRequest.URL = components.URL;
        [self downloadKey:keyRequest completionHandler:^(NSData* data, NSError* error){
            if(error) {
                [loadingRequest finishLoadingWithError:error];
                return;
            }
            if(data) {
                loadingRequest.contentInformationRequest.contentLength = data.length;
                loadingRequest.contentInformationRequest.contentType = AVStreamingKeyDeliveryPersistentContentKeyType;
                loadingRequest.contentInformationRequest.byteRangeAccessSupported = NO;
                [loadingRequest.dataRequest respondWithData: data];
            }
            [loadingRequest finishLoading];
        }];
        return YES;
    }
    components.scheme = [components.scheme isEqualToString:@"rctvideohttps"] ? @"https" : @"http";
    if([components.path containsString:@".m3u8"]) {
        NSMutableURLRequest *request = loadingRequest.request.mutableCopy;
        NSURL* baseUrl = components.URL;
        request.URL = components.URL;
        request.cachePolicy = NSURLRequestUseProtocolCachePolicy;
        NSString* loadingRequestKey = [self getLoadingRequestKey:loadingRequest];
        self.requestMap[loadingRequestKey] = loadingRequest;
        self.baseUrlMap[loadingRequestKey] = baseUrl;
        NSCachedURLResponse *cachedResponse = [[NSURLCache sharedURLCache] cachedResponseForRequest:request];
        if(cachedResponse) {
            NSHTTPURLResponse *cachedHttpResponse = (NSHTTPURLResponse*)[cachedResponse response];
            NSString *contentType = [cachedHttpResponse MIMEType];
            loadingRequest.response = [cachedResponse response];
            loadingRequest.contentInformationRequest.contentType = contentType;
            loadingRequest.contentInformationRequest.byteRangeAccessSupported = NO;
            NSDate* renewalDate = [RCTVideoDownloaderDelegateOld expirationDateFromHeaders:[cachedHttpResponse allHeaderFields] withStatusCode:[cachedHttpResponse statusCode]];
            loadingRequest.contentInformationRequest.renewalDate = renewalDate;
            [loadingRequest.dataRequest respondWithData: [self transformResponseData:cachedResponse.data loadingRequest:loadingRequest]];
            [loadingRequest finishLoading];
            [self removeRequest:loadingRequest];
            NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
            [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
            NSLog(@"VideoDownloader Delegate:  Got cached response for %@, expires %@", [baseUrl absoluteString], [dateFormatter stringFromDate:renewalDate]);
            return YES;
        }
        NSLog(@"VideoDownloader Delegate:  Loading %@", [baseUrl absoluteString]);
        NSURLConnection * connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
        self.connectionMap[loadingRequestKey] = connection;
        self.responseDataMap[loadingRequestKey] = [NSMutableData data];
        [connection start];
        return YES;
    }
    //    NSMutableURLRequest *request = loadingRequest.request.mutableCopy;
    //    NSCachedURLResponse *cachedResponse = [[NSURLCache sharedURLCache] cachedResponseForRequest:request];
    //    if(cachedResponse){
    //        NSLog(@"VideoDownloader Delegate:  Sending cached response %@", [components.URL absoluteString]);
    //        NSHTTPURLResponse *httpCacheResponse = (NSHTTPURLResponse *)cachedResponse.response;
    //        [loadingRequest setResponse:httpCacheResponse];
    //        [loadingRequest finishLoading];
    //        return YES;
    //    }
    NSLog(@"VideoDownloader Delegate:  Redirecting %@", [components.URL absoluteString]);
    NSURLRequest* redirect = [NSURLRequest requestWithURL:components.URL];
    [loadingRequest setRedirect:redirect];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[redirect URL] statusCode:301 HTTPVersion:nil headerFields:nil];
    [loadingRequest setResponse:response];
    [loadingRequest finishLoading];
    return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    [self removeRequest:loadingRequest];
}

#pragma mark - NSURL Connection delegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    AVAssetResourceLoadingRequest* loadingRequest = [self loadingRequestForConnection:connection];
    NSString* loadingRequestKey = [self getLoadingRequestKey:loadingRequest];
    NSURL* baseUrl = self.baseUrlMap[loadingRequestKey];
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSLog(@"VideoDownloader Delegate:  Invalid response response type for %@", [baseUrl absoluteString]);
    }
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
    NSString *contentType = [httpResponse MIMEType];
    NSMutableData *responseData = self.responseDataMap[loadingRequestKey];
    [responseData setLength:0];
    loadingRequest.response = response;
    loadingRequest.contentInformationRequest.contentType = contentType;
    loadingRequest.contentInformationRequest.byteRangeAccessSupported = NO;
    NSDate* renewalDate = [RCTVideoDownloaderDelegateOld expirationDateFromHeaders:[httpResponse allHeaderFields] withStatusCode:[httpResponse statusCode]];
    loadingRequest.contentInformationRequest.renewalDate = renewalDate;
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSLog(@"VideoDownloader Delegate:  Got response for %@, expires %@", [baseUrl absoluteString], [dateFormatter stringFromDate:renewalDate]);
}

- (void)connection:(NSURLConnection*)connection didReceiveData:(NSData *)data {
    AVAssetResourceLoadingRequest* loadingRequest = [self loadingRequestForConnection:connection];
    NSString* loadingRequestKey = [self getLoadingRequestKey:loadingRequest];
    NSMutableData *responseData = self.responseDataMap[loadingRequestKey];
    [responseData appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection*)connection {
    AVAssetResourceLoadingRequest* loadingRequest = [self loadingRequestForConnection:connection];
    NSString* loadingRequestKey = [self getLoadingRequestKey:loadingRequest];
    NSMutableData *responseData = self.responseDataMap[loadingRequestKey];
    loadingRequest.contentInformationRequest.contentLength = responseData.length;
    [loadingRequest.dataRequest respondWithData: [self transformResponseData:responseData loadingRequest:loadingRequest]];
    [loadingRequest finishLoading];
    [self removeRequest:loadingRequest];
}

- (void)connection:(NSURLConnection*)connection didFailWithError:(NSError *)error {
    AVAssetResourceLoadingRequest* loadingRequest = [self loadingRequestForConnection:connection];
    [loadingRequest finishLoadingWithError:error];
    [self removeRequest:loadingRequest];
}

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response {
    AVAssetResourceLoadingRequest* loadingRequest = [self loadingRequestForConnection:connection];
    loadingRequest.redirect = request;
    return request;
}


@end






