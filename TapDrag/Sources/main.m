#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <limits.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdint.h>
#import <time.h>
#import <unistd.h>

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef, void *, int, double, int);
typedef MTDeviceRef (*MTDeviceCreateDefaultFunction)(void);
typedef CFArrayRef (*MTDeviceCreateListFunction)(void);
typedef int (*MTRegisterContactFrameCallbackFunction)(MTDeviceRef, MTContactCallbackFunction);
typedef int (*MTDeviceStartFunction)(MTDeviceRef, int);
typedef int (*MTDeviceStopFunction)(MTDeviceRef);
typedef BOOL (*MTDeviceIsBuiltInFunction)(MTDeviceRef);
typedef int (*MTDeviceGetSensorDimensionsFunction)(MTDeviceRef, int *, int *);

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
    DiagnosticRawStart,
    DiagnosticFirstTap,
    DiagnosticSecondContact,
    DiagnosticIdentityTransfer,
    DiagnosticMovement,
    DiagnosticSyntheticDown,
    DiagnosticSyntheticDrag,
    DiagnosticSyntheticUp,
    DiagnosticNativeObserved,
    DiagnosticNativePassed,
    DiagnosticNativeFiltered,
    DiagnosticMovementInput,
    DiagnosticDownstreamObserved,
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
    ReasonNativeButtonDuringTouch,
    ReasonIntertapTooShort,
    ReasonIntertapExpired,
    ReasonIdentityTransfer,
    ReasonObserverUnavailable,
    ReasonObserverDisabled,
    ReasonSystemSuspended,
    ReasonSystemResumed,
    ReasonDeviceTopology,
    ReasonMultitouchUnavailable,
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
    BOOL nativeButtonDownDuringTouch;
    float maximumSquaredDistance, maximumSquaredDistanceMM;
    BOOL firstTapPending;
    double firstTapCompletedTimestamp;
    uint64_t firstTapCompletedUptime;
    CGPoint firstTapPointer;
    BOOL firstTapPointerValid;
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
    int64_t deltaX, deltaY;
    uint64_t eventFlags;
    int32_t buttonNumber, mouseSubtype;
    int32_t phase, kind, reason, eventType, clickState;
    int32_t sourceState, sourcePid, sourceUid, sourceGid;
    int32_t targetPid, targetWindow, handlingWindow, x, y;
    int32_t durationMillis, intertapMillis, motionMilliMillimeters, pressureMilli;
    int32_t frames, maximumContacts, moved, invalid;
    int32_t nativeDragging;
} DiagnosticRecord;

enum {
    MaximumDevices = 16,
    DiagnosticCapacity = 2048,
    AutomaticLogLimit = 12,
    SyntheticEventNumberMinimum = 1,
    SyntheticEventNumberMaximum = INT16_MAX,
    MinimumTrackpadSensorRows = 10,
};

static atomic_bool gEnabled = false;
static atomic_bool gInputSuspended = false;
static atomic_bool gMultitouchReady = false;
static atomic_ullong gFeatureEpoch = 1;
static atomic_bool gInternalDraggingPresent = false;
static atomic_bool gInternalDraggingEnabled = true;
static atomic_bool gBluetoothDraggingPresent = false;
static atomic_bool gBluetoothDraggingEnabled = true;
static atomic_bool gAnyNativeDraggingEnabled = true;

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
static CFMachPortRef gClickTap = NULL;
static CFRunLoopSourceRef gClickTapSource = NULL;
static CFMachPortRef gObserverTap = NULL;
static CFRunLoopSourceRef gObserverTapSource = NULL;
static atomic_bool gObserverActive = false;
// Protected by gSyntheticLock; a native first click must not precede its
// possible replacement drag.
static CGEventRef gBufferedTapDown = NULL, gBufferedTapUp = NULL;
static MTDeviceRef gBufferedTapDevice = NULL;
static unsigned long long gBufferedTapToken = 0;
static int64_t gReplayedButtonNumber = 0;
static MTDeviceIsBuiltInFunction gDeviceIsBuiltIn = NULL;
static MTDeviceCreateDefaultFunction gDeviceCreateDefault = NULL;
static MTDeviceCreateListFunction gDeviceCreateList = NULL;
static MTRegisterContactFrameCallbackFunction gRegisterContactFrameCallback = NULL;
static MTDeviceStartFunction gDeviceStart = NULL;
static MTDeviceStopFunction gDeviceStop = NULL;
static MTDeviceGetSensorDimensionsFunction gDeviceGetSensorDimensions = NULL;

static DiagnosticRecord gRecords[DiagnosticCapacity];
static uint64_t gRecordSequence = 0;
static atomic_uint gDroppedRecords = 0;
static atomic_bool gLoggingActive = false;
static atomic_bool gAutomaticLoggingEnabled = true;
static atomic_bool gLoggingDirty = false;
static atomic_bool gLoggingFaulted = false;
static dispatch_queue_t gLoggingQueue = NULL;
static dispatch_source_t gLoggingTimer = NULL;
static NSURL *gAutomaticLogURL = nil;

static NSString *const EnabledKey = @"DoubleTapDragReleaseEnabled";
static NSString *const AutomaticLoggingKey = @"AutomaticDiagnosticLoggingEnabled";
static const int64_t DoubleTapTag = 0x3346444E45574452LL;
static const long long MinimumSecondContactGapMillis = 30;
static const long long MaximumSecondTapGapMillis = 160;
static const long long SecondContactHoldMillis = 180;
static const double MaximumFirstTapDurationSeconds = 0.25;
static const float TapMoveThresholdMillimeters = 1.3f;
static const float FallbackNormalizedMoveThreshold = 0.010f;
static const long long FirstClickAllowanceMillis = 20;
static const double MaximumFirstTapEventDistancePoints = 12.0;
static const CGEventTapLocation InputTapLocation = kCGHIDEventTap;

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


static BOOL secondContactGapIsValid(long long gap, long long maximumGap) {
    return gap >= MinimumSecondContactGapMillis && gap <= maximumGap;
}

static BOOL validSecondContactGapMillis(long long gap) {
    return secondContactGapIsValid(gap, doubleTapDragGapMillis());
}

