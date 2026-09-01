#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <limits.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdint.h>
#import <unistd.h>

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef, void *, int, double, int);
typedef MTDeviceRef (*MTDeviceCreateDefaultFunction)(void);
typedef CFArrayRef (*MTDeviceCreateListFunction)(void);
typedef int (*MTRegisterContactFrameCallbackFunction)(MTDeviceRef, MTContactCallbackFunction);
typedef int (*MTDeviceStartFunction)(MTDeviceRef, int);
typedef BOOL (*MTDeviceIsBuiltInFunction)(MTDeviceRef);

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t pathIndex;
    uint32_t state;
    int32_t fingerID, handID;
    MTVector normalizedVector;
    float zTotal;
    int32_t field9;
    float angle, majorAxis, minorAxis;
    MTVector absoluteVector;
    int32_t field14, field15;
    float zDensity;
} MTTouch;

typedef enum {
    MTTouchStateMakeTouch = 3,
    MTTouchStateTouching = 4,
    MTTouchStateBreakTouch = 5,
} MTTouchState;

typedef enum {
    DragPhaseIdle,
    DragPhaseCandidate,
    DragPhaseStarting,
    DragPhaseOwned,
    DragPhaseReleasing,
} DragPhase;

typedef enum {
    ReleaseOutcomeWaiting,
    ReleaseOutcomeFirstTap,
    ReleaseOutcomeSecondTapNoDrag,
    ReleaseOutcomeStarting,
    ReleaseOutcomeOwned,
    ReleaseOutcomeReleased,
    ReleaseOutcomeInterrupted,
    ReleaseOutcomeInvalid,
    ReleaseOutcomeNativeDraggingOn,
} ReleaseOutcome;

typedef enum {
    DiagnosticRawStart,
    DiagnosticFirstTap,
    DiagnosticSecondContact,
    DiagnosticMovement,
    DiagnosticSyntheticDown,
    DiagnosticSyntheticDrag,
    DiagnosticSyntheticUp,
    DiagnosticNativePassed,
    DiagnosticNativeFiltered,
    DiagnosticReset,
    DiagnosticConfiguration,
    DiagnosticFailure,
} DiagnosticKind;

typedef enum {
    ReasonNone,
    ReasonFirstTap,
    ReasonSecondTap,
    ReasonMovement,
    ReasonLift,
    ReasonNoMovement,
    ReasonMultiFinger,
    ReasonDisabled,
    ReasonNativeDragging,
    ReasonEventTapDisabled,
    ReasonStale,
    ReasonQuickReleaseAborted,
    ReasonHold,
    ReasonTapTooLong,
    ReasonTapMoved,
    ReasonIntertapExpired,
} DiagnosticReason;

typedef enum { NativePass, NativeFilter, NativeReplaceDrag } NativeDisposition;

typedef struct {
    MTDeviceRef device;
    int touchingCount, maximumTouching;
    BOOL touchMade, touchInvalid;
    int touchingFrames;
    double touchStartedTimestamp;
    MTPoint touchStartedPosition, touchStartedAbsolutePosition;
    int32_t pathIndex, fingerID;
    BOOL identityValid;
    CGPoint pointerStart;
    BOOL pointerStartValid;
    BOOL touchMoved;
    float maximumSquaredDistance, maximumSquaredDistanceMM;
    BOOL firstTapPending;
    double firstTapCompletedTimestamp;
    BOOL chainCandidate;
    unsigned long long chainGeneration;
    BOOL movementConfirmed, holdConfirmed, startRequested;
} DeviceState;

typedef struct {
    DragPhase phase;
    unsigned long long generation;
    MTDeviceRef device;
    int64_t eventNumber;
    long long downNotBeforeMillis;
    CGPoint start, latest;
    BOOL startValid, latestValid;
} DragChain;

typedef struct {
    DragPhase phase;
    unsigned long long generation;
    MTDeviceRef device;
    int64_t eventNumber;
} ChainSnapshot;

typedef struct {
    uint64_t sequence, machTime, generation, eventTimestamp;
    int64_t wallMillis, eventNumber, sourceUserData;
    int32_t phase, kind, reason, eventType, clickState, x, y;
    int32_t durationMillis, intertapMillis, motionMilliMillimeters;
    int32_t frames, maximumContacts, moved, invalid;
    int32_t nativeDragging;
} DiagnosticRecord;

enum {
    MaximumDevices = 16,
    DiagnosticCapacity = 2048,
    AutomaticLogLimit = 12,
    SyntheticEventNumberMinimum = 1,
    SyntheticEventNumberMaximum = INT16_MAX,
};

static atomic_bool gEnabled = true;
static atomic_bool gOverrideEnabled = true;
static atomic_ullong gOverrideMask = kCGEventFlagMaskAlternate;
static atomic_bool gReplacementEnabled = false;
static atomic_ullong gFeatureEpoch = 1;
static atomic_bool gInternalDraggingPresent = false;
static atomic_bool gInternalDraggingEnabled = true;
static atomic_bool gBluetoothDraggingPresent = false;
static atomic_bool gBluetoothDraggingEnabled = true;
static atomic_bool gAnyNativeDraggingEnabled = true;
static atomic_llong gLastThreeFingerReleaseMillis = 0;
static atomic_int gLastOutcome = ReleaseOutcomeWaiting;
static atomic_int gLastDurationMillis = 0;
static atomic_int gLastFrames = 0;
static atomic_int gLastMaximumContacts = 0;
static atomic_bool gLastMoved = false;
static atomic_bool gLastInvalid = false;

static os_unfair_lock gStateLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock gChainLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock gSyntheticLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock gDiagnosticLock = OS_UNFAIR_LOCK_INIT;
static DeviceState gDevices[MaximumDevices];
static int gDeviceCount = 0;
static DragChain gChain = {.phase = DragPhaseIdle, .generation = 1};
static uint64_t gNextEventNumber = SyntheticEventNumberMinimum;
static CGEventSourceRef gSyntheticSource = NULL;
static CFMachPortRef gEventTap = NULL;
static CFRunLoopSourceRef gEventTapSource = NULL;
static MTDeviceIsBuiltInFunction gDeviceIsBuiltIn = NULL;

static DiagnosticRecord gRecords[DiagnosticCapacity];
static uint64_t gRecordSequence = 0;
static atomic_uint gDroppedRecords = 0;
static atomic_bool gLoggingActive = false;
static atomic_bool gLoggingDirty = false;
static atomic_bool gLoggingFaulted = false;
static dispatch_queue_t gLoggingQueue = NULL;
static dispatch_source_t gLoggingTimer = NULL;
static NSURL *gAutomaticLogURL = nil;

static NSString *const OverrideEnabledKey = @"ShiftOverrideEnabled";
static NSString *const OverrideModifierKey = @"OverrideModifier";
static NSString *const ReplacementEnabledKey = @"DoubleTapDragReleaseEnabled";
static NSString *const ModifierShift = @"Shift";
static NSString *const ModifierControl = @"Control";
static NSString *const ModifierOption = @"Option";
static NSString *const ModifierFn = @"Fn";
static const int64_t ThreeFingerTag = 0x334644334655504DLL;
static const int64_t DoubleTapTag = 0x3346444E45574452LL;
static const long long MinimumReleaseIntervalMillis = 80;
static const long long MaximumSecondTapGapMillis = 600;
static const long long SecondContactHoldMillis = 180;
static const double MaximumFirstTapDurationSeconds = 0.25;
static const float TapMoveThresholdMillimeters = 1.3f;
static const float FallbackNormalizedMoveThreshold = 0.010f;
static const long long FirstClickAllowanceMillis = 40;

static long long nowMillis(void) {
    return (long long)(CFAbsoluteTimeGetCurrent() * 1000.0);
}

static long long doubleClickIntervalMillis(void) {
    return MAX(1LL, (long long)([NSEvent doubleClickInterval] * 1000.0));
}

static long long doubleTapDragGapForSystemMillis(long long systemInterval) {
    return MIN(MAX(1LL, systemInterval), MaximumSecondTapGapMillis);
}

static long long doubleTapDragGapMillis(void) {
    return doubleTapDragGapForSystemMillis(doubleClickIntervalMillis());
}

static CGEventFlags modifierMaskForName(NSString *name) {
    if ([name isEqualToString:ModifierShift]) return kCGEventFlagMaskShift;
    if ([name isEqualToString:ModifierControl]) return kCGEventFlagMaskControl;
    if ([name isEqualToString:ModifierFn]) return kCGEventFlagMaskSecondaryFn;
    return kCGEventFlagMaskAlternate;
}

