#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOBluetooth/IOBluetooth.h>
#import <objc/message.h>
#import <dlfcn.h>

typedef void (*MRMediaRemoteGetNowPlayingInfoFn)(dispatch_queue_t queue, void (^handler)(NSDictionary *info));
typedef void (*MRMediaRemoteGetNowPlayingApplicationIsPlayingFn)(dispatch_queue_t queue, void (^handler)(Boolean isPlaying));
typedef Boolean (*MRMediaRemoteSendCommandFn)(int command, id userInfo);
typedef void (*MRMediaRemoteSetElapsedTimeFn)(double elapsedTime);

@interface NSObject (IslandBluetoothBatteryPrivate)
- (uint8_t)batteryPercentSingle;
- (uint8_t)batteryPercentCombined;
- (uint8_t)batteryPercentLeft;
- (uint8_t)batteryPercentRight;
- (uint8_t)batteryPercentCase;
@end

/// Reads the live battery percentage for a connected Bluetooth device by re-fetching from
/// `IOBluetoothDevice.pairedDevices` and reading the private `uint8_t` battery getters directly in Objective-C.
int island_bt_get_battery_percent(const char *addressOrNameCStr) {
    @autoreleasepool {
        NSString *target = addressOrNameCStr ? [NSString stringWithUTF8String:addressOrNameCStr] : @"";
        NSString *lowerTarget = [target lowercaseString];

        NSArray *paired = [IOBluetoothDevice pairedDevices];
        if (!paired) return -1;

        for (IOBluetoothDevice *dev in paired) {
            if (![dev isKindOfClass:[IOBluetoothDevice class]]) continue;

            NSString *addr = [[dev addressString] lowercaseString] ?: @"";
            NSString *name = [[dev name] lowercaseString] ?: @"";

            BOOL matches = (lowerTarget.length == 0) ||
                           [addr isEqualToString:lowerTarget] ||
                           [name isEqualToString:lowerTarget] ||
                           (name.length > 0 && [lowerTarget containsString:name]) ||
                           (lowerTarget.length > 0 && [name containsString:lowerTarget]);

            if (!matches) continue;
            if (lowerTarget.length == 0 && ![dev isConnected]) continue;

            int best = -1;
            if ([dev respondsToSelector:@selector(batteryPercentSingle)]) {
                uint8_t val = [dev batteryPercentSingle];
                if (val > 0 && val <= 100) best = (int)val;
            }
            if (best <= 0 && [dev respondsToSelector:@selector(batteryPercentCombined)]) {
                uint8_t val = [dev batteryPercentCombined];
                if (val > 0 && val <= 100) best = (int)val;
            }
            if (best <= 0) {
                int left = 0, right = 0;
                if ([dev respondsToSelector:@selector(batteryPercentLeft)]) {
                    left = (int)[dev batteryPercentLeft];
                }
                if ([dev respondsToSelector:@selector(batteryPercentRight)]) {
                    right = (int)[dev batteryPercentRight];
                }
                if (left > 0 && right > 0) {
                    best = MIN(left, right);
                } else if (left > 0) {
                    best = left;
                } else if (right > 0) {
                    best = right;
                }
            }

            if (best > 0 && best <= 100) {
                return best;
            }
        }
        return -1;
    }
}

void island_bt_print_battery_percent(void) {
    const char *filter = getenv("ISLAND_BT_QUERY");
    int pct = island_bt_get_battery_percent(filter);
    printf("%d\n", pct);
    fflush(stdout);
}

static void *loadMediaRemote(void) {
    static void *handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    });
    return handle;
}

int island_mr_send_command(int command) {
    void *handle = loadMediaRemote();
    if (!handle) return 0;
    MRMediaRemoteSendCommandFn fn = (MRMediaRemoteSendCommandFn)dlsym(handle, "MRMediaRemoteSendCommand");
    if (!fn) return 0;
    Boolean ok = fn(command, nil);
    usleep(80000);
    return ok ? 1 : 0;
}

void island_mr_send_command_play(void) { island_mr_send_command(0); }
void island_mr_send_command_pause(void) { island_mr_send_command(1); }
void island_mr_send_command_toggle(void) { island_mr_send_command(2); }
void island_mr_send_command_next(void) { island_mr_send_command(4); }
void island_mr_send_command_prev(void) { island_mr_send_command(5); }

int island_mr_seek_to(double seconds) {
    void *handle = loadMediaRemote();
    if (!handle) return 0;
    MRMediaRemoteSetElapsedTimeFn fn = (MRMediaRemoteSetElapsedTimeFn)dlsym(handle, "MRMediaRemoteSetElapsedTime");
    if (!fn) return 0;
    fn(seconds);
    return 1;
}