static int touchDurationMillis(const DeviceState *s, double timestamp) {
    return s->touchMade
        ? (int)llround(MAX(0.0, (timestamp - s->touchStartedTimestamp) * 1000.0)) : 0;
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
    CGEventSetIntegerValueField(event, kCGEventSourceStateID,
                               kCGEventSourceStateHIDSystemState);
    CGEventSetIntegerValueField(event, kCGEventSourceUnixProcessID, getpid());
    CGEventSetIntegerValueField(event, kCGEventSourceUserID, geteuid());
    CGEventSetIntegerValueField(event, kCGEventSourceGroupID, getegid());
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventSetIntegerValueField(event, kCGMouseEventNumber, number);
    // This transaction is driven by raw trackpad contacts. Keep its device
    // subtype consistent with the native first tap and movement events.
    CGEventSetIntegerValueField(event, kCGMouseEventSubtype, NSEventSubtypeTouch);
    CGEventSetTimestamp(event, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
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
        case DiagnosticIdentityTransfer: return @"identity_transferred";
        case DiagnosticMovement: return @"movement_confirmed";
        case DiagnosticSyntheticDown: return @"synthetic_down";
        case DiagnosticSyntheticDrag: return @"synthetic_drag";
        case DiagnosticSyntheticUp: return @"synthetic_up";
        case DiagnosticNativeObserved: return @"native_button_observed";
        case DiagnosticNativePassed: return @"native_button_passed";
        case DiagnosticNativeFiltered: return @"native_event_filtered";
        case DiagnosticMovementInput: return @"movement_input";
        case DiagnosticDownstreamObserved: return @"observed_downstream";
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
        case ReasonNativeButtonDuringTouch: return @"native_button_during_touch";
        case ReasonIntertapTooShort: return @"intertap_too_short";
        case ReasonIntertapExpired: return @"intertap_expired";
        case ReasonIdentityTransfer: return @"identity_transfer";
        case ReasonObserverUnavailable: return @"observer_unavailable";
        case ReasonObserverDisabled: return @"observer_disabled";
        case ReasonSystemSuspended: return @"system_suspended";
        case ReasonSystemResumed: return @"system_resumed";
        case ReasonDeviceTopology: return @"device_topology_changed";
        case ReasonMultitouchUnavailable: return @"multitouch_unavailable";
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
        .deltaX = event == NULL ? 0 : CGEventGetIntegerValueField(event, kCGMouseEventDeltaX),
        .deltaY = event == NULL ? 0 : CGEventGetIntegerValueField(event, kCGMouseEventDeltaY),
        .eventFlags = event == NULL ? 0 : CGEventGetFlags(event),
        .buttonNumber = event == NULL ? -1 : (int32_t)CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber),
        .mouseSubtype = event == NULL ? -1 : (int32_t)CGEventGetIntegerValueField(event, kCGMouseEventSubtype),
        .targetPid = event == NULL ? 0 : (int32_t)CGEventGetIntegerValueField(
            event, kCGEventTargetUnixProcessID),
        .sourceState = event == NULL ? 0 : (int32_t)CGEventGetIntegerValueField(
            event, kCGEventSourceStateID),
        .sourcePid = event == NULL ? 0 : (int32_t)CGEventGetIntegerValueField(
            event, kCGEventSourceUnixProcessID),
        .sourceUid = event == NULL ? 0 : (int32_t)CGEventGetIntegerValueField(
            event, kCGEventSourceUserID),
        .sourceGid = event == NULL ? 0 : (int32_t)CGEventGetIntegerValueField(
            event, kCGEventSourceGroupID),
        .targetWindow = event == NULL ? 0 : (int32_t)CGEventGetIntegerValueField(
            event, kCGMouseEventWindowUnderMousePointer),
        .handlingWindow = event == NULL ? 0 : (int32_t)CGEventGetIntegerValueField(
            event, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent),
        .sourceUserData = event == NULL ? 0 : CGEventGetIntegerValueField(event, kCGEventSourceUserData),
        .eventTimestamp = event == NULL ? 0 : CGEventGetTimestamp(event),
        .pressureMilli = event == NULL ? -1 : (int32_t)llround(
            CGEventGetDoubleValueField(event, kCGMouseEventPressure) * 1000.0),
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
             @"delta_x": @(r.deltaX), @"delta_y": @(r.deltaY),
             @"event_flags": @(r.eventFlags), @"button_number": @(r.buttonNumber),
             @"mouse_subtype": @(r.mouseSubtype),
             @"source_state_id": @(r.sourceState),
             @"source_pid": @(r.sourcePid),
             @"source_uid": @(r.sourceUid),
             @"source_gid": @(r.sourceGid),
             @"target_pid": @(r.targetPid),
             @"target_window": @(r.targetWindow),
             @"handling_window": @(r.handlingWindow),
             @"source_user_data": @(r.sourceUserData),
             @"event_timestamp": @(r.eventTimestamp), @"x": @(r.x), @"y": @(r.y),
             @"touch_duration_ms": @(r.durationMillis), @"intertap_ms": @(r.intertapMillis),
             @"mouse_pressure": r.pressureMilli < 0
                ? @(-1) : @((double)r.pressureMilli / 1000.0),
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
        @"input_event_tap": @"hid",
        @"drag_delivery": @"serialized_hid_post",
        @"synthetic_mouse_subtype": @(NSEventSubtypeTouch),
        @"downstream_observer_active": @(atomic_load(&gObserverActive)),
        @"diagnostic_schema": @6,
        @"system_double_click_ms": @(doubleClickIntervalMillis()),
        @"minimum_second_contact_gap_ms": @(MinimumSecondContactGapMillis),
        @"double_tap_drag_gap_ms": @(doubleTapDragGapMillis()),
        @"first_click_allowance_ms": @(FirstClickAllowanceMillis),
        @"first_tap_max_ms": @((int)llround(MaximumFirstTapDurationSeconds * 1000.0)),
        @"first_tap_event_distance_points": @(MaximumFirstTapEventDistancePoints),
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
             URLByAppendingPathComponent:@"TapDrag" isDirectory:YES]
            URLByAppendingPathComponent:@"Diagnostics" isDirectory:YES];
}

static void pruneLogs(NSURL *directory, NSURL *protectedURL) {
    NSArray<NSURL *> *files = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:directory includingPropertiesForKeys:@[NSURLContentModificationDateKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    files = [files filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *_) {
        (void)_; return [url.lastPathComponent hasPrefix:@"double-tap-"] && [url.pathExtension isEqualToString:@"jsonl"];
    }]];
    files = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSString *protectedPath = protectedURL.URLByStandardizingPath.path;
        if (protectedPath && [a.URLByStandardizingPath.path isEqualToString:protectedPath])
            return NSOrderedAscending;
        if (protectedPath && [b.URLByStandardizingPath.path isEqualToString:protectedPath])
            return NSOrderedDescending;
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
    if (![[NSData data] writeToURL:gAutomaticLogURL options:NSDataWritingAtomic error:nil])
        atomic_store(&gLoggingFaulted, true);
    else
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0600)}
                                        ofItemAtPath:gAutomaticLogURL.path error:nil];
    pruneLogs(directory, gAutomaticLogURL);
    if (gLoggingQueue == NULL) gLoggingQueue = dispatch_queue_create("io.github.efilo1.TapDrag.logs", DISPATCH_QUEUE_SERIAL);
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

static BOOL loggingShouldRun(BOOL featureEnabled, BOOL automaticLoggingEnabled) {
    return featureEnabled && automaticLoggingEnabled;
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
        if (builtIn) return internalPresent ? atomic_load(&gInternalDraggingEnabled) : YES;
        return bluetoothPresent ? atomic_load(&gBluetoothDraggingEnabled) : YES;
    }
    if (!internalPresent && !bluetoothPresent) return YES;
    return (internalPresent && atomic_load(&gInternalDraggingEnabled)) ||
        (bluetoothPresent && atomic_load(&gBluetoothDraggingEnabled));
}

static BOOL replacementActive(MTDeviceRef device) {
    return atomic_load(&gEnabled) && !atomic_load(&gInputSuspended) &&
        !nativeDraggingForDevice(device);
}

static BOOL shouldUseMultitouchDevice(MTDeviceRef device) {
    if (!gDeviceGetSensorDimensions) return YES;
    int rows = 0, columns = 0;
    int status = gDeviceGetSensorDimensions(device, &rows, &columns);
    (void)columns;
    return status != 0 || rows >= MinimumTrackpadSensorRows;
}

static BOOL refreshDraggingPreferences(void) {
    BOOL oldIP = atomic_load(&gInternalDraggingPresent);
    BOOL oldIE = atomic_load(&gInternalDraggingEnabled);
    BOOL oldBP = atomic_load(&gBluetoothDraggingPresent);
    BOOL oldBE = atomic_load(&gBluetoothDraggingEnabled);
    BOOL oldAny = atomic_load(&gAnyNativeDraggingEnabled);
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
    BOOL changed = oldIP != ip || oldIE != ie || oldBP != bp || oldBE != be || oldAny != any;
    if (changed)
        recordDiagnostic(DiagnosticConfiguration, any ? ReasonNativeDragging : ReasonNone,
                         0, DragPhaseIdle, NULL, CGPointZero, 0, 0, 0, NO, NO);
    return changed;
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
    s->nativeButtonDownDuringTouch = NO;
    s->maximumSquaredDistance = s->maximumSquaredDistanceMM = 0;
    s->chainCandidate = NO; s->chainGeneration = 0;
    s->movementConfirmed = s->holdConfirmed = s->startRequested = NO;
}

static void clearPendingFirstTap(DeviceState *s) {
    s->firstTapPending = NO;
    s->firstTapCompletedTimestamp = 0;
    s->firstTapCompletedUptime = 0;
    s->firstTapPointer = CGPointZero;
    s->firstTapPointerValid = NO;
}