static BOOL overrideIsHeld(void) {
    return atomic_load(&gOverrideEnabled) &&
        (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) &
         atomic_load(&gOverrideMask));
}

static BOOL claimReleaseSlot(atomic_llong *lastRelease) {
    long long current = nowMillis();
    long long previous = atomic_load(lastRelease);
    for (;;) {
        if (current - previous < MinimumReleaseIntervalMillis) return NO;
        if (atomic_compare_exchange_weak(lastRelease, &previous, current)) return YES;
    }
}

static BOOL copyPointerLocation(CGPoint *location) {
    CGEventRef event = CGEventCreate(NULL);
    if (event == NULL) return NO;
    *location = CGEventGetLocation(event);
    CFRelease(event);
    return YES;
}

static int64_t nextEventNumberLocked(void) {
    uint64_t value = gNextEventNumber;
    if (value < SyntheticEventNumberMinimum || value > SyntheticEventNumberMaximum) {
        value = SyntheticEventNumberMinimum;
    }
    gNextEventNumber = value == SyntheticEventNumberMaximum
        ? SyntheticEventNumberMinimum : value + 1;
    return (int64_t)value;
}

static CGEventRef createTaggedEvent(CGEventType type, CGPoint location, int64_t number) {
    if (gSyntheticSource == NULL) return NULL;
    CGEventRef event = CGEventCreateMouseEvent(gSyntheticSource, type, location,
                                               kCGMouseButtonLeft);
    if (event == NULL) return NULL;
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, DoubleTapTag);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventSetIntegerValueField(event, kCGMouseEventNumber, number);
    return event;
}

static BOOL ownEvent(CGEventRef event) {
    return event != NULL &&
        CGEventGetIntegerValueField(event, kCGEventSourceUserData) == DoubleTapTag;
}

static NSString *phaseName(DragPhase phase) {
    switch (phase) {
        case DragPhaseIdle: return @"idle";
        case DragPhaseCandidate: return @"candidate";
        case DragPhaseStarting: return @"starting";
        case DragPhaseOwned: return @"owned";
        case DragPhaseReleasing: return @"releasing";
    }
    return @"unknown";
}

static NSString *kindName(DiagnosticKind kind) {
    switch (kind) {
        case DiagnosticRawStart: return @"raw_contact_started";
        case DiagnosticFirstTap: return @"first_tap";
        case DiagnosticSecondContact: return @"second_contact";
        case DiagnosticMovement: return @"movement_confirmed";
        case DiagnosticSyntheticDown: return @"synthetic_down";
        case DiagnosticSyntheticDrag: return @"synthetic_drag";
        case DiagnosticSyntheticUp: return @"synthetic_up";
        case DiagnosticNativePassed: return @"native_button_passed";
        case DiagnosticNativeFiltered: return @"native_event_filtered";
        case DiagnosticReset: return @"chain_reset";
        case DiagnosticConfiguration: return @"configuration";
        case DiagnosticFailure: return @"failure";
    }
    return @"unknown";
}

static NSString *reasonName(DiagnosticReason reason) {
    switch (reason) {
        case ReasonNone: return @"none";
        case ReasonFirstTap: return @"first_tap";
        case ReasonSecondTap: return @"second_tap";
        case ReasonMovement: return @"movement";
        case ReasonLift: return @"lift";
        case ReasonNoMovement: return @"no_movement";
        case ReasonMultiFinger: return @"multi_finger";
        case ReasonDisabled: return @"disabled";
        case ReasonNativeDragging: return @"native_dragging_enabled";
        case ReasonEventTapDisabled: return @"event_tap_disabled";
        case ReasonStale: return @"stale_generation";
        case ReasonQuickReleaseAborted: return @"quick_release_aborted";
        case ReasonHold: return @"hold_timeout";
        case ReasonTapTooLong: return @"tap_too_long";
        case ReasonTapMoved: return @"tap_moved";
        case ReasonIntertapExpired: return @"intertap_expired";
    }
    return @"unknown";
}

static void recordDiagnosticDetails(DiagnosticKind kind, DiagnosticReason reason,
                                    unsigned long long generation, DragPhase phase,
                                    CGEventRef event, CGPoint location,
                                    int duration, int intertap, float motionMillimeters,
                                    int frames, int contacts, BOOL moved, BOOL invalid) {
    if (!os_unfair_lock_trylock(&gDiagnosticLock)) {
        atomic_fetch_add(&gDroppedRecords, 1);
        return;
    }
    uint64_t sequence = gRecordSequence++;
    gRecords[sequence % DiagnosticCapacity] = (DiagnosticRecord){
        .sequence = sequence, .machTime = mach_absolute_time(),
        .generation = generation, .wallMillis = nowMillis(), .phase = phase,
        .kind = kind, .reason = reason,
        .eventType = event == NULL ? kCGEventNull : (int32_t)CGEventGetType(event),
        .clickState = event == NULL ? 0 : (int32_t)CGEventGetIntegerValueField(event, kCGMouseEventClickState),
        .eventNumber = event == NULL ? 0 : CGEventGetIntegerValueField(event, kCGMouseEventNumber),
        .sourceUserData = event == NULL ? 0 : CGEventGetIntegerValueField(event, kCGEventSourceUserData),
        .eventTimestamp = event == NULL ? 0 : CGEventGetTimestamp(event),
        .x = (int32_t)llround(location.x), .y = (int32_t)llround(location.y),
        .durationMillis = duration, .intertapMillis = intertap,
        .motionMilliMillimeters = isfinite(motionMillimeters)
            ? (int32_t)llround(motionMillimeters * 1000.0f) : -1,
        .frames = frames, .maximumContacts = contacts,
        .moved = moved, .invalid = invalid,
        .nativeDragging = atomic_load(&gAnyNativeDraggingEnabled),
    };
    os_unfair_lock_unlock(&gDiagnosticLock);
    atomic_store(&gLoggingDirty, true);
}

static void recordDiagnostic(DiagnosticKind kind, DiagnosticReason reason,
                             unsigned long long generation, DragPhase phase,
                             CGEventRef event, CGPoint location,
                             int duration, int frames, int contacts,
                             BOOL moved, BOOL invalid) {
    recordDiagnosticDetails(kind, reason, generation, phase, event, location,
                            duration, -1, NAN, frames, contacts, moved, invalid);
}

static size_t copyRecords(DiagnosticRecord *output, size_t capacity,
                          unsigned int *dropped) {
    os_unfair_lock_lock(&gDiagnosticLock);
    uint64_t available = MIN(gRecordSequence, (uint64_t)DiagnosticCapacity);
    size_t count = MIN((size_t)available, capacity);
    uint64_t first = gRecordSequence - count;
    for (size_t i = 0; i < count; i++) output[i] = gRecords[(first + i) % DiagnosticCapacity];
    if (dropped != NULL) *dropped = atomic_load(&gDroppedRecords);
    os_unfair_lock_unlock(&gDiagnosticLock);
    return count;
}

static void clearRecords(void) {
    os_unfair_lock_lock(&gDiagnosticLock);
    gRecordSequence = 0;
    memset(gRecords, 0, sizeof(gRecords));
    atomic_store(&gDroppedRecords, 0);
    os_unfair_lock_unlock(&gDiagnosticLock);
    atomic_store(&gLoggingDirty, true);
}

static NSDictionary *recordDictionary(DiagnosticRecord r) {
    return @{@"sequence": @(r.sequence), @"mach_time": @(r.machTime),
             @"wall_ms": @(r.wallMillis), @"generation": @(r.generation),
             @"phase": phaseName((DragPhase)r.phase),
             @"kind": kindName((DiagnosticKind)r.kind),
             @"reason": reasonName((DiagnosticReason)r.reason),
             @"event_type": @(r.eventType), @"click_state": @(r.clickState),
             @"mouse_event_number": @(r.eventNumber),
             @"source_user_data": @(r.sourceUserData),
             @"event_timestamp": @(r.eventTimestamp), @"x": @(r.x), @"y": @(r.y),
             @"touch_duration_ms": @(r.durationMillis), @"intertap_ms": @(r.intertapMillis),
             @"motion_mm": r.motionMilliMillimeters < 0
                ? @(-1) : @((double)r.motionMilliMillimeters / 1000.0),
             @"touching_frames": @(r.frames),
             @"maximum_touching_contacts": @(r.maximumContacts),
             @"touch_moved": @(r.moved != 0), @"touch_invalid": @(r.invalid != 0),
             @"native_dragging_enabled": @(r.nativeDragging != 0)};
}