void island_mr_query_now_playing_json(void) {
    @autoreleasepool {
        void *handle = loadMediaRemote();
        if (!handle) {
            printf("{}\n");
            fflush(stdout);
            return;
        }

        MRMediaRemoteGetNowPlayingInfoFn getInfo = (MRMediaRemoteGetNowPlayingInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        MRMediaRemoteGetNowPlayingApplicationIsPlayingFn getPlaying = (MRMediaRemoteGetNowPlayingApplicationIsPlayingFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");

        if (!getInfo || !getPlaying) {
            printf("{}\n");
            fflush(stdout);
            return;
        }

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSDictionary *nowPlayingInfo = nil;
        __block Boolean playingState = false;

        dispatch_queue_t bgQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

        getPlaying(bgQueue, ^(Boolean isPlaying) {
            playingState = isPlaying;
            getInfo(bgQueue, ^(NSDictionary *info) {
                nowPlayingInfo = [info copy];
                dispatch_semaphore_signal(sem);
            });
        });

        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC));
        dispatch_semaphore_wait(sem, timeout);

        if (!nowPlayingInfo || nowPlayingInfo.count == 0) {
            printf("{}\n");
            fflush(stdout);
            return;
        }

        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        NSString *title = nowPlayingInfo[@"kMRMediaRemoteNowPlayingInfoTitle"];
        NSString *artist = nowPlayingInfo[@"kMRMediaRemoteNowPlayingInfoArtist"];
        NSString *album = nowPlayingInfo[@"kMRMediaRemoteNowPlayingInfoAlbum"];
        NSNumber *duration = nowPlayingInfo[@"kMRMediaRemoteNowPlayingInfoDuration"];
        NSNumber *elapsed = nowPlayingInfo[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
        NSNumber *rate = nowPlayingInfo[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
        NSDate *timestampDate = nowPlayingInfo[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        NSData *artworkData = nowPlayingInfo[@"kMRMediaRemoteNowPlayingInfoArtworkData"];

        if (title) out[@"title"] = title;
        if (artist) out[@"artist"] = artist;
        if (album) out[@"album"] = album;
        if (duration) out[@"duration"] = duration;

        BOOL isPlaying = playingState || (rate != nil && [rate doubleValue] > 0.01);
        out[@"isPlaying"] = @(isPlaying);

        double baseElapsed = elapsed ? [elapsed doubleValue] : 0.0;
        double playbackRate = rate ? [rate doubleValue] : (isPlaying ? 1.0 : 0.0);
        if (isPlaying && timestampDate && [timestampDate isKindOfClass:[NSDate class]]) {
            NSTimeInterval delta = [[NSDate date] timeIntervalSinceDate:timestampDate];
            if (delta > 0 && delta < 36000) {
                baseElapsed += delta * (playbackRate > 0.01 ? playbackRate : 1.0);
            }
        }
        out[@"elapsedTime"] = @(baseElapsed);
        out[@"appName"] = @"Now Playing";

        if (artworkData && [artworkData isKindOfClass:[NSData class]] && artworkData.length > 0 && artworkData.length < 4 * 1024 * 1024) {
            out[@"artworkBase64"] = [artworkData base64EncodedStringWithOptions:0];
        }

        NSError *err = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:out options:0 error:&err];
        if (jsonData && !err) {
            NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
            printf("%s\n", [jsonStr UTF8String]);
        } else {
            printf("{}\n");
        }
        fflush(stdout);
    }
}

// MARK: - AirDrop Outgoing Node Helper Functions (SFAirDropNode)

CGImageRef island_airdrop_node_copy_display_icon(id node) {
    if (!node) return NULL;
    SEL sel = NSSelectorFromString(@"displayIcon");
    if (![node respondsToSelector:sel]) return NULL;
    typedef CGImageRef (*DisplayIconFn)(id, SEL);
    DisplayIconFn fn = (DisplayIconFn)objc_msgSend;
    CGImageRef img = fn(node, sel);
    if (img) {
        CGImageRetain(img);
    }
    return img;
}

int island_airdrop_node_start_send(
    id node,
    NSString *bundleID,
    NSString *sessionID,
    NSArray *items,
    NSString *desc,
    CGImageRef previewImage
) {
    if (!node) return 0;
    SEL sel = NSSelectorFromString(@"startSendForBundleID:sessionID:items:description:previewImage:fromShareSheet:");
    if (![node respondsToSelector:sel]) return 0;
    typedef void (*StartSendFn)(id, SEL, NSString *, NSString *, NSArray *, NSString *, CGImageRef, BOOL);
    StartSendFn fn = (StartSendFn)objc_msgSend;
    fn(node, sel, bundleID, sessionID, items, desc, previewImage, NO);
    return 1;
}

int island_airdrop_node_cancel_send(id node) {
    if (!node) return 0;
    SEL sel = NSSelectorFromString(@"cancelSend");
    if (![node respondsToSelector:sel]) return 0;
    typedef void (*CancelSendFn)(id, SEL);
    CancelSendFn fn = (CancelSendFn)objc_msgSend;
    fn(node, sel);
    return 1;
}