static void resetDevice(DeviceState *s) {
    resetCurrentTouch(s); s->touchingCount = s->maximumTouching = 0;
    clearPendingFirstTap(s);
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

static BOOL contactCanTransferIdentity(const DeviceState *s, MTDeviceRef device,
                                       ChainSnapshot chain) {
    if (!s->chainCandidate) return YES;
    return s->chainGeneration == chain.generation && chain.device == device &&
        (chain.phase == DragPhaseCandidate || chain.phase == DragPhaseStarting ||
         chain.phase == DragPhaseOwned);
}

static int markNativeButtonDownDuringFirstContacts(void) {
    int marked = 0;
    os_unfair_lock_lock(&gStateLock);
    for (int i = 0; i < gDeviceCount; i++) {
        DeviceState *s = &gDevices[i];
        if (s->touchingCount > 0 && s->touchMade && !s->chainCandidate &&
            replacementActive(s->device)) {
            s->nativeButtonDownDuringTouch = YES;
            marked++;
        }
    }
    os_unfair_lock_unlock(&gStateLock);
    return marked;
}

static BOOL adoptReplacementIdentity(DeviceState *s, const void *contacts, int count) {
    if (contacts == NULL || count <= 0) return NO;
    const MTTouch *touches = contacts; const MTTouch *replacement = NULL;
    for (int i = 0; i < count; i++) if (actualTouch(touches[i].state)) {
        if (replacement != NULL) return NO;
        replacement = &touches[i];
    }
    if (replacement == NULL) return NO;
    s->pathIndex = replacement->pathIndex; s->fingerID = replacement->fingerID;
    s->identityValid = YES;
    s->touchStartedPosition = replacement->normalizedVector.position;
    s->touchStartedAbsolutePosition = replacement->absoluteVector.position;
    return YES;
}

static void observePosition(DeviceState *s, MTPoint position, MTPoint absolutePosition) {
    float dx = position.x - s->touchStartedPosition.x;
    float dy = position.y - s->touchStartedPosition.y;
    float distance = dx * dx + dy * dy;
    s->maximumSquaredDistance = MAX(s->maximumSquaredDistance, distance);
    float mmX = absolutePosition.x - s->touchStartedAbsolutePosition.x;
    float mmY = absolutePosition.y - s->touchStartedAbsolutePosition.y;
    float distanceMM = mmX * mmX + mmY * mmY;
    BOOL absoluteValid = isfinite(s->touchStartedAbsolutePosition.x) &&
        isfinite(s->touchStartedAbsolutePosition.y) && isfinite(absolutePosition.x) &&
        isfinite(absolutePosition.y) &&
        ((s->touchStartedAbsolutePosition.x != 0 || s->touchStartedAbsolutePosition.y != 0) &&
         (absolutePosition.x != 0 || absolutePosition.y != 0));
    if (absoluteValid && isfinite(distanceMM)) {
        s->maximumSquaredDistanceMM = MAX(s->maximumSquaredDistanceMM, distanceMM);
        if (distanceMM >= TapMoveThresholdMillimeters * TapMoveThresholdMillimeters)
            s->touchMoved = YES;
    } else if (distance >= FallbackNormalizedMoveThreshold * FallbackNormalizedMoveThreshold) {
        s->touchMoved = YES;
    }
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
    ChainSnapshot s = {gChain.phase, gChain.generation, gChain.device,
                       gChain.eventNumber};
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
        gChain.start = gChain.latest = start;
        gChain.startValid = gChain.latestValid = valid;
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
        recordDiagnostic(DiagnosticSyntheticUp, ReasonLift, generation,
            DragPhaseReleasing, up, location, 0, 0, 0, YES, NO);
        CGEventPost(InputTapLocation, up); CFRelease(up);
    }
    os_unfair_lock_unlock(&gSyntheticLock); return up != NULL;
}

static BOOL locationsDiffer(CGPoint a, CGPoint b) {
    return fabs(a.x - b.x) >= 0.5 || fabs(a.y - b.y) >= 0.5;
}

static void discardBufferedTapLocked(void) {
    if (gBufferedTapDown) CFRelease(gBufferedTapDown);
    if (gBufferedTapUp) CFRelease(gBufferedTapUp);
    gBufferedTapDown = gBufferedTapUp = NULL;
    gBufferedTapDevice = NULL;
    ++gBufferedTapToken;
}

static void postBufferedButtonLocked(CGEventRef original) {
    CGEventRef event = CGEventCreateCopy(original);
    if (!event) return;
    CGEventSetSource(event, gSyntheticSource);
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, DoubleTapTag);
    CGEventSetTimestamp(event, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    recordDiagnostic(DiagnosticNativePassed, ReasonFirstTap, 0, DragPhaseIdle,
                     event, CGEventGetLocation(event), 0, 0, 0, NO, NO);
    CGEventPost(InputTapLocation, event);
    CFRelease(event);
}

static void flushBufferedTapLocked(void) {
    if (!gBufferedTapDown || !gBufferedTapUp) {
        discardBufferedTapLocked();
        return;
    }
    CGPoint pointer = CGPointZero;
    BOOL restore = gBufferedTapUp && copyPointerLocation(&pointer) &&
        locationsDiffer(pointer, CGEventGetLocation(gBufferedTapUp));
    if (gBufferedTapDown) postBufferedButtonLocked(gBufferedTapDown);
    if (gBufferedTapUp) postBufferedButtonLocked(gBufferedTapUp);
    if (restore) {
        CGEventRef move = createTaggedEvent(kCGEventMouseMoved, pointer, 0);
        if (move) { CGEventPost(InputTapLocation, move); CFRelease(move); }
    }
    discardBufferedTapLocked();
}

static void expireBufferedTap(unsigned long long token) {
    os_unfair_lock_lock(&gSyntheticLock);
    if (token == gBufferedTapToken && gBufferedTapDown) {
        ChainSnapshot s = chainSnapshot();
        BOOL deciding = s.device == gBufferedTapDevice &&
            (s.phase == DragPhaseCandidate || s.phase == DragPhaseStarting);
        if (deciding && atomic_load(&gEnabled)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{ expireBufferedTap(token); });
        } else flushBufferedTapLocked();
    }
    os_unfair_lock_unlock(&gSyntheticLock);
}

static BOOL firstTapCandidateMatchesEvent(const DeviceState *state,
                                          CGEventRef event,
                                          uint64_t now) {
    if (!state->firstTapPending || state->touchingCount != 0 ||
        !state->firstTapPointerValid || state->firstTapCompletedUptime == 0 ||
        now < state->firstTapCompletedUptime) return NO;
    uint64_t maximumAge = (uint64_t)(doubleTapDragGapMillis() +
        FirstClickAllowanceMillis) * NSEC_PER_MSEC;
    if (now - state->firstTapCompletedUptime > maximumAge) return NO;
    CGPoint eventLocation = CGEventGetLocation(event);
    return hypot(eventLocation.x - state->firstTapPointer.x,
                 eventLocation.y - state->firstTapPointer.y) <=
        MaximumFirstTapEventDistancePoints;
}

