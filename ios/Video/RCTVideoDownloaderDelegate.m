//
//  RCTVideoDownloaderDelegate.m
//  RCTVideo
//
//  Created by John Wehr on 1/4/19.
//

#import <MobileCoreServices/MobileCoreServices.h>
#import <AVFoundation/AVMediaFormat.h>
#import "RCTVideoDownloaderDelegate.h"

@interface RCTVideoDownloaderDelegate () <NSURLConnectionDelegate, NSURLConnectionDataDelegate>
@property (nonatomic, strong) NSMutableDictionary *connectionMap;
@property (nonatomic, strong) NSMutableDictionary *requestMap;
@property (nonatomic, strong) NSMutableDictionary *contentTypeMap;
@property (nonatomic, strong) NSMutableDictionary *baseUrlMap;
@property (nonatomic, strong) NSRegularExpression *keyRegex;
@property (nonatomic, strong) NSRegularExpression *segmentRegex;
@property (nonatomic, strong) NSRegularExpression *playlistRegex;
@end

@implementation RCTVideoDownloaderDelegate

+ (instancetype)sharedVideoDownloaderDelegate {
    static RCTVideoDownloaderDelegate *sharedVideoDownloaderDelegate = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedVideoDownloaderDelegate = [[self alloc] init];
    });
    return sharedVideoDownloaderDelegate;
}

- (instancetype)init
{
    if (self = [super init]) {
        self.connectionMap = [NSMutableDictionary dictionary];
        self.requestMap = [NSMutableDictionary dictionary];
        self.contentTypeMap = [NSMutableDictionary dictionary];
        self.baseUrlMap = [NSMutableDictionary dictionary];
        NSError *regexError = NULL;
        NSRegularExpressionOptions regexOptions = NSRegularExpressionCaseInsensitive;
        NSString* keyRegexPattern = @"#EXT-X-KEY.*?URI=\"(.*?)\"";
        self.keyRegex = [NSRegularExpression regularExpressionWithPattern:keyRegexPattern options:regexOptions error:&regexError];
        if (regexError) {
            NSLog(@"RCTVideoDownloaderDelegate: Couldn't create key regex");
        }
        NSString* segmentRegexPattern = @"#EXTINF:.*?\\n(.*?)\\n";
        self.segmentRegex = [NSRegularExpression regularExpressionWithPattern:segmentRegexPattern options:regexOptions error:&regexError];
        if (regexError) {
            NSLog(@"RCTVideoDownloaderDelegate: Couldn't create segment regex");
        }
        NSString* playlistRegexPattern = @"#EXT-X-STREAM-INF:.*?\\n(.*?)\\n";
        self.playlistRegex = [NSRegularExpression regularExpressionWithPattern:playlistRegexPattern options:regexOptions error:&regexError];
        if (regexError) {
            NSLog(@"RCTVideoDownloaderDelegate: Couldn't create playlist regex");
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

#pragma mark - Public

#pragma mark - Resource loader delegate

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSURLComponents *components = [[NSURLComponents alloc] initWithURL:loadingRequest.request.URL resolvingAgainstBaseURL:YES];
    if(![components.scheme isEqualToString:@"rctvideohttps"] && ![components.scheme isEqualToString:@"rctvideohttp"]) {
        return NO;
    }
    components.scheme = [components.scheme isEqualToString:@"rctvideohttps"] ? @"https" : @"http";
    if([components.path containsString:@".m3u8"]) {
        NSLog(@"RCTVideoDownloaderDelegate: Loading %@", [components.URL absoluteString]);
        NSMutableURLRequest *request = loadingRequest.request.mutableCopy;
        request.URL = components.URL;
        request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        NSURLConnection * connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
        NSString* loadingRequestKey = [self getLoadingRequestKey:loadingRequest];
        self.connectionMap[loadingRequestKey] = connection;
        self.requestMap[loadingRequestKey] = loadingRequest;
        self.baseUrlMap[loadingRequestKey] = components.URL;
        [connection start];
        return YES;
    }
    NSLog(@"RCTVideoDownloaderDelegate: Redirecting %@", [components.URL absoluteString]);
    NSURLRequest* redirect = [NSURLRequest requestWithURL:components.URL];
    [loadingRequest setRedirect:redirect];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[redirect URL] statusCode:302 HTTPVersion:nil headerFields:nil];
    [loadingRequest setResponse:response];
    [loadingRequest finishLoading];
    return YES;
}

- (NSString*)getKeyFilePath:(NSURL*)url {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *applicationSupportDirectory = [paths firstObject];
    NSArray *components = [NSArray arrayWithObjects:applicationSupportDirectory, [@([url absoluteString].hash) stringValue], nil];
    return [NSString pathWithComponents:components];
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest
{
    [self removeRequest:loadingRequest];
}

#pragma mark - NSURL Connection delegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    NSString *contentType = [response MIMEType];
    unsigned long long contentLength = [response expectedContentLength];
    NSString *rangeValue = [(NSHTTPURLResponse *)response allHeaderFields][@"Content-Range"];
    if (rangeValue) {
        NSArray *rangeItems = [rangeValue componentsSeparatedByString:@"/"];
        if (rangeItems.count > 1) {
            contentLength = [rangeItems[1] longLongValue];
        } else {
            contentLength = [response expectedContentLength];
        }
    }
    AVAssetResourceLoadingRequest* loadingRequest = [self loadingRequestForConnection:connection];
    NSString* loadingRequestKey = [self getLoadingRequestKey:loadingRequest];
    NSURL* baseUrl = self.baseUrlMap[loadingRequestKey];
    NSLog(@"RCTVideoDownloaderDelegate: Got response for %@", [baseUrl absoluteString]);
    loadingRequest.response = response;
    loadingRequest.contentInformationRequest.contentLength = contentLength;
    loadingRequest.contentInformationRequest.contentType = contentType;
    loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
}

- (void)downloadKey:(NSMutableURLRequest *)keyRequest {
    NSString *keyFilePath = [self getKeyFilePath:keyRequest.URL];
    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:keyRequest
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    if (error) {
                        NSLog(@"RCTVideoDownloaderDelegate: Key download error:%@", error.description);
                    }
                    if (data) {
                        [data writeToFile:keyFilePath atomically:YES];
                        NSLog(@"RCTVideoDownloaderDelegate: Key saved to %@", keyFilePath);
                    }
                }] resume];
}