static NSString *traceText(NSString *capture) {
    DiagnosticRecord *records = calloc(DiagnosticCapacity, sizeof(*records));
    if (records == NULL) return @"";
    unsigned int dropped = 0;
    size_t count = copyRecords(records, DiagnosticCapacity, &dropped);
    NSMutableString *text = [NSMutableString string];
    NSDictionary *header = @{@"capture": capture ?: @"unknown", @"pid": @(getpid()),
        @"version": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
        @"build": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
        @"records": @(count), @"dropped": @(dropped),
        @"system_double_click_ms": @(doubleClickIntervalMillis()),
        @"double_tap_drag_gap_ms": @(doubleTapDragGapMillis()),
        @"first_tap_max_ms": @((int)llround(MaximumFirstTapDurationSeconds * 1000.0)),
        @"second_contact_hold_ms": @(SecondContactHoldMillis),
        @"movement_threshold_mm": @(TapMoveThresholdMillimeters)};
    NSMutableArray *objects = [NSMutableArray arrayWithObject:header];
    for (size_t i = 0; i < count; i++) [objects addObject:recordDictionary(records[i])];
    for (NSDictionary *object in objects) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
        if (data != nil) [text appendFormat:@"%@\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
    }
    free(records);
    return text;
}

static NSURL *logDirectoryURL(void) {
    NSURL *library = [[[NSFileManager defaultManager] URLsForDirectory:NSLibraryDirectory
                                                              inDomains:NSUserDomainMask] firstObject];
    return [[[library URLByAppendingPathComponent:@"Logs" isDirectory:YES]
             URLByAppendingPathComponent:@"3FDragUnstuck" isDirectory:YES]
            URLByAppendingPathComponent:@"DoubleTap" isDirectory:YES];
}

static void pruneLogs(NSURL *directory) {
    NSArray<NSURL *> *files = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:directory includingPropertiesForKeys:@[NSURLContentModificationDateKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    files = [files filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *_) {
        (void)_; return [url.lastPathComponent hasPrefix:@"double-tap-"] && [url.pathExtension isEqualToString:@"jsonl"];
    }]];
    files = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *ad = nil, *bd = nil;
        [a getResourceValue:&ad forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&bd forKey:NSURLContentModificationDateKey error:nil];
        return [bd ?: [NSDate distantPast] compare:ad ?: [NSDate distantPast]];
    }];
    for (NSUInteger i = AutomaticLogLimit; i < files.count; i++)
        [[NSFileManager defaultManager] removeItemAtURL:files[i] error:nil];
}

static void persistTrace(void) {
    if (!atomic_load(&gLoggingActive) || gAutomaticLogURL == nil ||
        !atomic_exchange(&gLoggingDirty, false)) return;
    NSData *data = [traceText(@"automatic") dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil || ![data writeToURL:gAutomaticLogURL options:NSDataWritingAtomic error:nil]) {
        atomic_store(&gLoggingFaulted, true);
        atomic_store(&gLoggingDirty, true);
    } else {
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0600)}
                                        ofItemAtPath:gAutomaticLogURL.path error:nil];
    }
}

static void startLogging(void) {
    if (atomic_exchange(&gLoggingActive, true)) return;
    atomic_store(&gLoggingFaulted, false);
    NSURL *directory = logDirectoryURL();
    [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @(0700)} error:nil];
    gAutomaticLogURL = [directory URLByAppendingPathComponent:[NSString stringWithFormat:
        @"double-tap-%@-pid%d.jsonl", NSUUID.UUID.UUIDString, getpid()]];
    pruneLogs(directory);
    if (gLoggingQueue == NULL) gLoggingQueue = dispatch_queue_create("io.github.efilo1.3FDragUnstuck.logs", DISPATCH_QUEUE_SERIAL);
    gLoggingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gLoggingQueue);
    dispatch_source_set_timer(gLoggingTimer, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                              250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gLoggingTimer, ^{ persistTrace(); });
    dispatch_resume(gLoggingTimer);
    atomic_store(&gLoggingDirty, true);
}

static void stopLogging(void) {
    if (!atomic_exchange(&gLoggingActive, false)) return;
    atomic_store(&gLoggingActive, true);
    if (gLoggingQueue != NULL) dispatch_sync(gLoggingQueue, ^{ persistTrace(); });
    atomic_store(&gLoggingActive, false);
    if (gLoggingTimer != NULL) { dispatch_source_cancel(gLoggingTimer); gLoggingTimer = NULL; }
}

static BOOL readDraggingPreference(NSString *domain, BOOL *present) {
    id value = [[[NSUserDefaults standardUserDefaults] persistentDomainForName:domain] objectForKey:@"Dragging"];
    if (present != NULL) *present = value != nil;
    return value != nil && [value boolValue];
}

static BOOL nativeDraggingForDevice(MTDeviceRef device) {
    BOOL internalPresent = atomic_load(&gInternalDraggingPresent);
    BOOL bluetoothPresent = atomic_load(&gBluetoothDraggingPresent);
    if (device != NULL && gDeviceIsBuiltIn != NULL) {
        BOOL builtIn = gDeviceIsBuiltIn(device);
        if (builtIn && internalPresent) return atomic_load(&gInternalDraggingEnabled);
        if (!builtIn && bluetoothPresent) return atomic_load(&gBluetoothDraggingEnabled);
    }
    if (!internalPresent && !bluetoothPresent) return YES;
    return (internalPresent && atomic_load(&gInternalDraggingEnabled)) ||
        (bluetoothPresent && atomic_load(&gBluetoothDraggingEnabled));
}

static BOOL replacementActive(MTDeviceRef device) {
    return atomic_load(&gEnabled) && atomic_load(&gReplacementEnabled) &&
        !nativeDraggingForDevice(device);
}

static void refreshDraggingPreferences(void) {
    BOOL ip = NO, bp = NO;
    BOOL ie = readDraggingPreference(@"com.apple.AppleMultitouchTrackpad", &ip);
    BOOL be = readDraggingPreference(@"com.apple.driver.AppleBluetoothMultitouch.trackpad", &bp);
    atomic_store(&gInternalDraggingPresent, ip); atomic_store(&gInternalDraggingEnabled, ie);
    atomic_store(&gBluetoothDraggingPresent, bp); atomic_store(&gBluetoothDraggingEnabled, be);
    BOOL any = NO;
    os_unfair_lock_lock(&gStateLock);
    if (gDeviceCount == 0) any = (!ip && !bp) || (ip && ie) || (bp && be);
    for (int i = 0; i < gDeviceCount; i++) any = any || nativeDraggingForDevice(gDevices[i].device);
    os_unfair_lock_unlock(&gStateLock);
    atomic_store(&gAnyNativeDraggingEnabled, any);
    recordDiagnostic(DiagnosticConfiguration, any ? ReasonNativeDragging : ReasonNone,
                     0, DragPhaseIdle, NULL, CGPointZero, 0, 0, 0, NO, NO);
}

static DeviceState *deviceStateLocked(MTDeviceRef device) {
    for (int i = 0; i < gDeviceCount; i++) if (gDevices[i].device == device) return &gDevices[i];
    return NULL;
}

static void resetCurrentTouch(DeviceState *s) {
    s->touchMade = s->touchInvalid = s->identityValid = s->pointerStartValid = NO;
    s->touchingFrames = 0; s->touchStartedTimestamp = 0;
    s->touchStartedPosition = s->touchStartedAbsolutePosition = (MTPoint){0, 0};
    s->pathIndex = s->fingerID = 0;
    s->pointerStart = CGPointZero; s->touchMoved = NO;
    s->maximumSquaredDistance = s->maximumSquaredDistanceMM = 0;
    s->chainCandidate = NO; s->chainGeneration = 0;
    s->movementConfirmed = s->holdConfirmed = s->startRequested = NO;
}

static void resetDevice(DeviceState *s) {
    resetCurrentTouch(s); s->touchingCount = s->maximumTouching = 0;
    s->firstTapPending = NO; s->firstTapCompletedTimestamp = 0;
}

static void resetAllDevicesLocked(void) {
    for (int i = 0; i < gDeviceCount; i++) resetDevice(&gDevices[i]);
}

static BOOL actualTouch(uint32_t state) {
    return state == MTTouchStateMakeTouch || state == MTTouchStateTouching;
}

static int touchingCount(const void *contacts, int count) {
    if (contacts == NULL || count <= 0) return 0;
    const MTTouch *touches = contacts; int result = 0;
    for (int i = 0; i < count; i++) if (actualTouch(touches[i].state)) result++;
    return result;
}