static BOOL bufferTrackpadTapButton(CGEventType type, CGEventRef event) {
    if (type != kCGEventLeftMouseDown && type != kCGEventLeftMouseUp) return NO;
    MTDeviceRef device = NULL;
    if (type == kCGEventLeftMouseDown &&
        CGEventGetIntegerValueField(event, kCGMouseEventSubtype) == NSEventSubtypeTouch) {
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        os_unfair_lock_lock(&gStateLock);
        for (int i = 0; i < gDeviceCount; ++i) {
            DeviceState *s = &gDevices[i];
            BOOL matches = replacementActive(s->device) &&
                firstTapCandidateMatchesEvent(s, event, now);
            if (matches) {
                if (device) { device = NULL; break; }
                device = s->device;
            }
        }
        os_unfair_lock_unlock(&gStateLock);
    }
    os_unfair_lock_lock(&gSyntheticLock);
    int64_t number = CGEventGetIntegerValueField(event, kCGMouseEventNumber);
    BOOL consumed = NO;
    if (gReplayedButtonNumber && type == kCGEventLeftMouseUp && number == gReplayedButtonNumber) {
        postBufferedButtonLocked(event);
        gReplayedButtonNumber = 0;
        consumed = YES;
    } else if (gBufferedTapDown) {
        if (type == kCGEventLeftMouseUp && number ==
            CGEventGetIntegerValueField(gBufferedTapDown, kCGMouseEventNumber)) {
            if (gBufferedTapUp) CFRelease(gBufferedTapUp);
            gBufferedTapUp = CGEventCreateCopy(event);
        } else {
            // Post both clicks through the same queue; returning the new native
            // down directly could overtake the replayed first click.
            flushBufferedTapLocked();
            postBufferedButtonLocked(event);
            gReplayedButtonNumber = type == kCGEventLeftMouseDown ? number : 0;
        }
        consumed = YES;
    } else if (device) {
        gBufferedTapDown = CGEventCreateCopy(event);
        if (gBufferedTapDown) {
            gBufferedTapDevice = device;
            unsigned long long token = ++gBufferedTapToken;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (doubleTapDragGapMillis() + FirstClickAllowanceMillis) * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{ expireBufferedTap(token); });
            consumed = YES;
        }
    }
    if (consumed) recordDiagnostic(DiagnosticNativeFiltered, ReasonFirstTap, 0,
        chainSnapshot().phase, event, CGEventGetLocation(event), 0, 0, 0, NO, NO);
    os_unfair_lock_unlock(&gSyntheticLock);
    return consumed;
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
        return NO;
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
    if (gBufferedTapDevice == device) {
        recordDiagnostic(DiagnosticNativeFiltered, ReasonSecondTap, generation, gChain.phase,
            gBufferedTapDown, start, 0, 0, 0, YES, NO);
        discardBufferedTapLocked();
    }
    recordDiagnostic(DiagnosticSyntheticDown, ReasonSecondTap, generation,
        phase, down, start, 0, 0, 0, YES, NO);
    CGEventPost(InputTapLocation, down); CFRelease(down);
    if (drag) {
        recordDiagnostic(DiagnosticSyntheticDrag, ReasonMovement,
            generation, phase, drag, latest, 0, 0, 0, YES, NO);
        CGEventPost(InputTapLocation, drag); CFRelease(drag);
    }
    if (up) {
        recordDiagnostic(DiagnosticSyntheticUp, ReasonLift, generation,
            phase, up, latest, 0, 0, 0, YES, NO);
        CGEventPost(InputTapLocation, up); CFRelease(up); resetChainLocked(ReasonLift);
    }
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
    os_unfair_lock_lock(&gSyntheticLock);
    if (reason == ReasonSystemSuspended || reason == ReasonSystemResumed)
        discardBufferedTapLocked();
    else flushBufferedTapLocked();
    gReplayedButtonNumber = 0;
    os_unfair_lock_unlock(&gSyntheticLock);
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

static CGEventRef createDragFromMovement(CGEventRef movement, int64_t number) {
    CGEventRef drag = createTaggedEvent(kCGEventLeftMouseDragged,
                                       CGEventGetLocation(movement), number);
    if (!drag) return NULL;
    CGEventSetFlags(drag, CGEventGetFlags(movement));
    CGEventSetIntegerValueField(drag, kCGMouseEventDeltaX,
        CGEventGetIntegerValueField(movement, kCGMouseEventDeltaX));
    CGEventSetIntegerValueField(drag, kCGMouseEventDeltaY,
        CGEventGetIntegerValueField(movement, kCGMouseEventDeltaY));
    CGEventSetDoubleValueField(drag, kCGMouseEventPressure, 1.0);
    return drag;
}

static BOOL postNativeMovementAsDrag(CGEventRef event, ChainSnapshot snapshot) {
    // Returning a mutated native event can overtake a posted down. Post the
    // replacement under the same lock as down/up and consume the native event.
    os_unfair_lock_lock(&gSyntheticLock);
    os_unfair_lock_lock(&gChainLock);
    BOOL current = gChain.generation == snapshot.generation && gChain.phase == DragPhaseOwned &&
        gChain.eventNumber == snapshot.eventNumber;
    if (!current) {
        os_unfair_lock_unlock(&gChainLock);
        os_unfair_lock_unlock(&gSyntheticLock);
        return NO;
    }
    CGPoint location = CGEventGetLocation(event);
    recordDiagnostic(DiagnosticMovementInput, ReasonMovement,
        snapshot.generation, DragPhaseOwned, event, location,
        0, 0, 0, YES, NO);
    CGEventRef drag = createDragFromMovement(event, snapshot.eventNumber);
    gChain.latest = location; gChain.latestValid = YES;
    if (drag) {
        recordDiagnostic(DiagnosticSyntheticDrag, ReasonMovement,
            snapshot.generation, DragPhaseOwned, drag, location,
            0, 0, 0, YES, NO);
        CGEventPost(InputTapLocation, drag);
        CFRelease(drag);
    }
    os_unfair_lock_unlock(&gChainLock);
    os_unfair_lock_unlock(&gSyntheticLock);
    return drag != NULL;
}

static BOOL activeEventTapsValid(void);

static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    (void)proxy; (void)context;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        ChainSnapshot s = chainSnapshot();
        recordDiagnostic(DiagnosticFailure, ReasonEventTapDisabled, s.generation, s.phase,
                         event, CGPointZero, 0, 0, 0, NO, NO);
        atomic_store(&gInputSuspended, true);
        interruptChain(ReasonEventTapDisabled);
        if (gEventTap) CGEventTapEnable(gEventTap, true);
        if (activeEventTapsValid()) atomic_store(&gInputSuspended, false);
        return event;
    }
    if (event == NULL || ownEvent(event) || !atomic_load(&gEnabled)) return event;
    BOOL button = type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp;
    if (button) {
        int marked = type == kCGEventLeftMouseDown
            ? markNativeButtonDownDuringFirstContacts() : 0;
        ChainSnapshot observed = chainSnapshot();
        recordDiagnostic(DiagnosticNativeObserved,
            marked > 0 ? ReasonNativeButtonDuringTouch : ReasonNone,
            observed.generation, observed.phase, event, CGEventGetLocation(event),
            0, 0, marked, NO, NO);
    }
    ChainSnapshot s = chainSnapshot();
    NativeDisposition disposition = dispositionForEvent(s, type);
    if (disposition == NativePass) {
        if ((type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp) && s.phase != DragPhaseIdle)
            recordDiagnostic(DiagnosticNativePassed, ReasonFirstTap, s.generation, s.phase,
                             event, CGEventGetLocation(event), 0, 0, 0, NO, NO);
        return event;
    }
    if (disposition == NativeReplaceDrag &&
        postNativeMovementAsDrag(event, s)) return NULL;
    recordDiagnostic(DiagnosticNativeFiltered, ReasonNone, s.generation, s.phase,
                     event, CGEventGetLocation(event), 0, 0, 0, YES, NO);
    return NULL;
}

static CGEventRef clickBufferCallback(CGEventTapProxy proxy, CGEventType type,
                                      CGEventRef event, void *context) {
    (void)proxy; (void)context;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        atomic_store(&gInputSuspended, true);
        interruptChain(ReasonEventTapDisabled);
        if (gClickTap) CGEventTapEnable(gClickTap, true);
        if (activeEventTapsValid()) atomic_store(&gInputSuspended, false);
        return event;
    }
    if (!event || ownEvent(event) || !atomic_load(&gEnabled)) return event;
    return bufferTrackpadTapButton(type, event) ? NULL : event;
}

static CGEventRef downstreamObserverCallback(CGEventTapProxy proxy, CGEventType type,
                                             CGEventRef event, void *context) {
    (void)proxy; (void)context;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        recordDiagnostic(DiagnosticFailure, ReasonObserverDisabled, 0, DragPhaseIdle,
                         NULL, CGPointZero, 0, 0, 0, NO, NO);
        if (gObserverTap) CGEventTapEnable(gObserverTap, true);
        atomic_store(&gObserverActive,
                     gObserverTap && CGEventTapIsEnabled(gObserverTap));
        return event;
    }
    if (!event || !atomic_load(&gEnabled)) return event;
    ChainSnapshot s = chainSnapshot();
    BOOL active = s.phase != DragPhaseIdle;
    if (!ownEvent(event) && type != kCGEventLeftMouseDown && type != kCGEventLeftMouseUp &&
        type != kCGEventLeftMouseDragged && !active)
        return event;
    // Released chains may already be reset. The tag and event number still
    // correlate those observations with their original transaction records.
    BOOL current = ownEvent(event) && s.eventNumber > 0 &&
        s.eventNumber == CGEventGetIntegerValueField(event, kCGMouseEventNumber);
    recordDiagnostic(DiagnosticDownstreamObserved, ReasonNone,
        (current || (!ownEvent(event) && active)) ? s.generation : 0,
        s.phase, event, CGEventGetLocation(event),
        0, 0, 0, NO, NO);
    return event;
}

