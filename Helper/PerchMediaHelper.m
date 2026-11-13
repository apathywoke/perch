// PerchMediaHelper — tiny bridge to the system "Now Playing" service.
//
// Since macOS 15.4 only Apple-signed processes may read Now Playing data from
// MediaRemote. This library is loaded into /usr/bin/perl (an Apple-signed
// system binary), reads the data there and prints it as JSON lines on stdout.
// Commands are accepted as plain text lines on stdin. No network, no files.
//
// stdout: one JSON object per line
//   {"bundleId":…, "playing":…, "title":…, "artist":…, "album":…,
//    "duration":…, "elapsed":…, "timestamp":…, "rate":…,
//    "artworkId":…, "artwork":"<base64, only when artworkId changes>"}
//   {} when nothing is playing.
// stdin:
//   send <id>     MediaRemote command (0 play, 1 pause, 2 toggle, 4 next, 5 previous…)
//   seek <sec>    set elapsed time
//   refresh       re-emit the current state

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <dlfcn.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*MRClientStringFn)(id);
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendFn)(unsigned int, CFDictionaryRef);
typedef void (*MRSetElapsedFn)(double);

static MRGetInfoFn getInfo;
static MRGetPlayingFn getPlaying;
static MRGetPIDFn getPID;
static MRGetClientFn getClient;
static MRClientStringFn clientBundleId;
static MRClientStringFn clientParentBundleId;
static MRSendFn sendCommand;
static MRSetElapsedFn setElapsed;

static dispatch_queue_t queue;
static NSString *lastArtworkId = nil;
static NSString *lastLine = nil;

static void writeLine(NSString *line) {
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    const char *bytes = data.bytes;
    size_t left = data.length;
    while (left > 0) {
        ssize_t n = write(STDOUT_FILENO, bytes, left);
        if (n <= 0) exit(0); // parent is gone
        bytes += n;
        left -= (size_t)n;
    }
}

static NSString *artworkIdentifier(NSData *data) {
    if (data.length == 0) return nil;
    // FNV-1a over a sample of the bytes: cheap and good enough to detect changes.
    uint64_t hash = 1469598103934665603ULL;
    const uint8_t *bytes = data.bytes;
    NSUInteger step = MAX((NSUInteger)1, data.length / 4096);
    for (NSUInteger i = 0; i < data.length; i += step) {
        hash = (hash ^ bytes[i]) * 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%lu-%llx", (unsigned long)data.length, hash];
}

static void emit(BOOL force) {
    getInfo(queue, ^(CFDictionaryRef cfInfo) {
        NSDictionary *info = (__bridge NSDictionary *)cfInfo;
        getPlaying(queue, ^(Boolean playing) {
            void (^finish)(NSString *) = ^(NSString *bundleId) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
                if (info.count > 0 && [title isKindOfClass:NSString.class] && title.length > 0) {
                    out[@"title"] = title;
                    out[@"playing"] = @((BOOL)playing);
                    if (bundleId) out[@"bundleId"] = bundleId;
                    id v;
                    if ([(v = info[@"kMRMediaRemoteNowPlayingInfoArtist"]) isKindOfClass:NSString.class]) out[@"artist"] = v;
                    if ([(v = info[@"kMRMediaRemoteNowPlayingInfoAlbum"]) isKindOfClass:NSString.class]) out[@"album"] = v;
                    if ([(v = info[@"kMRMediaRemoteNowPlayingInfoDuration"]) isKindOfClass:NSNumber.class]) out[@"duration"] = v;
                    if ([(v = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]) isKindOfClass:NSNumber.class]) out[@"elapsed"] = v;
                    if ([(v = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]) isKindOfClass:NSNumber.class]) out[@"rate"] = v;
                    if ([(v = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"]) isKindOfClass:NSDate.class])
                        out[@"timestamp"] = @([(NSDate *)v timeIntervalSince1970]);
                    NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                    if ([art isKindOfClass:NSData.class] && art.length > 0) {
                        out[@"artworkId"] = artworkIdentifier(art);
                    }
                    NSString *artId = out[@"artworkId"];
                    NSData *keyData = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
                    NSString *key = [[NSString alloc] initWithData:keyData encoding:NSUTF8StringEncoding];
                    if (!force && [key isEqualToString:lastLine]) return;
                    lastLine = key;
                    if (artId && (force || ![artId isEqualToString:lastArtworkId])) {
                        out[@"artwork"] = [art base64EncodedStringWithOptions:0];
                    }
                    lastArtworkId = artId;
                } else {
                    if (!force && [lastLine isEqualToString:@"{}"]) return;
                    lastLine = @"{}";
                    lastArtworkId = nil;
                }
                NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
                writeLine([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
            };

            if (getClient && clientBundleId) {
                getClient(queue, ^(id client) {
                    NSString *bundleId = nil;
                    if (client) {
                        if (clientParentBundleId) bundleId = (__bridge NSString *)clientParentBundleId(client);
                        if (bundleId.length == 0) bundleId = (__bridge NSString *)clientBundleId(client);
                    }
                    finish(bundleId.length ? bundleId : nil);
                });
            } else if (getPID) {
                getPID(queue, ^(int pid) {
                    NSRunningApplication *app = pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
                    finish(app.bundleIdentifier);
                });
            } else {
                finish(nil);
            }
        });
    });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                                  componentsSeparatedByString:@" "];
    if (parts.count == 0) return;
    NSString *name = parts[0];
    if ([name isEqualToString:@"send"] && parts.count == 2 && sendCommand) {
        int cmd = parts[1].intValue;
        if (cmd >= 0 && cmd <= 13) sendCommand((unsigned int)cmd, NULL);
    } else if ([name isEqualToString:@"seek"] && parts.count == 2 && setElapsed) {
        double t = parts[1].doubleValue;
        if (isfinite(t) && t >= 0) setElapsed(t);
    } else if ([name isEqualToString:@"refresh"]) {
        emit(YES);
    }
}

__attribute__((visibility("default")))
void perch_main(void) {
    @autoreleasepool {
        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (!mr) { fprintf(stderr, "MediaRemote unavailable\n"); exit(2); }
        getInfo = dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
        getPlaying = dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        getPID = dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
        getClient = dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
        clientBundleId = dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
        clientParentBundleId = dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
        sendCommand = dlsym(mr, "MRMediaRemoteSendCommand");
        setElapsed = dlsym(mr, "MRMediaRemoteSetElapsedTime");
        MRRegisterFn registerNotifications = dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
        if (!getInfo || !getPlaying || !registerNotifications) { fprintf(stderr, "MediaRemote symbols missing\n"); exit(2); }

        queue = dispatch_queue_create("perch.media", DISPATCH_QUEUE_SERIAL);
        registerNotifications(queue);

        NSArray<NSString *> *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
        ];
        for (NSString *name in names) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                dispatch_async(queue, ^{ emit(NO); });
            }];
        }
        dispatch_async(queue, ^{ emit(YES); });

        // Commands from the parent app; EOF means the app quit, so we quit too.
        dispatch_queue_t inputQueue = dispatch_queue_create("perch.input", DISPATCH_QUEUE_SERIAL);
        dispatch_async(inputQueue, ^{
            char buffer[256];
            while (fgets(buffer, sizeof(buffer), stdin)) {
                NSString *line = [NSString stringWithUTF8String:buffer];
                if (line) dispatch_async(queue, ^{ handleCommand(line); });
            }
            exit(0);
        });

        CFRunLoopRun();
    }
}