static BOOL frameContainsIdentity(const DeviceState *s, const void *contacts, int count) {
    if (!s->identityValid || contacts == NULL) return NO;
    const MTTouch *touches = contacts;
    for (int i = 0; i < count; i++) if (actualTouch(touches[i].state) &&
        touches[i].pathIndex == s->pathIndex && touches[i].fingerID == s->fingerID) return YES;
    return NO;
}

static BOOL frameReplacesIdentity(const DeviceState *s, const void *contacts, int count) {
    if (!s->identityValid || contacts == NULL) return NO;
    const MTTouch *touches = contacts; BOOL broke = NO, made = NO;
    for (int i = 0; i < count; i++) {
        broke = broke || (touches[i].state == MTTouchStateBreakTouch &&
            touches[i].pathIndex == s->pathIndex && touches[i].fingerID == s->fingerID);
        made = made || touches[i].state == MTTouchStateMakeTouch;
    }
    return broke && made;
}

static void observePosition(DeviceState *s, MTPoint position, MTPoint absolutePosition) {
    float dx = position.x - s->touchStartedPosition.x;
    float dy = position.y - s->touchStartedPosition.y;
    float distance = dx * dx + dy * dy;
    s->maximumSquaredDistance = MAX(s->maximumSquaredDistance, distance);
    float mmX = absolutePosition.x - s->touchStartedAbsolutePosition.x;
    float mmY = absolutePosition.y - s->touchStartedAbsolutePosition.y;
    float distanceMM = mmX * mmX + mmY * mmY;
    if (isfinite(distanceMM)) s->maximumSquaredDistanceMM = MAX(s->maximumSquaredDistanceMM, distanceMM);
    if (distanceMM >= TapMoveThresholdMillimeters * TapMoveThresholdMillimeters ||
        distance >= FallbackNormalizedMoveThreshold * FallbackNormalizedMoveThreshold)
        s->touchMoved = YES;
}

static void observeBreak(DeviceState *s, const void *contacts, int count) {
    if (!s->identityValid || contacts == NULL) return;
    const MTTouch *touches = contacts;
    for (int i = 0; i < count; i++) if (touches[i].state == MTTouchStateBreakTouch &&
        touches[i].pathIndex == s->pathIndex && touches[i].fingerID == s->fingerID) {
        observePosition(s, touches[i].normalizedVector.position,
                        touches[i].absoluteVector.position); return;
    }
}

static void observeFrame(DeviceState *s, const void *contacts, int count, double timestamp) {
    if (contacts == NULL) return;
    const MTTouch *touches = contacts; const MTTouch *primary = NULL; int actual = 0;
    for (int i = 0; i < count; i++) if (actualTouch(touches[i].state)) {
        actual++; if (primary == NULL) primary = &touches[i];
    }
    if (actual > 1) { s->touchInvalid = YES; return; }
    if (primary == NULL) return;
    if (!s->touchMade) {
        s->touchMade = YES; s->touchStartedTimestamp = timestamp;
        s->touchStartedPosition = primary->normalizedVector.position;
        s->touchStartedAbsolutePosition = primary->absoluteVector.position;
        s->pathIndex = primary->pathIndex; s->fingerID = primary->fingerID;
        s->identityValid = YES; s->pointerStartValid = copyPointerLocation(&s->pointerStart);
    }
    if (primary->state == MTTouchStateTouching) {
        s->touchingFrames++;
        observePosition(s, primary->normalizedVector.position,
                        primary->absoluteVector.position);
    }
}

static ChainSnapshot chainSnapshot(void) {
    os_unfair_lock_lock(&gChainLock);
    ChainSnapshot s = {gChain.phase, gChain.generation, gChain.device, gChain.eventNumber};
    os_unfair_lock_unlock(&gChainLock); return s;
}

static void clearChainLocked(void) {
    gChain.phase = DragPhaseIdle; gChain.device = NULL; gChain.eventNumber = 0;
    gChain.downNotBeforeMillis = 0; gChain.start = gChain.latest = CGPointZero;
    gChain.startValid = gChain.latestValid = NO;
}

static void resetChainLocked(DiagnosticReason reason) {
    unsigned long long generation = gChain.generation; DragPhase phase = gChain.phase;
    gChain.generation++; clearChainLocked();
    recordDiagnostic(DiagnosticReset, reason, generation, phase, NULL, CGPointZero, 0, 0, 0, NO, NO);
}

static BOOL resetChain(unsigned long long generation, DiagnosticReason reason) {
    os_unfair_lock_lock(&gChainLock); BOOL current = gChain.generation == generation;
    if (current) resetChainLocked(reason); os_unfair_lock_unlock(&gChainLock); return current;
}

static BOOL beginSecondContact(MTDeviceRef device, CGPoint start, BOOL valid,
                               int intertapMillis, unsigned long long *generation) {
    os_unfair_lock_lock(&gChainLock); BOOL accepted = gChain.phase == DragPhaseIdle;
    if (accepted) {
        gChain.generation++; gChain.phase = DragPhaseCandidate; gChain.device = device;
        gChain.eventNumber = 0; gChain.downNotBeforeMillis = nowMillis() + FirstClickAllowanceMillis;
        gChain.start = gChain.latest = start; gChain.startValid = gChain.latestValid = valid;
        *generation = gChain.generation;
    }
    os_unfair_lock_unlock(&gChainLock);
    if (accepted) recordDiagnosticDetails(DiagnosticSecondContact, ReasonSecondTap, *generation,
        DragPhaseCandidate, NULL, start, 0, intertapMillis, 0, 0, 1, NO, NO);
    return accepted;
}

static BOOL promoteContact(MTDeviceRef device, unsigned long long generation,
                           CGPoint latest, BOOL valid, DiagnosticReason reason,
                           long long *notBefore) {
    os_unfair_lock_lock(&gChainLock);
    BOOL accepted = gChain.generation == generation && gChain.device == device &&
        (gChain.phase == DragPhaseCandidate || gChain.phase == DragPhaseStarting);
    if (accepted) {
        gChain.phase = DragPhaseStarting;
        if (valid) { gChain.latest = latest; gChain.latestValid = YES; }
        *notBefore = gChain.downNotBeforeMillis;
    }
    os_unfair_lock_unlock(&gChainLock);
    if (accepted) recordDiagnostic(DiagnosticMovement, reason, generation,
        DragPhaseStarting, NULL, latest, 0, 0, 1, YES, NO);
    return accepted;
}

static void updateChainLocation(unsigned long long generation, CGPoint location) {
    os_unfair_lock_lock(&gChainLock);
    if (gChain.generation == generation && gChain.phase != DragPhaseIdle) {
        gChain.latest = location; gChain.latestValid = YES;
    }
    os_unfair_lock_unlock(&gChainLock);
}

typedef enum { ReleaseInactive, ReleaseStarter, ReleaseCaller } ReleaseRequest;
static ReleaseRequest requestRelease(unsigned long long generation, int64_t *number,
                                     CGPoint *location) {
    os_unfair_lock_lock(&gChainLock); ReleaseRequest request = ReleaseInactive;
    if (gChain.generation == generation && gChain.phase == DragPhaseStarting) {
        gChain.phase = DragPhaseReleasing; request = ReleaseStarter;
    } else if (gChain.generation == generation && gChain.phase == DragPhaseOwned) {
        gChain.phase = DragPhaseReleasing; *number = gChain.eventNumber;
        *location = gChain.latestValid ? gChain.latest : gChain.start; request = ReleaseCaller;
    }
    os_unfair_lock_unlock(&gChainLock); return request;
}

static BOOL finishRelease(unsigned long long generation) {
    os_unfair_lock_lock(&gChainLock);
    BOOL current = gChain.generation == generation && gChain.phase == DragPhaseReleasing;
    if (current) resetChainLocked(ReasonLift); os_unfair_lock_unlock(&gChainLock); return current;
}

static BOOL postUp(int64_t number, CGPoint location, unsigned long long generation) {
    os_unfair_lock_lock(&gSyntheticLock);
    CGEventRef up = createTaggedEvent(kCGEventLeftMouseUp, location, number);
    if (up != NULL) {
        recordDiagnostic(DiagnosticSyntheticUp, ReasonLift, generation, DragPhaseReleasing,
                         up, location, 0, 0, 0, YES, NO);
        CGEventPost(kCGHIDEventTap, up); CFRelease(up);
    }
    os_unfair_lock_unlock(&gSyntheticLock); return up != NULL;
}