static void completeTouch(DeviceState *s, double timestamp, BOOL *candidate,
                          unsigned long long *generation, BOOL *movement) {
    int duration = touchDurationMillis(s, timestamp);
    *candidate = s->chainCandidate; *generation = s->chainGeneration; *movement = s->movementConfirmed;
    DiagnosticReason reason = ReasonNone; DiagnosticKind kind = DiagnosticReset;
    if (s->touchInvalid) {
        clearPendingFirstTap(s); reason = ReasonMultiFinger;
    } else if (!s->chainCandidate && s->nativeButtonDownDuringTouch) {
        clearPendingFirstTap(s);
        reason = ReasonNativeButtonDuringTouch;
    } else if (s->chainCandidate) {
        clearPendingFirstTap(s);
        reason = s->movementConfirmed ? (s->holdConfirmed ? ReasonHold : ReasonMovement) : ReasonNoMovement;
    } else if (s->touchMade && duration <= MaximumFirstTapDurationSeconds * 1000.0 &&
               !s->touchMoved) {
        s->firstTapPending = YES; s->firstTapCompletedTimestamp = timestamp;
        s->firstTapCompletedUptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        s->firstTapPointerValid = copyPointerLocation(&s->firstTapPointer);
        reason = ReasonFirstTap; kind = DiagnosticFirstTap;
    } else {
        clearPendingFirstTap(s);
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
    BOOL schedule = NO, scheduleHold = NO, ownedUp = NO, interrupt = NO;
    unsigned long long generation = 0, epoch = 0; long long notBefore = 0;
    int64_t number = 0; CGPoint releaseLocation = CGPointZero;
    os_unfair_lock_lock(&gStateLock); DeviceState *s = deviceStateLocked(device);
    if (s == NULL) { os_unfair_lock_unlock(&gStateLock); return 0; }
    if (!atomic_load(&gEnabled)) { resetDevice(s); os_unfair_lock_unlock(&gStateLock); return 0; }
    BOOL identityChanged = replacementActive(device) && count == 1 && s->touchingCount == 1 &&
        s->maximumTouching == 1 && s->touchMade && s->identityValid &&
        (!frameContainsIdentity(s, contacts, contactCount) || frameReplacesIdentity(s, contacts, contactCount));
    if (identityChanged) {
        ChainSnapshot chain = chainSnapshot();
        if (contactCanTransferIdentity(s, device, chain) &&
            adoptReplacementIdentity(s, contacts, contactCount)) {
            unsigned long long diagnosticGeneration = s->chainCandidate
                ? chain.generation : 0;
            recordDiagnostic(DiagnosticIdentityTransfer, ReasonIdentityTransfer,
                diagnosticGeneration, chain.phase, NULL, s->pointerStart,
                0, s->touchingFrames, 1, s->touchMoved, NO);
        } else {
            observeBreak(s, contacts, contactCount); os_unfair_lock_unlock(&gStateLock);
            contactFrameCallback(device, NULL, 0, timestamp, frame);
            return contactFrameCallback(device, contacts, contactCount, timestamp, frame);
        }
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
                BOOL recent = s->firstTapPending && validSecondContactGapMillis(gap);
                if (recent && beginSecondContact(device, s->pointerStart,
                                                 s->pointerStartValid, gap,
                                                 &generation)) {
                    s->chainCandidate = YES; s->chainGeneration = generation;
                    scheduleHold = YES; epoch = atomic_load(&gFeatureEpoch);
                } else if (s->firstTapPending && !recent) {
                    DiagnosticReason reason = gap >= 0 && gap < MinimumSecondContactGapMillis
                        ? ReasonIntertapTooShort : ReasonIntertapExpired;
                    recordDiagnosticDetails(DiagnosticReset, reason,
                        0, chainSnapshot().phase, NULL, s->pointerStart, 0, gap, 0,
                        0, count, NO, NO);
                    clearPendingFirstTap(s);
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
        } else resetCurrentTouch(s);
        os_unfair_lock_unlock(&gStateLock);
        if (interrupt) interruptChain(ReasonMultiFinger);
        if (scheduleHold) scheduleHoldPromotion(device, generation, epoch);
        if (schedule) scheduleStart(device, generation, notBefore, epoch);
        return 0;
    }
    if (s->touchingCount == 0) { os_unfair_lock_unlock(&gStateLock); return 0; }
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
    if (schedule) scheduleStart(device, generation, notBefore, epoch);
    if (ownedUp) {
        if (!(postUp(number, releaseLocation, generation) && finishRelease(generation)))
            resetChain(generation, ReasonStale);
    }
    return 0;
}

typedef enum { AccessGranted, AccessRequired } AccessStatus;

static CGEventMask diagnosticMouseMask(void) {
    return CGEventMaskBit(kCGEventMouseMoved) | CGEventMaskBit(kCGEventLeftMouseDown) |
        CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventLeftMouseUp) |
        CGEventMaskBit(kCGEventScrollWheel) |
        CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp) |
        CGEventMaskBit(kCGEventRightMouseDragged) | CGEventMaskBit(kCGEventOtherMouseDown) |
        CGEventMaskBit(kCGEventOtherMouseUp) | CGEventMaskBit(kCGEventOtherMouseDragged) |
        CGEventMaskBit(kCGEventTabletPointer) | CGEventMaskBit(kCGEventTabletProximity);
}

static BOOL activeEventTapsValid(void) {
    return gEventTap && gEventTapSource && CFMachPortIsValid(gEventTap) &&
        CGEventTapIsEnabled(gEventTap) && gClickTap && gClickTapSource &&
        CFMachPortIsValid(gClickTap) && CGEventTapIsEnabled(gClickTap);
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(strong) NSStatusItem *statusItem;
@property(strong) NSMenuItem *enabledItem;
@property(strong) NSMenuItem *launchAtLoginItem, *loginApprovalItem;
@property(strong) NSMenuItem *replacementStatus, *diagnosticStatus, *accessibilityItem;
@property(strong) NSMenuItem *automaticLoggingItem;
@property(strong) NSTimer *configurationTimer;
@property(assign) BOOL inputSessionActive;
@property(strong) NSArray *deviceList;
@property(assign) void *multitouchHandle;
@property(assign) IONotificationPortRef hotplugPort;
@property(assign) io_iterator_t addedTrackpads, removedTrackpads;
- (BOOL)rebuildMultitouchDevices;
- (void)resetInputState:(DiagnosticReason)reason;
- (void)updateStatus;
@end

static void drainDeviceIterator(io_iterator_t iterator) {
    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) IOObjectRelease(service);
}

static void multitouchTopologyChanged(void *context, io_iterator_t iterator) {
    drainDeviceIterator(iterator);
    AppDelegate *delegate = (__bridge AppDelegate *)context;
    if (!delegate.inputSessionActive) return;
    atomic_store(&gInputSuspended, true);
    [delegate resetInputState:ReasonDeviceTopology];
    BOOL devicesReady = [delegate rebuildMultitouchDevices];
    if (!devicesReady) recordDiagnostic(DiagnosticFailure, ReasonMultitouchUnavailable,
        0, DragPhaseIdle, NULL, CGPointZero, 0, 0, 0, NO, NO);
    if (!atomic_load(&gEnabled) || (devicesReady && activeEventTapsValid()))
        atomic_store(&gInputSuspended, false);
    [delegate updateStatus];
}

@implementation AppDelegate

