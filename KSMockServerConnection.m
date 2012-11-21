//
//  Created by Sam Deane on 06/11/2012.
//  Copyright 2012 Karelia Software. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "KSMockServerConnection.h"

#import "KSMockServer.h"
#import "KSMockServerListener.h"
#import "KSMockServerResponder.h"

@interface KSMockServerConnection()

@property (strong, nonatomic) NSInputStream* input;
@property (strong, nonatomic) NSOutputStream* output;
@property (strong, nonatomic) NSMutableData* outputData;
@property (strong, nonatomic) KSMockServerResponder* responder;
@property (strong, nonatomic) KSMockServer* server;


@end

@implementation KSMockServerConnection

@synthesize input   = _input;
@synthesize output = _output;
@synthesize outputData = _outputData;
@synthesize responder = _responder;
@synthesize server = _server;

#pragma mark - Object Lifecycle

+ (KSMockServerConnection*)connectionWithSocket:(int)socket responder:(KSMockServerResponder*)responder server:(KSMockServer *)server
{
    KSMockServerConnection* connection = [[KSMockServerConnection alloc] initWithSocket:socket responder:responder server:server];

    return [connection autorelease];
}

- (id)initWithSocket:(int)socket responder:(KSMockServerResponder*)responder server:(KSMockServer *)server
{
    if ((self = [super init]) != nil)
    {
        self.server = server;
        self.responder = responder;
        self.outputData = [NSMutableData data];

        CFReadStreamRef readStream;
        CFWriteStreamRef writeStream;
        CFStreamCreatePairWithSocket(NULL, socket, &readStream, &writeStream);

        self.input = [self setupStream:(NSStream*)readStream];
        self.output = [self setupStream:(NSStream*)writeStream];
    }

    return self;
}

- (void)dealloc
{
    [_input release];
    [_output release];
    [_outputData release];
    [_server release];

    
    [super dealloc];
}

#pragma mark - Public API

- (void)cancel
{
    [self disconnectStreams:@"cancelled"];
}

#pragma mark - Data Processing

- (void)processInput
{
    uint8_t buffer[32768];
    NSInteger bytesRead = [self.input read:buffer maxLength:sizeof(buffer)];
    if (bytesRead == -1)
    {
        [self disconnectStreams:@"read error"];
    }

    else if (bytesRead == 0)
    {
        [self disconnectStreams:@"no more data"];
    }

    else
    {
        NSDictionary* substitutions = [self.server standardSubstitutions];
        NSString* request = [[NSString alloc] initWithBytes:buffer length:bytesRead encoding:NSUTF8StringEncoding];
        MockServerLog(@"got request '%@'", request);
        NSArray* commands = [self.responder responseForRequest:request substitutions:substitutions];
        if (commands)
        {
            [self processCommands:commands];
        }
        else
        {
            // if nothing matched, close the connection
            // to prevent this, add a key of ".*" as the last response in the array
            [self processCommands:@[CloseCommand]];
        }

        [request release];
    }
}

- (void)processClose
{
    MockServerLog(@"closed connection");
    [self.output close];
    [self.input close];
}

- (void)processCommands:(NSArray*)commands
{
    NSTimeInterval delay = 0.0;
    for (id command in commands)
    {
        if ([command isKindOfClass:[NSNumber class]])
        {
            delay += [command doubleValue];
        }
        else
        {
            SEL method;
            BOOL isString = [command isKindOfClass:[NSString class]];
            if (isString && [command isEqual:CloseCommand])
            {
                method = @selector(processClose);
            }
            else
            {
                method = @selector(processOutput);
                if (isString)
                {
                    MockServerLog(@"queued output %@", command);
                    command = [command dataUsingEncoding:NSUTF8StringEncoding];
                }
                [self.outputData appendData:command];
            }

            [self performSelector:method withObject:command afterDelay:delay];
        }
    }
}



- (void)processOutput
{
    NSUInteger bytesToWrite = [self.outputData length];
    if (bytesToWrite)
    {
        NSUInteger written = [self.output write:[self.outputData bytes] maxLength:bytesToWrite];
        [self.outputData replaceBytesInRange:NSMakeRange(0, written) withBytes:nil length:0];

        MockServerLog(@"wrote %ld bytes", (long)written);
    }
}

#pragma mark - Streams

- (id)setupStream:(NSStream*)stream
{
    MockServerAssert(stream);

    [stream setProperty:(id)kCFBooleanTrue forKey:(NSString *)kCFStreamPropertyShouldCloseNativeSocket];
    stream.delegate = self;
    [stream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [stream open];
    CFRelease(stream);

    return stream;
}

- (void)cleanupStream:(NSStream*)stream
{
    @synchronized(stream)
    {
        if (stream)
        {
            stream.delegate = nil;
            [stream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
            [stream close];
        }
    }
}
- (void)disconnectStreams:(NSString*)reason
{
    [self cleanupStream:self.input];
    self.input = nil;

    [self cleanupStream:self.output];
    self.output = nil;

    [self.server connectionDidClose:self];
    MockServerLog(@"disconnected: %@", reason);
}

- (NSString*)nameForStream:(NSStream*)stream
{
    NSString* result;
    if (stream == self.input)
    {
        result = @"input";
    }
    else if (stream == self.output)
    {
        result = @"output";
    }
    else
    {
        result = @"unknown";
    }

    return result;
}

- (KSMockServerResponder*)responder
{
    KSMockServerResponder* result = _responder;
    if (!result)
    {
        result = self.server.responder;
    }

    return result;
}

- (void)stream:(NSStream*)stream handleEvent:(NSStreamEvent)eventCode
{
    MockServerAssert((stream == self.input) || (stream == self.output));

    switch (eventCode)
    {
        case NSStreamEventOpenCompleted:
        {
            MockServerLog(@"opened %@ stream", [self nameForStream:stream]);
            if (stream == self.input)
            {
                [self processCommands:self.responder.initialResponse];
            }
            break;
        }

        case NSStreamEventHasBytesAvailable:
        {
            [self processInput];
            break;
        }

        case NSStreamEventHasSpaceAvailable:
        {
            MockServerAssert(stream == self.output);     // should never happen for the input stream
            [self processOutput];
            break;
        }

        case NSStreamEventErrorOccurred:
        {
            MockServerLog(@"got error for %@ stream", [self nameForStream:stream]);
            [self disconnectStreams:@"Stream open error"];
            break;
        }

        case NSStreamEventEndEncountered:
        {
            MockServerLog(@"got eof for %@ stream", [self nameForStream:stream]);
            break;
        }

        default:
        {
            MockServerLog(@"unknown event for %@ stream", [self nameForStream:stream]);
            MockServerAssert(NO);
            break;
        }
    }
}

@end