static BOOL locationsDiffer(CGPoint a, CGPoint b) {
    return fabs(a.x - b.x) >= 0.5 || fabs(a.y - b.y) >= 0.5;
}

static BOOL startSyntheticDrag(MTDeviceRef device, unsigned long long generation,
                               unsigned long long epoch) {
    if (epoch != atomic_load(&gFeatureEpoch) || !replacementActive(device)) {
        resetChain(generation, ReasonDisabled); return NO;
    }
    os_unfair_lock_lock(&gSyntheticLock); os_unfair_lock_lock(&gChainLock);
    if (gChain.generation != generation || gChain.device != device ||
        (gChain.phase != DragPhaseStarting && gChain.phase != DragPhaseReleasing)) {
        os_unfair_lock_unlock(&gChainLock); os_unfair_lock_unlock(&gSyntheticLock); return NO;
    }
    long long delay = gChain.downNotBeforeMillis - nowMillis();
    if (delay > 0) {
        os_unfair_lock_unlock(&gChainLock); os_unfair_lock_unlock(&gSyntheticLock);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_MSEC),
                       dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            startSyntheticDrag(device, generation, epoch);
        });
        return NO;
    }
    DragPhase phase = gChain.phase; CGPoint start = gChain.start, latest = gChain.latest;
    BOOL hasDrag = gChain.latestValid && locationsDiffer(start, latest);
    if (!gChain.startValid || (phase == DragPhaseReleasing && !hasDrag)) {
        resetChainLocked(ReasonQuickReleaseAborted);
        os_unfair_lock_unlock(&gChainLock); os_unfair_lock_unlock(&gSyntheticLock);
        atomic_store(&gLastOutcome, ReleaseOutcomeInterrupted); return NO;
    }
    int64_t number = nextEventNumberLocked();
    CGEventRef down = createTaggedEvent(kCGEventLeftMouseDown, start, number);
    CGEventRef drag = hasDrag ? createTaggedEvent(kCGEventLeftMouseDragged, latest, number) : NULL;
    CGEventRef up = phase == DragPhaseReleasing ? createTaggedEvent(kCGEventLeftMouseUp, latest, number) : NULL;
    if (down == NULL || (phase == DragPhaseReleasing && up == NULL)) {
        if (down) CFRelease(down); if (drag) CFRelease(drag); if (up) CFRelease(up);
        resetChainLocked(ReasonDisabled); os_unfair_lock_unlock(&gChainLock);
        os_unfair_lock_unlock(&gSyntheticLock); return NO;
    }
    gChain.eventNumber = number; if (phase == DragPhaseStarting) gChain.phase = DragPhaseOwned;
    recordDiagnostic(DiagnosticSyntheticDown, ReasonSecondTap, generation, phase, down, start, 0, 0, 0, YES, NO);
    CGEventPost(kCGHIDEventTap, down); CFRelease(down);
    if (drag) {
        recordDiagnostic(DiagnosticSyntheticDrag, ReasonMovement, generation, phase, drag, latest, 0, 0, 0, YES, NO);
        CGEventPost(kCGHIDEventTap, drag); CFRelease(drag);
    }
    if (up) {
        recordDiagnostic(DiagnosticSyntheticUp, ReasonLift, generation, phase, up, latest, 0, 0, 0, YES, NO);
        CGEventPost(kCGHIDEventTap, up); CFRelease(up); resetChainLocked(ReasonLift);
        atomic_store(&gLastOutcome, ReleaseOutcomeReleased);
    } else atomic_store(&gLastOutcome, ReleaseOutcomeOwned);
    os_unfair_lock_unlock(&gChainLock); os_unfair_lock_unlock(&gSyntheticLock); return YES;
}

static void scheduleStart(MTDeviceRef device, unsigned long long generation,
                          long long notBefore, unsigned long long epoch) {
    long long delay = MAX(0LL, notBefore - nowMillis());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        startSyntheticDrag(device, generation, epoch);
    });
}

static void scheduleHoldPromotion(MTDeviceRef device,
                                  unsigned long long generation,
                                  unsigned long long epoch) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 SecondContactHoldMillis * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        BOOL start = NO; long long notBefore = 0;
        os_unfair_lock_lock(&gStateLock);
        DeviceState *s = deviceStateLocked(device);
        if (s != NULL && epoch == atomic_load(&gFeatureEpoch) &&
            replacementActive(device) && s->touchingCount == 1 &&
            s->maximumTouching == 1 && !s->touchInvalid &&
            s->chainCandidate && s->chainGeneration == generation &&
            !s->movementConfirmed) {
            CGPoint location; BOOL valid = copyPointerLocation(&location);
            s->movementConfirmed = promoteContact(device, generation, location,
                                                  valid, ReasonHold, &notBefore);
            if (s->movementConfirmed) {
                s->holdConfirmed = YES;
                s->startRequested = YES;
                start = YES;
            }
        }
        os_unfair_lock_unlock(&gStateLock);
        if (start) scheduleStart(device, generation, notBefore, epoch);
    });
}

static void interruptChain(DiagnosticReason reason) {
    unsigned long long generation; int64_t number = 0; CGPoint location = CGPointZero; BOOL up = NO;
    os_unfair_lock_lock(&gChainLock); generation = gChain.generation;
    if (gChain.phase == DragPhaseOwned) {
        gChain.phase = DragPhaseReleasing; number = gChain.eventNumber;
        location = gChain.latestValid ? gChain.latest : gChain.start; up = YES;
    } else resetChainLocked(reason);
    os_unfair_lock_unlock(&gChainLock);
    if (up) { postUp(number, location, generation); finishRelease(generation); }
    atomic_store(&gLastOutcome, ReleaseOutcomeInterrupted);
}

static NativeDisposition dispositionForEvent(ChainSnapshot snapshot, CGEventType type) {
    BOOL button = type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp;
    BOOL movement = type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged;
    if (snapshot.phase == DragPhaseOwned) {
        if (movement) return NativeReplaceDrag; if (button) return NativeFilter;
    }
    if (snapshot.phase == DragPhaseReleasing && snapshot.eventNumber > 0 && (button || movement)) return NativeFilter;
    return NativePass;
}

static BOOL replaceWithDrag(CGEventTapProxy proxy, CGEventRef source, ChainSnapshot snapshot) {
    os_unfair_lock_lock(&gSyntheticLock); os_unfair_lock_lock(&gChainLock);
    BOOL current = gChain.generation == snapshot.generation && gChain.phase == DragPhaseOwned &&
        gChain.eventNumber == snapshot.eventNumber;
    if (!current) { os_unfair_lock_unlock(&gChainLock); os_unfair_lock_unlock(&gSyntheticLock); return NO; }
    CGPoint location = CGEventGetLocation(source);
    CGEventRef drag = createTaggedEvent(kCGEventLeftMouseDragged, location,
                                        snapshot.eventNumber);
    if (drag) {
        CGEventSetFlags(drag, CGEventGetFlags(source));
        CGEventSetIntegerValueField(drag, kCGMouseEventDeltaX, CGEventGetIntegerValueField(source, kCGMouseEventDeltaX));
        CGEventSetIntegerValueField(drag, kCGMouseEventDeltaY, CGEventGetIntegerValueField(source, kCGMouseEventDeltaY));
        gChain.latest = location; gChain.latestValid = YES;
        recordDiagnostic(DiagnosticSyntheticDrag, ReasonMovement, snapshot.generation, DragPhaseOwned,
                         drag, location, 0, 0, 0, YES, NO);
        CGEventTapPostEvent(proxy, drag); CFRelease(drag);
    }
    os_unfair_lock_unlock(&gChainLock); os_unfair_lock_unlock(&gSyntheticLock); return drag != NULL;
}

static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    (void)context;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        ChainSnapshot s = chainSnapshot();
        recordDiagnostic(DiagnosticFailure, ReasonEventTapDisabled, s.generation, s.phase,
                         event, CGPointZero, 0, 0, 0, NO, NO);
        interruptChain(ReasonEventTapDisabled); if (gEventTap) CGEventTapEnable(gEventTap, true); return event;
    }
    if (event == NULL || ownEvent(event) || !atomic_load(&gEnabled) || !atomic_load(&gReplacementEnabled)) return event;
    ChainSnapshot s = chainSnapshot(); NativeDisposition disposition = dispositionForEvent(s, type);
    if (disposition == NativePass) {
        if ((type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp) && s.phase != DragPhaseIdle)
            recordDiagnostic(DiagnosticNativePassed, ReasonFirstTap, s.generation, s.phase,
                             event, CGEventGetLocation(event), 0, 0, 0, NO, NO);
        return event;
    }
    if (disposition == NativeReplaceDrag) replaceWithDrag(proxy, event, s);
    recordDiagnostic(DiagnosticNativeFiltered, ReasonNone, s.generation, s.phase,
                     event, CGEventGetLocation(event), 0, 0, 0, YES, NO);
    return NULL;
}