- (AccessStatus)accessStatus:(BOOL)prompt {
    BOOL post = CGPreflightPostEventAccess(), listen = CGPreflightListenEventAccess();
    if (prompt && !post) CGRequestPostEventAccess(); if (prompt && !listen) CGRequestListenEventAccess();
    return CGPreflightPostEventAccess() && CGPreflightListenEventAccess() ? AccessGranted : AccessRequired;
}

- (BOOL)installEventTap {
    if (gSyntheticSource == NULL) return NO;
    if (gEventTap || gEventTapSource || gClickTap || gClickTapSource) {
        BOOL valid = gEventTap && gEventTapSource && CFMachPortIsValid(gEventTap) &&
            gClickTap && gClickTapSource && CFMachPortIsValid(gClickTap);
        if (valid) {
            CGEventTapEnable(gEventTap, true);
            CGEventTapEnable(gClickTap, true);
            if (CGEventTapIsEnabled(gEventTap) && CGEventTapIsEnabled(gClickTap)) return YES;
        }
        [self removeEventTap];
    }
    CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved) | CGEventMaskBit(kCGEventLeftMouseDown) |
        CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventLeftMouseUp);
    // Down, drag, up, and conflicting native buttons share this input stage.
    gEventTap = CGEventTapCreate(InputTapLocation, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                 mask, eventTapCallback, NULL);
    if (!gEventTap) return NO;
    gEventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gEventTap, 0);
    if (!gEventTapSource) { CFRelease(gEventTap); gEventTap = NULL; return NO; }
    CFRunLoopAddSource(CFRunLoopGetMain(), gEventTapSource, kCFRunLoopCommonModes);
    // Correlate WindowServer's annotated tap click with the completed raw tap.
    gClickTap = CGEventTapCreate(kCGAnnotatedSessionEventTap, kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp),
        clickBufferCallback, NULL);
    if (gClickTap)
        gClickTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gClickTap, 0);
    if (!gClickTapSource) { [self removeEventTap]; return NO; }
    CFRunLoopAddSource(CFRunLoopGetMain(), gClickTapSource, kCFRunLoopCommonModes);
    // Observe possible interference without expanding the active filter or
    // collecting keyboard input. Ordinary moves are relevant during a drag.
    gObserverTap = CGEventTapCreate(kCGAnnotatedSessionEventTap, kCGTailAppendEventTap,
        kCGEventTapOptionListenOnly, diagnosticMouseMask(), downstreamObserverCallback, NULL);
    if (gObserverTap) {
        gObserverTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gObserverTap, 0);
        if (gObserverTapSource) {
            CFRunLoopAddSource(CFRunLoopGetMain(), gObserverTapSource, kCFRunLoopCommonModes);
            atomic_store(&gObserverActive, true);
        } else {
            CFMachPortInvalidate(gObserverTap); CFRelease(gObserverTap); gObserverTap = NULL;
        }
    }
    if (!atomic_load(&gObserverActive))
        recordDiagnostic(DiagnosticFailure, ReasonObserverUnavailable, 0, DragPhaseIdle,
                         NULL, CGPointZero, 0, 0, 0, NO, NO);
    if (!gEventTap || !gClickTap) { [self removeEventTap]; return NO; }
    CGEventTapEnable(gEventTap, true);
    CGEventTapEnable(gClickTap, true);
    if (CGEventTapIsEnabled(gEventTap) && CGEventTapIsEnabled(gClickTap)) return YES;
    [self removeEventTap];
    return NO;
}

- (void)removeEventTap {
    if (gClickTapSource) { CFRunLoopRemoveSource(CFRunLoopGetMain(), gClickTapSource, kCFRunLoopCommonModes); CFRelease(gClickTapSource); gClickTapSource = NULL; }
    if (gClickTap) { CFMachPortInvalidate(gClickTap); CFRelease(gClickTap); gClickTap = NULL; }
    atomic_store(&gObserverActive, false);
    if (gObserverTapSource) { CFRunLoopRemoveSource(CFRunLoopGetMain(), gObserverTapSource, kCFRunLoopCommonModes); CFRelease(gObserverTapSource); gObserverTapSource = NULL; }
    if (gObserverTap) { CFMachPortInvalidate(gObserverTap); CFRelease(gObserverTap); gObserverTap = NULL; }
    if (gEventTapSource) { CFRunLoopRemoveSource(CFRunLoopGetMain(), gEventTapSource, kCFRunLoopCommonModes); CFRelease(gEventTapSource); gEventTapSource = NULL; }
    if (gEventTap) { CFMachPortInvalidate(gEventTap); CFRelease(gEventTap); gEventTap = NULL; }
}

- (void)updateLaunchAtLoginStatus {
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    switch (status) {
        case SMAppServiceStatusEnabled:
            self.launchAtLoginItem.state = NSControlStateValueOn; break;
        case SMAppServiceStatusRequiresApproval:
            self.launchAtLoginItem.state = NSControlStateValueMixed; break;
        case SMAppServiceStatusNotRegistered:
        case SMAppServiceStatusNotFound:
            self.launchAtLoginItem.state = NSControlStateValueOff; break;
    }
    self.loginApprovalItem.hidden = status != SMAppServiceStatusRequiresApproval;
}

- (void)openLoginItemsSettings:(id)sender {
    (void)sender; [SMAppService openSystemSettingsLoginItems];
}

- (void)toggleLaunchAtLogin:(id)sender {
    (void)sender;
    SMAppService *service = SMAppService.mainAppService;
    SMAppServiceStatus status = service.status;
    BOOL disable = status == SMAppServiceStatusEnabled || status == SMAppServiceStatusRequiresApproval;
    NSError *error = nil;
    BOOL success = disable ? [service unregisterAndReturnError:&error]
                           : [service registerAndReturnError:&error];
    [self updateLaunchAtLoginStatus];
    if (!disable && service.status == SMAppServiceStatusRequiresApproval) {
        [self openLoginItemsSettings:nil];
    } else if (!success) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Launch at Login Could Not Be Updated";
        alert.informativeText = error.localizedDescription ?: @"macOS could not update the login item. Please try again.";
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Open Login Items Settings"];
        if ([alert runModal] == NSAlertSecondButtonReturn) [self openLoginItemsSettings:nil];
    }
}

- (void)updateStatus {
    [self updateLaunchAtLoginStatus];
    if (self.replacementStatus) {
        self.replacementStatus.title = !atomic_load(&gEnabled)
            ? @"TapDrag: Disabled"
            : ([self accessStatus:NO] != AccessGranted
                ? @"TapDrag: Accessibility / Input Monitoring Required"
                : (atomic_load(&gInputSuspended)
                    ? (atomic_load(&gMultitouchReady)
                        ? @"TapDrag: Paused; event taps unavailable"
                        : @"TapDrag: Paused; trackpad unavailable")
                    : (atomic_load(&gAnyNativeDraggingEnabled)
                    ? @"TapDrag: Inactive; turn off macOS trackpad dragging"
                    : @"TapDrag: Ready")));
    }
    if (self.diagnosticStatus) {
        os_unfair_lock_lock(&gDiagnosticLock); uint64_t count = MIN(gRecordSequence, (uint64_t)DiagnosticCapacity); os_unfair_lock_unlock(&gDiagnosticLock);
        NSString *loggingStatus = atomic_load(&gLoggingFaulted) ? @", write failed"
            : (atomic_load(&gLoggingActive) ? @", auto saved"
                : (atomic_load(&gAutomaticLoggingEnabled) ? @", auto save paused" : @", memory only"));
        self.diagnosticStatus.title = [NSString stringWithFormat:@"Diagnostics: %llu events%@", count, loggingStatus];
        self.automaticLoggingItem.state = atomic_load(&gAutomaticLoggingEnabled)
            ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (NSMenuItem *)item:(NSString *)title action:(SEL)action menu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self; [menu addItem:item]; return item;
}

- (void)setupStatusItem {
    if (self.statusItem) return;
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"hand.tap.fill" accessibilityDescription:@"TapDrag"];
    if (image) { image.template = YES; self.statusItem.button.image = image; }
    else self.statusItem.button.title = @"TD";
    self.statusItem.button.toolTip = @"TapDrag";
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""]; menu.delegate = self;
    self.enabledItem = [self item:@"Enabled" action:@selector(toggleEnabled:) menu:menu]; self.enabledItem.state = atomic_load(&gEnabled);
    self.launchAtLoginItem = [self item:@"Launch at Login" action:@selector(toggleLaunchAtLogin:) menu:menu];
    self.loginApprovalItem = [self item:@"Approve Launch at Login..." action:@selector(openLoginItemsSettings:) menu:menu];
    self.loginApprovalItem.hidden = YES;
    self.replacementStatus = [self item:@"TapDrag: checking" action:nil menu:menu]; self.replacementStatus.enabled = NO;
    NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:@"Diagnostics" action:nil keyEquivalent:@""];
    NSMenu *diagnostics = [[NSMenu alloc] initWithTitle:@"Diagnostics"];
    self.automaticLoggingItem = [self item:@"Automatic Logging" action:@selector(toggleAutomaticLogging:) menu:diagnostics];
    self.diagnosticStatus = [self item:@"Diagnostics: 0 events" action:nil menu:diagnostics]; self.diagnosticStatus.enabled = NO;
    [diagnostics addItem:[NSMenuItem separatorItem]];
    [self item:@"Copy Diagnostic Summary" action:@selector(copyDiagnostics:) menu:diagnostics];
    [self item:@"Export Diagnostic Trace..." action:@selector(exportDiagnostics:) menu:diagnostics];
    [self item:@"Reveal Automatic Diagnostic Logs" action:@selector(revealDiagnostics:) menu:diagnostics];
    [self item:@"Clear Diagnostic Trace" action:@selector(clearDiagnostics:) menu:diagnostics];
    root.submenu = diagnostics; [menu addItem:root];
    self.accessibilityItem = [self item:@"Accessibility Permission Required" action:@selector(requestAccessibility:) menu:menu];
    [self item:@"Hide Menu Bar Icon" action:@selector(hideStatusItem:) menu:menu]; [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"]; quit.target = NSApp; [menu addItem:quit];
    self.statusItem.menu = menu; [self updateStatus];
}

