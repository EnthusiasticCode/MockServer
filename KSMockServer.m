//
//  Created by Sam Deane on 06/11/2012.
//  Copyright 2012 Karelia Software. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <sys/socket.h>
#import <netinet/in.h>   // for IPPROTO_TCP, sockaddr_in

#import "KSMockServer.h"
#import "KSMockServerConnection.h"
#import "KSMockServerListener.h"
#import "KSMockServerRegExResponder.h"

@interface KSMockServer()

@property (strong, nonatomic) KSMockServerConnection* connection;
@property (strong, nonatomic) NSMutableArray* dataConnections;
@property (strong, nonatomic) KSMockServerListener* dataListener;
@property (strong, nonatomic) KSMockServerListener* listener;
@property (strong, nonatomic) NSOperationQueue* queue;
@property (strong, nonatomic) KSMockServerResponder* responder;
@property (assign, atomic) BOOL running;


@end

@implementation KSMockServer

@synthesize connection = _connection;
@synthesize data = _data;
@synthesize dataConnections = _dataConnections;
@synthesize dataListener = _dataListener;
@synthesize listener = _listener;
@synthesize queue = _queue;
@synthesize responder = _responder;
@synthesize running = _running;

NSString *const CloseCommand = @"«close»";
NSString *const InitialResponseKey = @"«initial»";

#pragma mark - Object Lifecycle

+ (KSMockServer*)serverWithResponder:(KSMockServerResponder*)responder
{
    KSMockServer* server = [[KSMockServer alloc] initWithPort:0 responder:responder];

    return [server autorelease];
}

+ (KSMockServer*)serverWithPort:(NSUInteger)port responder:(KSMockServerResponder*)responder
{
    KSMockServer* server = [[KSMockServer alloc] initWithPort:port responder:responder];

    return [server autorelease];
}

- (id)initWithPort:(NSUInteger)port responder:(KSMockServerResponder*)responder
{
    if ((self = [super init]) != nil)
    {
        self.queue = [NSOperationQueue currentQueue];
        self.responder = responder;
        self.listener = [KSMockServerListener listenerWithPort:port connectionBlock:^BOOL(int socket) {
            MockServerAssert(socket != 0);

            BOOL ok = self.connection == nil;
            if (ok)
            {
                MockServerLog(@"received connection");
                self.connection = [KSMockServerConnection connectionWithSocket:socket responder:self.responder server:self];
            }

            return ok;
        }];
    }

    return self;
}

- (void)dealloc
{
    [_connection release];
    [_data release];
    [_dataConnections release];
    [_dataListener release];
    [_queue release];
    [_responder release];

    [super dealloc];
}

#pragma mark - Public API

- (void)start
{
    BOOL success = [self.listener start];
    if (success)
    {
        [self makeDataListener];

        MockServerAssert(self.port != 0);
        MockServerLog(@"server started on port %ld", self.port);
        self.running = YES;
    }
}

- (void)stop
{
    [self.connection cancel];
    [self.listener stop:@"stopped externally"];
    [self.dataListener stop:@"stopped externally"];
    for (KSMockServerConnection* connection in self.dataConnections)
    {
        [connection cancel];
    }

    self.running = NO;
}

- (void)runUntilStopped
{
    while (self.running)
    {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate date]];
        }
    }
}

- (NSUInteger)port
{
    return self.listener.port;
}

#pragma mark - Substitutions


- (NSDictionary*)standardSubstitutions
{
    NSUInteger extraPort = self.dataListener.port;
    NSDictionary* substitutions =
    @{
    @"$address" : @"127.0.0.1",
    @"$server" : @"fakeserver 20121107",
    @"$size" : [NSString stringWithFormat:@"%ld", (long) [self.data length]],
    @"$pasv" : [NSString stringWithFormat:@"127,0,0,1,%ld,%ld", extraPort / 256L, extraPort % 256L]
    };

    return substitutions;
}

#pragma mark - Data Connection

- (void)makeDataListener
{
    self.dataConnections = [NSMutableArray array];
    __block KSMockServer* server = self;
    self.dataListener = [KSMockServerListener listenerWithPort:0 connectionBlock:^BOOL(int socket) {

        MockServerLog(@"got connection on data listener");

        NSData* data = server.data;
        if (!data)
        {
            data = [@"Test data" dataUsingEncoding:NSUTF8StringEncoding];
        }

        NSArray* responses = @[ @[InitialResponseKey, data, CloseCommand ] ];
        KSMockServerRegExResponder* responder = [KSMockServerRegExResponder responderWithResponses:responses];
        KSMockServerConnection* connection = [KSMockServerConnection connectionWithSocket:socket responder:responder server:server];
        [self.dataConnections addObject:connection];

        return YES;
    }];

    [self.dataListener start];
}

- (void)disposeDataListener
{
}

@end