static void postThreeFingerUp(void) {
    CGPoint location; if (!copyPointerLocation(&location)) return;
    os_unfair_lock_lock(&gSyntheticLock);
    CGEventRef up = createTaggedEvent(kCGEventLeftMouseUp, location, 0);
    if (up) { CGEventSetIntegerValueField(up, kCGEventSourceUserData, ThreeFingerTag); CGEventPost(kCGHIDEventTap, up); CFRelease(up); }
    os_unfair_lock_unlock(&gSyntheticLock);
}

static void completeTouch(DeviceState *s, double timestamp, BOOL *candidate,
                          unsigned long long *generation, BOOL *movement) {
    int duration = s->touchMade ? (int)MAX(0.0, (timestamp - s->touchStartedTimestamp) * 1000.0) : 0;
    *candidate = s->chainCandidate; *generation = s->chainGeneration; *movement = s->movementConfirmed;
    atomic_store(&gLastDurationMillis, duration); atomic_store(&gLastFrames, s->touchingFrames);
    atomic_store(&gLastMaximumContacts, s->maximumTouching);
    atomic_store(&gLastMoved, s->touchMoved); atomic_store(&gLastInvalid, s->touchInvalid);
    DiagnosticReason reason = ReasonNone; DiagnosticKind kind = DiagnosticReset;
    if (s->touchInvalid) {
        s->firstTapPending = NO; atomic_store(&gLastOutcome, ReleaseOutcomeInvalid); reason = ReasonMultiFinger;
    } else if (s->chainCandidate) {
        s->firstTapPending = NO; atomic_store(&gLastOutcome, s->movementConfirmed ? ReleaseOutcomeStarting : ReleaseOutcomeSecondTapNoDrag);
        reason = s->movementConfirmed ? (s->holdConfirmed ? ReasonHold : ReasonMovement) : ReasonNoMovement;
    } else if (s->touchMade && duration <= MaximumFirstTapDurationSeconds * 1000.0 &&
               !s->touchMoved) {
        s->firstTapPending = YES; s->firstTapCompletedTimestamp = timestamp;
        atomic_store(&gLastOutcome, ReleaseOutcomeFirstTap); reason = ReasonFirstTap; kind = DiagnosticFirstTap;
    } else {
        s->firstTapPending = NO; s->firstTapCompletedTimestamp = 0;
        if (s->touchMade) reason = duration > MaximumFirstTapDurationSeconds * 1000.0
            ? ReasonTapTooLong : ReasonTapMoved;
    }
    recordDiagnosticDetails(kind, reason, *generation, chainSnapshot().phase,
                            NULL, s->pointerStart, duration, -1,
                            sqrtf(s->maximumSquaredDistanceMM), s->touchingFrames,
                            s->maximumTouching, s->touchMoved, s->touchInvalid);
    resetCurrentTouch(s);
}

static int contactFrameCallback(MTDeviceRef device, void *contacts, int contactCount,
                                double timestamp, int frame) {
    int count = touchingCount(contacts, contactCount);
    BOOL schedule = NO, scheduleHold = NO, ownedUp = NO, interrupt = NO, three = NO;
    unsigned long long generation = 0, epoch = 0; long long notBefore = 0;
    int64_t number = 0; CGPoint releaseLocation = CGPointZero;
    os_unfair_lock_lock(&gStateLock); DeviceState *s = deviceStateLocked(device);
    if (s == NULL) { os_unfair_lock_unlock(&gStateLock); return 0; }
    if (!atomic_load(&gEnabled)) { resetDevice(s); os_unfair_lock_unlock(&gStateLock); return 0; }
    BOOL identityChanged = replacementActive(device) && count == 1 && s->touchingCount == 1 &&
        s->maximumTouching == 1 && s->touchMade && s->identityValid &&
        (!frameContainsIdentity(s, contacts, contactCount) || frameReplacesIdentity(s, contacts, contactCount));
    if (identityChanged) {
        observeBreak(s, contacts, contactCount); os_unfair_lock_unlock(&gStateLock);
        contactFrameCallback(device, NULL, 0, timestamp, frame);
        return contactFrameCallback(device, contacts, contactCount, timestamp, frame);
    }
    if (count > 0) {
        BOOL started = s->touchingCount == 0;
        if (started) { s->maximumTouching = 0; resetCurrentTouch(s); }
        s->touchingCount = count; s->maximumTouching = MAX(s->maximumTouching, count);
        if (replacementActive(device)) {
            observeFrame(s, contacts, contactCount, timestamp);
            if (started && s->touchMade) {
                recordDiagnostic(DiagnosticRawStart, ReasonNone, 0, chainSnapshot().phase,
                                 NULL, s->pointerStart, 0, 0, count, NO, NO);
                int gap = s->firstTapPending
                    ? (int)llround((timestamp - s->firstTapCompletedTimestamp) * 1000.0) : -1;
                BOOL recent = s->firstTapPending && gap >= 0 &&
                    gap <= doubleTapDragGapMillis();
                if (recent && beginSecondContact(device, s->pointerStart,
                                                 s->pointerStartValid, gap,
                                                 &generation)) {
                    s->chainCandidate = YES; s->chainGeneration = generation;
                    scheduleHold = YES; epoch = atomic_load(&gFeatureEpoch);
                } else if (s->firstTapPending && !recent) {
                    recordDiagnosticDetails(DiagnosticReset, ReasonIntertapExpired,
                        0, chainSnapshot().phase, NULL, s->pointerStart, 0, gap, 0,
                        0, count, NO, NO);
                    s->firstTapPending = NO; s->firstTapCompletedTimestamp = 0;
                }
            }
            if (s->chainCandidate && s->touchMoved) {
                CGPoint location; BOOL valid = copyPointerLocation(&location);
                if (!s->movementConfirmed) s->movementConfirmed = promoteContact(device, s->chainGeneration,
                    location, valid, ReasonMovement, &notBefore);
                else if (valid) updateChainLocation(s->chainGeneration, location);
                if (s->movementConfirmed && !s->startRequested) {
                    s->startRequested = YES; schedule = YES; generation = s->chainGeneration; epoch = atomic_load(&gFeatureEpoch);
                }
            }
            if (s->touchInvalid && s->chainCandidate) { interrupt = YES; s->chainCandidate = NO; }
        } else {
            resetCurrentTouch(s);
            if (atomic_load(&gReplacementEnabled) && nativeDraggingForDevice(device))
                atomic_store(&gLastOutcome, ReleaseOutcomeNativeDraggingOn);
        }
        os_unfair_lock_unlock(&gStateLock);
        if (interrupt) interruptChain(ReasonMultiFinger);
        if (scheduleHold) scheduleHoldPromotion(device, generation, epoch);
        if (schedule) scheduleStart(device, generation, notBefore, epoch);
        return 0;
    }
    if (s->touchingCount == 0) { os_unfair_lock_unlock(&gStateLock); return 0; }
    three = s->maximumTouching == 3;
    if (replacementActive(device)) {
        observeBreak(s, contacts, contactCount);
        if (s->chainCandidate && s->touchMoved && !s->movementConfirmed) {
            CGPoint location; BOOL valid = copyPointerLocation(&location);
            s->movementConfirmed = promoteContact(device, s->chainGeneration,
                                                   location, valid,
                                                   ReasonMovement, &notBefore);
        }
        BOOL candidate = NO, movement = NO;
        completeTouch(s, timestamp, &candidate, &generation, &movement);
        if (candidate && !movement) resetChain(generation, ReasonNoMovement);
        else if (candidate) {
            ReleaseRequest request = requestRelease(generation, &number, &releaseLocation);
            if (request == ReleaseCaller) ownedUp = YES;
            else if (request == ReleaseStarter && !s->startRequested) { schedule = YES; epoch = atomic_load(&gFeatureEpoch); }
            else if (request == ReleaseInactive) resetChain(generation, ReasonStale);
        }
    } else resetCurrentTouch(s);
    s->touchingCount = s->maximumTouching = 0; os_unfair_lock_unlock(&gStateLock);
    if (three && !overrideIsHeld() && claimReleaseSlot(&gLastThreeFingerReleaseMillis)) postThreeFingerUp();
    if (schedule) scheduleStart(device, generation, notBefore, epoch);
    if (ownedUp) {
        if (postUp(number, releaseLocation, generation) && finishRelease(generation))
            atomic_store(&gLastOutcome, ReleaseOutcomeReleased);
        else { resetChain(generation, ReasonStale); atomic_store(&gLastOutcome, ReleaseOutcomeInterrupted); }
    }
    return 0;
}