- (void)toggleEnabled:(id)sender {
    (void)sender; refreshDraggingPreferences(); BOOL enable = !atomic_load(&gEnabled);
    if (enable && ([self accessStatus:YES] != AccessGranted || ![self installEventTap])) {
        NSAlert *alert = [[NSAlert alloc] init]; alert.messageText = @"TapDrag Was Not Enabled";
        alert.informativeText = @"Grant Accessibility and, if requested, Input Monitoring permission to this app, then try again.";
        [alert addButtonWithTitle:@"Open Accessibility Settings"]; [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] == NSAlertFirstButtonReturn) [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]]; return;
    }
    atomic_store(&gEnabled, enable);
    if (enable) atomic_store(&gInputSuspended, !atomic_load(&gMultitouchReady));
    if (loggingShouldRun(enable, atomic_load(&gAutomaticLoggingEnabled))) startLogging();
    else stopLogging();
    if (!enable) { atomic_fetch_add(&gFeatureEpoch, 1); interruptChain(ReasonDisabled); os_unfair_lock_lock(&gStateLock); resetAllDevicesLocked(); os_unfair_lock_unlock(&gStateLock); }
    [[NSUserDefaults standardUserDefaults] setBool:enable forKey:EnabledKey]; self.enabledItem.state = enable;
    [self updateStatus];
}

- (void)toggleAutomaticLogging:(id)sender {
    (void)sender;
    BOOL enabled = !atomic_load(&gAutomaticLoggingEnabled);
    atomic_store(&gAutomaticLoggingEnabled, enabled);
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:AutomaticLoggingKey];
    if (loggingShouldRun(atomic_load(&gEnabled), enabled)) startLogging();
    else stopLogging();
    [self updateStatus];
}