- (void)connection:(NSURLConnection*)connection didReceiveData:(NSData *)data {
    AVAssetResourceLoadingRequest* loadingRequest = [self loadingRequestForConnection:connection];
    NSString* loadingRequestKey = [self getLoadingRequestKey:loadingRequest];
    NSURL* baseUrl = self.baseUrlMap[loadingRequestKey];
    NSLog(@"RCTVideoDownloaderDelegate: Got data for %@", [baseUrl absoluteString]);
    NSString* original = [NSString stringWithUTF8String:[data bytes]];
    if(!original) {
        [loadingRequest.dataRequest respondWithData:data];
        return;
    }
    
    NSArray *keyMatches = [self.keyRegex matchesInString:original options:0 range:NSMakeRange(0, [original length])];
    NSMutableDictionary* replacements = [NSMutableDictionary dictionary];
    for (NSTextCheckingResult *keyMatch in keyMatches) {
        if(keyMatch.numberOfRanges > 1) {
            NSString* keyUrlString = [original substringWithRange:[keyMatch rangeAtIndex:1]];
            NSMutableURLRequest *keyRequest = loadingRequest.request.mutableCopy;
            keyRequest.URL = [NSURL URLWithString:keyUrlString relativeToURL:baseUrl];
            keyRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
            [self downloadKey:keyRequest];
            replacements[keyUrlString] = [NSString stringWithFormat:@"file://%@", [self getKeyFilePath:keyRequest.URL]];
        }
    }
    NSArray *segmentMatches = [self.segmentRegex matchesInString:original options:0 range:NSMakeRange(0, [original length])];
    for (NSTextCheckingResult *segmentMatch in segmentMatches) {
        if(segmentMatch.numberOfRanges > 1) {
            NSString* segmentUrlString = [original substringWithRange:[segmentMatch rangeAtIndex:1]];
            replacements[segmentUrlString] = [[NSURL URLWithString:segmentUrlString relativeToURL:baseUrl] absoluteString];
        }
    }
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
    [loadingRequest.dataRequest respondWithData:[transformed dataUsingEncoding:NSUTF8StringEncoding]];
}

- (void)connectionDidFinishLoading:(NSURLConnection*)connection {
    AVAssetResourceLoadingRequest* loadingRequest = [self loadingRequestForConnection:connection];
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




