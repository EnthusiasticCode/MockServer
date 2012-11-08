//
//  Created by Sam Deane on 06/11/2012.
//  Copyright 2012 Karelia Software. All rights reserved.
//

#import "KSMockServer.h"
#import "KSMockServerFTPResponses.h"

#import <SenTestingKit/SenTestingKit.h>

@interface KSMockServerTests : SenTestCase

@end

@implementation KSMockServerTests

static NSString *const HTTPHeader = @"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=iso-8859-1\r\n\r\n";
static NSString*const HTTPContent = @"<!DOCTYPE HTML PUBLIC \"-//IETF//DTD HTML 2.0//EN\"><html><head><title>example</title></head><body>example result</body></html>\n";

- (NSArray*)httpResponses
{
    NSArray* responses = @[
    @[ @"^GET .* HTTP.*", HTTPHeader, HTTPContent, @(0.1), CloseCommand],
    @[@"^HEAD .* HTTP.*", HTTPHeader, CloseCommand],
    ];

    return responses;
}

- (KSMockServer*)setupServerWithResponses:(NSArray*)responses
{
    KSMockServer* server = [KSMockServer serverWithPort:0 responses:responses];

    STAssertNotNil(server, @"got server");
    [server start];
    BOOL started = server.running;
    STAssertTrue(started, @"server started ok");
    return started ? server : nil;
}

- (NSString*)stringForScheme:(NSString*)scheme path:(NSString*)path method:(NSString*)method server:(KSMockServer*)server
{
    NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://127.0.0.1:%ld%@", scheme, (long)server.port, path]];
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    return [self stringForRequest:request server:server];
}

- (NSString*)stringForScheme:(NSString*)scheme path:(NSString*)path server:(KSMockServer*)server
{
    NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://127.0.0.1:%ld%@", scheme, (long)server.port, path]];
    NSURLRequest* request = [NSURLRequest requestWithURL:url];
    return [self stringForRequest:request server:server];
}

- (NSString*)stringForRequest:(NSURLRequest*)request server:(KSMockServer*)server
{
    __block NSString* string = nil;

    [NSURLConnection sendAsynchronousRequest:request queue:[NSOperationQueue currentQueue] completionHandler:^(NSURLResponse* response, NSData* data, NSError* error)
     {
         if (error)
         {
             NSLog(@"got error %@", error);
         }
         else
         {
             string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
         }

         [server stop];
     }];

    [server runUntilStopped];

    return [string autorelease];
}

#pragma mark - Tests

- (void)testHTTPGet
{
    KSMockServer* server = [self setupServerWithResponses:[self httpResponses]];
    if (server)
    {
        NSString* string = [self stringForScheme:@"http" path:@"/index.html" method:@"GET" server:server];
        STAssertEqualObjects(string, HTTPContent, @"wrong response");
    }
}

- (void)testHTTPHead
{
    KSMockServer* server = [self setupServerWithResponses:[self httpResponses]];
    if (server)
    {
        NSString* string = [self stringForScheme:@"http" path:@"/index.html" method:@"HEAD" server:server];
        STAssertEqualObjects(string, @"", @"wrong response");
    }
}

- (void)testFTP
{
    KSMockServer* server = [self setupServerWithResponses:[KSMockServerFTPResponses standardResponses]];
    if (server)
    {
        NSString* testData = @"This is some test data";
        server.data = [testData dataUsingEncoding:NSUTF8StringEncoding];
        NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"ftp://user:pass@127.0.0.1:%ld/test.txt", (long)server.port]];
        NSURLRequest* request = [NSURLRequest requestWithURL:url];

        NSString* string = [self stringForRequest:request server:server];
        STAssertEqualObjects(string, testData, @"wrong response");
    }
}

@end