- (void)requestAccessibility:(id)sender { (void)sender; AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES}); }
- (void)copyDiagnostics:(id)sender { (void)sender; NSPasteboard *p = NSPasteboard.generalPasteboard; [p clearContents]; [p setString:traceText(@"manual_copy") forType:NSPasteboardTypeString]; }
- (void)exportDiagnostics:(id)sender { (void)sender; NSSavePanel *p = NSSavePanel.savePanel; p.nameFieldStringValue = @"TapDrag-diagnostics.jsonl"; UTType *type = [UTType typeWithFilenameExtension:@"jsonl"]; if (type) p.allowedContentTypes = @[type]; if ([p runModal] == NSModalResponseOK && p.URL) [traceText(@"manual_export") writeToURL:p.URL atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
- (void)revealDiagnostics:(id)sender { (void)sender; NSURL *url = gAutomaticLogURL ? gAutomaticLogURL.URLByDeletingLastPathComponent : logDirectoryURL(); [[NSFileManager defaultManager] createDirectoryAtURL:url withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@(0700)} error:nil]; [[NSWorkspace sharedWorkspace] openURL:url]; }
- (void)clearDiagnostics:(id)sender { (void)sender; clearRecords(); [self updateStatus]; }
- (void)hideStatusItem:(id)sender { (void)sender; if (!self.statusItem) return; [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem]; self.statusItem = nil; self.enabledItem = nil; self.launchAtLoginItem = self.loginApprovalItem = self.automaticLoggingItem = nil; self.replacementStatus = self.diagnosticStatus = self.accessibilityItem = nil; }

- (void)menuWillOpen:(NSMenu *)menu {
    if (menu != self.statusItem.menu) return; [self refreshRuntimeConfiguration:nil];
    BOOL trusted = AXIsProcessTrusted(); self.accessibilityItem.title = trusted ? @"Accessibility Permission Granted" : @"Accessibility Permission Required"; self.accessibilityItem.state = trusted;
    self.enabledItem.state = atomic_load(&gEnabled); [self updateStatus];
}

- (void)resetInputState:(DiagnosticReason)reason {
    atomic_fetch_add(&gFeatureEpoch, 1);
    interruptChain(reason);
    os_unfair_lock_lock(&gStateLock);
    resetAllDevicesLocked();
    os_unfair_lock_unlock(&gStateLock);
}

- (void)refreshRuntimeConfiguration:(NSTimer *)timer {
    (void)timer;
    BOOL changed = refreshDraggingPreferences();
    if (changed) [self resetInputState:ReasonNativeDragging];
    BOOL tapStateChanged = NO;
    if (self.inputSessionActive && atomic_load(&gEnabled) && !activeEventTapsValid()) {
        BOOL wasSuspended = atomic_exchange(&gInputSuspended, true);
        if (!wasSuspended) [self resetInputState:ReasonEventTapDisabled];
        if (atomic_load(&gMultitouchReady) && [self accessStatus:NO] == AccessGranted &&
            [self installEventTap]) {
            atomic_store(&gInputSuspended, false);
            [self resetInputState:ReasonSystemResumed];
        }
        tapStateChanged = wasSuspended != atomic_load(&gInputSuspended);
    }
    if (changed || tapStateChanged) [self updateStatus];
}

- (void)inputWillSuspend:(NSNotification *)notification {
    (void)notification;
    self.inputSessionActive = NO;
    atomic_store(&gInputSuspended, true);
    [self resetInputState:ReasonSystemSuspended];
    [self stopMultitouchDevices];
    [self updateStatus];
}

- (void)inputDidResume:(NSNotification *)notification {
    (void)notification;
    self.inputSessionActive = YES;
    [self resetInputState:ReasonSystemResumed];
    BOOL devicesReady = [self rebuildMultitouchDevices];
    refreshDraggingPreferences();
    BOOL ready = !atomic_load(&gEnabled) ||
        (devicesReady && [self accessStatus:NO] == AccessGranted && [self installEventTap]);
    atomic_store(&gInputSuspended, !ready);
    if (!ready) recordDiagnostic(DiagnosticFailure, devicesReady
        ? ReasonEventTapDisabled : ReasonMultitouchUnavailable, 0,
        DragPhaseIdle, NULL, CGPointZero, 0, 0, 0, NO, NO);
    [self updateStatus];
}

- (void)stopMultitouchDevices {
    atomic_store(&gMultitouchReady, false);
    NSArray *devices = self.deviceList;
    if (devices && gDeviceStop) {
        for (id device in devices) gDeviceStop((__bridge MTDeviceRef)device);
    }
    os_unfair_lock_lock(&gStateLock);
    gDeviceCount = 0;
    memset(gDevices, 0, sizeof(gDevices));
    os_unfair_lock_unlock(&gStateLock);
    self.deviceList = nil;
}

- (BOOL)rebuildMultitouchDevices {
    [self stopMultitouchDevices];
    if (!gRegisterContactFrameCallback || !gDeviceStart) return NO;
    CFArrayRef discovered = gDeviceCreateList ? gDeviceCreateList() : NULL;
    CFMutableArrayRef active = CFArrayCreateMutable(kCFAllocatorDefault, 0,
                                                    &kCFTypeArrayCallBacks);
    if (!active) { if (discovered) CFRelease(discovered); return NO; }
    if (discovered) {
        for (CFIndex i = 0; i < CFArrayGetCount(discovered) &&
             CFArrayGetCount(active) < MaximumDevices; i++) {
            MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(discovered, i);
            if (device && shouldUseMultitouchDevice(device)) CFArrayAppendValue(active, device);
        }
        CFRelease(discovered);
    }
    if (CFArrayGetCount(active) == 0 && gDeviceCreateDefault) {
        MTDeviceRef device = gDeviceCreateDefault();
        if (device) {
            if (shouldUseMultitouchDevice(device)) CFArrayAppendValue(active, device);
            CFRelease(device);
        }
    }
    if (CFArrayGetCount(active) == 0) { CFRelease(active); return NO; }
    self.deviceList = CFBridgingRelease(active);
    os_unfair_lock_lock(&gStateLock);
    gDeviceCount = (int)MIN(self.deviceList.count, MaximumDevices);
    for (int i = 0; i < gDeviceCount; i++) {
        memset(&gDevices[i], 0, sizeof(DeviceState));
        gDevices[i].device = (__bridge MTDeviceRef)self.deviceList[i];
    }
    os_unfair_lock_unlock(&gStateLock);
    for (id value in self.deviceList) {
        MTDeviceRef device = (__bridge MTDeviceRef)value;
        gRegisterContactFrameCallback(device, contactFrameCallback);
        gDeviceStart(device, 0);
    }
    atomic_store(&gMultitouchReady, true);
    refreshDraggingPreferences();
    return YES;
}

- (void)setupMultitouchHotplug {
    if (self.hotplugPort) return;
    self.hotplugPort = IONotificationPortCreate(kIOMainPortDefault);
    if (!self.hotplugPort) return;
    CFRunLoopSourceRef source = IONotificationPortGetRunLoopSource(self.hotplugPort);
    if (source) CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFMutableDictionaryRef matching = IOServiceMatching("AppleMultitouchDevice");
    if (!matching) return;
    CFRetain(matching);
    kern_return_t added = IOServiceAddMatchingNotification(self.hotplugPort,
        kIOFirstMatchNotification, matching, multitouchTopologyChanged,
        (__bridge void *)self, &_addedTrackpads);
    kern_return_t removed = IOServiceAddMatchingNotification(self.hotplugPort,
        kIOTerminatedNotification, matching, multitouchTopologyChanged,
        (__bridge void *)self, &_removedTrackpads);
    if (added == KERN_SUCCESS) drainDeviceIterator(self.addedTrackpads);
    if (removed == KERN_SUCCESS) drainDeviceIterator(self.removedTrackpads);
}

- (void)teardownMultitouchHotplug {
    if (self.addedTrackpads) { IOObjectRelease(self.addedTrackpads); self.addedTrackpads = 0; }
    if (self.removedTrackpads) { IOObjectRelease(self.removedTrackpads); self.removedTrackpads = 0; }
    if (self.hotplugPort) { IONotificationPortDestroy(self.hotplugPort); self.hotplugPort = NULL; }
}

- (void)startMultitouch {
    self.multitouchHandle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/A/MultitouchSupport", RTLD_LAZY);
    if (!self.multitouchHandle) { self.statusItem.button.image = nil; self.statusItem.button.title = @"TD!"; return; }
    gDeviceCreateDefault = (MTDeviceCreateDefaultFunction)dlsym(self.multitouchHandle, "MTDeviceCreateDefault");
    gDeviceCreateList = (MTDeviceCreateListFunction)dlsym(self.multitouchHandle, "MTDeviceCreateList");
    gRegisterContactFrameCallback = (MTRegisterContactFrameCallbackFunction)dlsym(self.multitouchHandle, "MTRegisterContactFrameCallback");
    gDeviceStart = (MTDeviceStartFunction)dlsym(self.multitouchHandle, "MTDeviceStart");
    gDeviceStop = (MTDeviceStopFunction)dlsym(self.multitouchHandle, "MTDeviceStop");
    gDeviceGetSensorDimensions = (MTDeviceGetSensorDimensionsFunction)dlsym(self.multitouchHandle, "MTDeviceGetSensorDimensions");
    gDeviceIsBuiltIn = (MTDeviceIsBuiltInFunction)dlsym(self.multitouchHandle, "MTDeviceIsBuiltIn");
    if ((!gDeviceCreateList && !gDeviceCreateDefault) || !gRegisterContactFrameCallback ||
        !gDeviceStart || !gDeviceStop) {
        self.statusItem.button.image = nil; self.statusItem.button.title = @"TD!"; return;
    }
    BOOL ready = [self rebuildMultitouchDevices];
    if (!ready) recordDiagnostic(DiagnosticFailure, ReasonMultitouchUnavailable,
        0, DragPhaseIdle, NULL, CGPointZero, 0, 0, 0, NO, NO);
    atomic_store(&gInputSuspended, atomic_load(&gEnabled) && !ready);
    [self setupMultitouchHotplug];
    [self updateStatus];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification; [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        EnabledKey:@YES, AutomaticLoggingKey:@YES}];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    self.inputSessionActive = YES;
    atomic_store(&gAutomaticLoggingEnabled, [d boolForKey:AutomaticLoggingKey]);
    gNextEventNumber = SyntheticEventNumberMinimum + arc4random_uniform(SyntheticEventNumberMaximum); gSyntheticSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState); if (gSyntheticSource) CGEventSourceSetLocalEventsSuppressionInterval(gSyntheticSource, 0);
    refreshDraggingPreferences(); if ([d boolForKey:EnabledKey] && [self accessStatus:NO] == AccessGranted && [self installEventTap]) { atomic_store(&gEnabled, true); if (atomic_load(&gAutomaticLoggingEnabled)) startLogging(); }
    [self setupStatusItem]; [self startMultitouch];
    NSNotificationCenter *workspaceNotifications = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspaceNotifications addObserver:self selector:@selector(inputWillSuspend:)
                                   name:NSWorkspaceWillSleepNotification object:nil];
    [workspaceNotifications addObserver:self selector:@selector(inputDidResume:)
                                   name:NSWorkspaceDidWakeNotification object:nil];
    [workspaceNotifications addObserver:self selector:@selector(inputWillSuspend:)
                                   name:NSWorkspaceSessionDidResignActiveNotification object:nil];
    [workspaceNotifications addObserver:self selector:@selector(inputDidResume:)
                                   name:NSWorkspaceSessionDidBecomeActiveNotification object:nil];
    self.configurationTimer = [NSTimer timerWithTimeInterval:1.0 target:self
        selector:@selector(refreshRuntimeConfiguration:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.configurationTimer forMode:NSRunLoopCommonModes];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag { (void)sender; (void)flag; [self setupStatusItem]; return NO; }
- (void)applicationWillTerminate:(NSNotification *)notification { (void)notification; [self.configurationTimer invalidate]; self.configurationTimer = nil; [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self]; atomic_store(&gEnabled, false); atomic_fetch_add(&gFeatureEpoch, 1); interruptChain(ReasonDisabled); stopLogging(); [self removeEventTap]; [self teardownMultitouchHotplug]; [self stopMultitouchDevices]; if (gSyntheticSource) { CFRelease(gSyntheticSource); gSyntheticSource = NULL; } if (self.multitouchHandle) dlclose(self.multitouchHandle); self.multitouchHandle = NULL; }
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