typedef enum { AccessGranted, AccessRequired, EventTapUnavailable } AccessStatus;

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(strong) NSStatusItem *statusItem;
@property(strong) NSMenuItem *enabledItem, *overrideItem, *replacementItem;
@property(strong) NSMenuItem *replacementStatus, *runtimeStatus, *diagnosticStatus, *accessibilityItem;
@property(strong) NSMenuItem *shiftItem, *controlItem, *optionItem, *fnItem;
@property(assign) CFArrayRef deviceList;
@property(assign) void *multitouchHandle;
@end

@implementation AppDelegate

- (AccessStatus)accessStatus:(BOOL)prompt {
    BOOL post = CGPreflightPostEventAccess(), listen = CGPreflightListenEventAccess();
    if (prompt && !post) CGRequestPostEventAccess(); if (prompt && !listen) CGRequestListenEventAccess();
    return CGPreflightPostEventAccess() && CGPreflightListenEventAccess() ? AccessGranted : AccessRequired;
}

- (BOOL)installEventTap {
    if (gSyntheticSource == NULL) return NO;
    if (gEventTap) { CGEventTapEnable(gEventTap, true); return YES; }
    CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved) | CGEventMaskBit(kCGEventLeftMouseDown) |
        CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventLeftMouseUp);
    gEventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                 mask, eventTapCallback, NULL);
    if (!gEventTap) return NO;
    gEventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gEventTap, 0);
    if (!gEventTapSource) { CFRelease(gEventTap); gEventTap = NULL; return NO; }
    CFRunLoopAddSource(CFRunLoopGetMain(), gEventTapSource, kCFRunLoopCommonModes); return YES;
}

- (void)removeEventTap {
    if (gEventTapSource) { CFRunLoopRemoveSource(CFRunLoopGetMain(), gEventTapSource, kCFRunLoopCommonModes); CFRelease(gEventTapSource); gEventTapSource = NULL; }
    if (gEventTap) { CFMachPortInvalidate(gEventTap); CFRelease(gEventTap); gEventTap = NULL; }
}

- (void)updateStatus {
    if (self.replacementStatus) {
        self.replacementStatus.title = [self accessStatus:NO] != AccessGranted
            ? @"Double-Tap Drag: Accessibility / Input Monitoring Required"
            : (atomic_load(&gAnyNativeDraggingEnabled)
                ? @"Double-Tap Drag: Inactive; turn off macOS trackpad dragging"
                : @"Double-Tap Drag: Full replacement ready");
    }
    if (self.runtimeStatus) {
        switch ((ReleaseOutcome)atomic_load(&gLastOutcome)) {
            case ReleaseOutcomeWaiting: self.runtimeStatus.title = @"Double-Tap last: waiting"; break;
            case ReleaseOutcomeFirstTap: self.runtimeStatus.title = @"Double-Tap last: first tap captured"; break;
            case ReleaseOutcomeSecondTapNoDrag: self.runtimeStatus.title = @"Double-Tap last: second tap had no drag"; break;
            case ReleaseOutcomeStarting: self.runtimeStatus.title = @"Double-Tap last: drag starting"; break;
            case ReleaseOutcomeOwned: self.runtimeStatus.title = @"Double-Tap last: drag active"; break;
            case ReleaseOutcomeReleased: self.runtimeStatus.title = [NSString stringWithFormat:@"Double-Tap last: released immediately (%d ms, %d frames)", atomic_load(&gLastDurationMillis), atomic_load(&gLastFrames)]; break;
            case ReleaseOutcomeInterrupted: self.runtimeStatus.title = @"Double-Tap last: interrupted safely"; break;
            case ReleaseOutcomeInvalid: self.runtimeStatus.title = @"Double-Tap last: multi-finger contact rejected"; break;
            case ReleaseOutcomeNativeDraggingOn: self.runtimeStatus.title = @"Double-Tap last: native dragging is still on"; break;
        }
    }
    if (self.diagnosticStatus) {
        os_unfair_lock_lock(&gDiagnosticLock); uint64_t count = MIN(gRecordSequence, (uint64_t)DiagnosticCapacity); os_unfair_lock_unlock(&gDiagnosticLock);
        self.diagnosticStatus.title = [NSString stringWithFormat:@"Diagnostics: %llu events%@", count,
            atomic_load(&gLoggingFaulted) ? @", write failed" : (atomic_load(&gLoggingActive) ? @", auto saved" : @"")];
    }
}

- (void)updateModifiers {
    NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey:OverrideModifierKey];
    self.shiftItem.state = [name isEqualToString:ModifierShift]; self.controlItem.state = [name isEqualToString:ModifierControl];
    self.optionItem.state = [name isEqualToString:ModifierOption]; self.fnItem.state = [name isEqualToString:ModifierFn];
}

- (NSMenuItem *)item:(NSString *)title action:(SEL)action menu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self; [menu addItem:item]; return item;
}

- (void)setupStatusItem {
    if (self.statusItem) return;
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"3F+"; self.statusItem.button.toolTip = @"3FDragUnstuck";
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""]; menu.delegate = self;
    self.enabledItem = [self item:@"Enabled" action:@selector(toggleEnabled:) menu:menu]; self.enabledItem.state = atomic_load(&gEnabled);
    self.overrideItem = [self item:@"Three-Finger Override Enabled" action:@selector(toggleOverride:) menu:menu]; self.overrideItem.state = atomic_load(&gOverrideEnabled);
    self.replacementItem = [self item:@"Double-Tap Drag Replacement (Experimental)" action:@selector(toggleReplacement:) menu:menu]; self.replacementItem.state = atomic_load(&gReplacementEnabled);
    self.replacementStatus = [self item:@"Double-Tap Drag: checking" action:nil menu:menu]; self.replacementStatus.enabled = NO;
    self.runtimeStatus = [self item:@"Double-Tap last: waiting" action:nil menu:menu]; self.runtimeStatus.enabled = NO;
    NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:@"Double-Tap Diagnostics" action:nil keyEquivalent:@""];
    NSMenu *diagnostics = [[NSMenu alloc] initWithTitle:@"Double-Tap Diagnostics"];
    self.diagnosticStatus = [self item:@"Diagnostics: 0 events" action:nil menu:diagnostics]; self.diagnosticStatus.enabled = NO;
    [diagnostics addItem:[NSMenuItem separatorItem]];
    [self item:@"Copy Diagnostic Summary" action:@selector(copyDiagnostics:) menu:diagnostics];
    [self item:@"Export Diagnostic Trace..." action:@selector(exportDiagnostics:) menu:diagnostics];
    [self item:@"Reveal Automatic Diagnostic Logs" action:@selector(revealDiagnostics:) menu:diagnostics];
    [self item:@"Clear Diagnostic Trace" action:@selector(clearDiagnostics:) menu:diagnostics];
    root.submenu = diagnostics; [menu addItem:root];
    NSMenuItem *modifierRoot = [[NSMenuItem alloc] initWithTitle:@"Three-Finger Override Modifier" action:nil keyEquivalent:@""];
    NSMenu *modifiers = [[NSMenu alloc] initWithTitle:@"Three-Finger Override Modifier"];
    self.shiftItem = [self item:@"Shift" action:@selector(selectModifier:) menu:modifiers]; self.shiftItem.representedObject = ModifierShift;
    self.controlItem = [self item:@"Control" action:@selector(selectModifier:) menu:modifiers]; self.controlItem.representedObject = ModifierControl;
    self.optionItem = [self item:@"Option" action:@selector(selectModifier:) menu:modifiers]; self.optionItem.representedObject = ModifierOption;
    self.fnItem = [self item:@"Fn (Globe)" action:@selector(selectModifier:) menu:modifiers]; self.fnItem.representedObject = ModifierFn;
    modifierRoot.submenu = modifiers; [menu addItem:modifierRoot];
    self.accessibilityItem = [self item:@"Accessibility Permission Required" action:@selector(requestAccessibility:) menu:menu];
    [self item:@"Hide Menu Bar Icon" action:@selector(hideStatusItem:) menu:menu]; [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"]; quit.target = NSApp; [menu addItem:quit];
    self.statusItem.menu = menu; [self updateModifiers]; [self updateStatus];
}

- (void)toggleEnabled:(id)sender { (void)sender; BOOL value = !atomic_load(&gEnabled); atomic_store(&gEnabled, value); self.enabledItem.state = value;
    if (!value) { atomic_fetch_add(&gFeatureEpoch, 1); interruptChain(ReasonDisabled); os_unfair_lock_lock(&gStateLock); resetAllDevicesLocked(); os_unfair_lock_unlock(&gStateLock); } }
- (void)toggleOverride:(id)sender { (void)sender; BOOL value = !atomic_load(&gOverrideEnabled); atomic_store(&gOverrideEnabled, value); self.overrideItem.state = value; [[NSUserDefaults standardUserDefaults] setBool:value forKey:OverrideEnabledKey]; }

- (void)toggleReplacement:(id)sender {
    (void)sender; refreshDraggingPreferences(); BOOL enable = !atomic_load(&gReplacementEnabled);
    if (enable && ([self accessStatus:YES] != AccessGranted || ![self installEventTap])) {
        NSAlert *alert = [[NSAlert alloc] init]; alert.messageText = @"Double-Tap Drag Replacement Was Not Enabled";
        alert.informativeText = @"Grant Accessibility and, if requested, Input Monitoring permission to this app, then try again.";
        [alert addButtonWithTitle:@"Open Accessibility Settings"]; [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] == NSAlertFirstButtonReturn) [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]]; return;
    }
    if (enable) startLogging(); else { atomic_fetch_add(&gFeatureEpoch, 1); interruptChain(ReasonDisabled); os_unfair_lock_lock(&gStateLock); resetAllDevicesLocked(); os_unfair_lock_unlock(&gStateLock); stopLogging(); }
    atomic_store(&gReplacementEnabled, enable); [[NSUserDefaults standardUserDefaults] setBool:enable forKey:ReplacementEnabledKey]; self.replacementItem.state = enable;
    atomic_store(&gLastOutcome, atomic_load(&gAnyNativeDraggingEnabled) ? ReleaseOutcomeNativeDraggingOn : ReleaseOutcomeWaiting); [self updateStatus];
}

- (void)selectModifier:(NSMenuItem *)sender { NSString *name = sender.representedObject; if (!name) return;
    [[NSUserDefaults standardUserDefaults] setObject:name forKey:OverrideModifierKey]; atomic_store(&gOverrideMask, modifierMaskForName(name)); [self updateModifiers]; }
- (void)requestAccessibility:(id)sender { (void)sender; AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES}); }
- (void)copyDiagnostics:(id)sender { (void)sender; NSPasteboard *p = NSPasteboard.generalPasteboard; [p clearContents]; [p setString:traceText(@"manual_copy") forType:NSPasteboardTypeString]; }
- (void)exportDiagnostics:(id)sender { (void)sender; NSSavePanel *p = NSSavePanel.savePanel; p.nameFieldStringValue = @"3FDragUnstuck-double-tap-diagnostics.jsonl"; UTType *type = [UTType typeWithFilenameExtension:@"jsonl"]; if (type) p.allowedContentTypes = @[type]; if ([p runModal] == NSModalResponseOK && p.URL) [traceText(@"manual_export") writeToURL:p.URL atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
- (void)revealDiagnostics:(id)sender { (void)sender; NSURL *url = gAutomaticLogURL ? gAutomaticLogURL.URLByDeletingLastPathComponent : logDirectoryURL(); [[NSFileManager defaultManager] createDirectoryAtURL:url withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@(0700)} error:nil]; [[NSWorkspace sharedWorkspace] openURL:url]; }
- (void)clearDiagnostics:(id)sender { (void)sender; clearRecords(); [self updateStatus]; }
- (void)hideStatusItem:(id)sender { (void)sender; if (!self.statusItem) return; [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem]; self.statusItem = nil; self.enabledItem = self.overrideItem = self.replacementItem = nil; self.replacementStatus = self.runtimeStatus = self.diagnosticStatus = self.accessibilityItem = nil; }

- (void)menuWillOpen:(NSMenu *)menu {
    if (menu != self.statusItem.menu) return; BOOL old = atomic_load(&gAnyNativeDraggingEnabled); refreshDraggingPreferences();
    if (old != atomic_load(&gAnyNativeDraggingEnabled)) { atomic_fetch_add(&gFeatureEpoch, 1); interruptChain(ReasonDisabled); os_unfair_lock_lock(&gStateLock); resetAllDevicesLocked(); os_unfair_lock_unlock(&gStateLock); }
    BOOL trusted = AXIsProcessTrusted(); self.accessibilityItem.title = trusted ? @"Accessibility Permission Granted" : @"Accessibility Permission Required"; self.accessibilityItem.state = trusted;
    self.enabledItem.state = atomic_load(&gEnabled); self.overrideItem.state = atomic_load(&gOverrideEnabled); self.replacementItem.state = atomic_load(&gReplacementEnabled); [self updateModifiers]; [self updateStatus];
}

- (void)startMultitouch {
    self.multitouchHandle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/A/MultitouchSupport", RTLD_LAZY);
    if (!self.multitouchHandle) { self.statusItem.button.title = @"3F!"; return; }
    MTDeviceCreateDefaultFunction createDefault = (MTDeviceCreateDefaultFunction)dlsym(self.multitouchHandle, "MTDeviceCreateDefault");
    MTDeviceCreateListFunction createList = (MTDeviceCreateListFunction)dlsym(self.multitouchHandle, "MTDeviceCreateList");
    MTRegisterContactFrameCallbackFunction registerCallback = (MTRegisterContactFrameCallbackFunction)dlsym(self.multitouchHandle, "MTRegisterContactFrameCallback");
    MTDeviceStartFunction startDevice = (MTDeviceStartFunction)dlsym(self.multitouchHandle, "MTDeviceStart");
    gDeviceIsBuiltIn = (MTDeviceIsBuiltInFunction)dlsym(self.multitouchHandle, "MTDeviceIsBuiltIn");
    if (!createDefault || !registerCallback || !startDevice) { self.statusItem.button.title = @"3F!"; return; }
    NSMutableArray<NSValue *> *devices = [NSMutableArray array];
    if (createList) { self.deviceList = createList(); if (self.deviceList) for (CFIndex i = 0; i < CFArrayGetCount(self.deviceList); i++) { MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(self.deviceList, i); if (d) [devices addObject:[NSValue valueWithPointer:d]]; } }
    if (devices.count == 0) { MTDeviceRef d = createDefault(); if (d) [devices addObject:[NSValue valueWithPointer:d]]; }
    os_unfair_lock_lock(&gStateLock); gDeviceCount = 0;
    for (NSValue *value in devices) { if (gDeviceCount == MaximumDevices) break; memset(&gDevices[gDeviceCount], 0, sizeof(DeviceState)); gDevices[gDeviceCount++].device = value.pointerValue; }
    os_unfair_lock_unlock(&gStateLock); refreshDraggingPreferences();
    for (NSValue *value in devices) { registerCallback(value.pointerValue, contactFrameCallback); startDevice(value.pointerValue, 0); }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification; [[NSUserDefaults standardUserDefaults] registerDefaults:@{OverrideEnabledKey:@YES, OverrideModifierKey:ModifierOption, ReplacementEnabledKey:@NO}];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults; atomic_store(&gOverrideEnabled, [d boolForKey:OverrideEnabledKey]); atomic_store(&gOverrideMask, modifierMaskForName([d stringForKey:OverrideModifierKey]));
    gNextEventNumber = SyntheticEventNumberMinimum + arc4random_uniform(SyntheticEventNumberMaximum); gSyntheticSource = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState); if (gSyntheticSource) CGEventSourceSetLocalEventsSuppressionInterval(gSyntheticSource, 0);
    refreshDraggingPreferences(); if ([d boolForKey:ReplacementEnabledKey] && [self accessStatus:NO] == AccessGranted && [self installEventTap]) { atomic_store(&gReplacementEnabled, true); startLogging(); }
    [self setupStatusItem]; [self startMultitouch];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag { (void)sender; (void)flag; [self setupStatusItem]; return NO; }
- (void)applicationWillTerminate:(NSNotification *)notification { (void)notification; atomic_store(&gReplacementEnabled, false); atomic_fetch_add(&gFeatureEpoch, 1); interruptChain(ReasonDisabled); stopLogging(); [self removeEventTap]; if (gSyntheticSource) { CFRelease(gSyntheticSource); gSyntheticSource = NULL; } self.deviceList = NULL; self.multitouchHandle = NULL; }
@end

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate; [app run];
    }
    return 0;
}
