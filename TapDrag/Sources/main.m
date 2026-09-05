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
#import <time.h>
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
    DiagnosticTargetObserved,
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
    ReasonTargetObserverUnavailable,
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
    int32_t buttonNumber, mouseSubtype, hidLeftDown, sessionLeftDown;
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
};

static atomic_bool gEnabled = false;
static atomic_ullong gFeatureEpoch = 1;
static atomic_bool gInternalDraggingPresent = false;
static atomic_bool gInternalDraggingEnabled = true;
static atomic_bool gBluetoothDraggingPresent = false;
static atomic_bool gBluetoothDraggingEnabled = true;
static atomic_bool gAnyNativeDraggingEnabled = true;
static atomic_int gLastOutcome = ReleaseOutcomeWaiting;
static atomic_int gLastDurationMillis = 0;
static atomic_int gLastFrames = 0;

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
static CFMachPortRef gTargetObserverTap = NULL;
static CFRunLoopSourceRef gTargetObserverTapSource = NULL;
static atomic_int gObservedTargetPid = 0;
static atomic_int gWeChatPid = 0;
// Protected by gSyntheticLock; native first clicks must not precede a
// replacement drag in applications that recognize double-clicks themselves.
static CGEventRef gBufferedTapDown = NULL, gBufferedTapUp = NULL;
static MTDeviceRef gBufferedTapDevice = NULL;
static unsigned long long gBufferedTapToken = 0;
static int64_t gReplayedButtonNumber = 0;
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

static NSString *const EnabledKey = @"DoubleTapDragReleaseEnabled";
static const int64_t DoubleTapTag = 0x3346444E45574452LL;
static const long long MinimumSecondContactGapMillis = 30;
static const long long MaximumSecondTapGapMillis = 160;
static const long long SecondContactHoldMillis = 180;
static const double MaximumFirstTapDurationSeconds = 0.25;
static const float TapMoveThresholdMillimeters = 1.3f;
static const float FallbackNormalizedMoveThreshold = 0.010f;
static const long long FirstClickAllowanceMillis = 40;
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
        case DiagnosticTargetObserved: return @"observed_target_process";
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
        case ReasonTargetObserverUnavailable: return @"target_observer_unavailable";
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
        .hidLeftDown = event == NULL ? -1 : CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft),
        .sessionLeftDown = event == NULL ? -1 : CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft),
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
             @"hid_left_down": @(r.hidLeftDown), @"session_left_down": @(r.sessionLeftDown),
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
        @"wechat_first_tap_buffer": @YES,
        @"wechat_pid": @(atomic_load(&gWeChatPid)),
        @"downstream_observer_active": @(atomic_load(&gObserverActive)),
        @"target_observer_pid": @(atomic_load(&gObservedTargetPid)),
        @"diagnostic_schema": @3,
        @"system_double_click_ms": @(doubleClickIntervalMillis()),
        @"minimum_second_contact_gap_ms": @(MinimumSecondContactGapMillis),
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
             URLByAppendingPathComponent:@"TapDrag" isDirectory:YES]
            URLByAppendingPathComponent:@"Diagnostics" isDirectory:YES];
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
    return atomic_load(&gEnabled) && !nativeDraggingForDevice(device);
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
    s->nativeButtonDownDuringTouch = NO;
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
    if (isfinite(distanceMM)) {
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

static BOOL bufferWeChatTapButton(CGEventType type, CGEventRef event) {
    if (type != kCGEventLeftMouseDown && type != kCGEventLeftMouseUp) return NO;
    MTDeviceRef device = NULL;
    int wechatPid = atomic_load(&gWeChatPid);
    if (type == kCGEventLeftMouseDown && wechatPid > 0 &&
        CGEventGetIntegerValueField(event, kCGEventTargetUnixProcessID) == wechatPid &&
        CGEventGetIntegerValueField(event, kCGMouseEventSubtype) == NSEventSubtypeTouch) {
        os_unfair_lock_lock(&gStateLock);
        for (int i = 0; i < gDeviceCount; ++i) {
            DeviceState *s = &gDevices[i];
            if (replacementActive(s->device) && s->firstTapPending && s->touchingCount == 0) {
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
    os_unfair_lock_lock(&gSyntheticLock);
    flushBufferedTapLocked();
    gReplayedButtonNumber = 0;
    os_unfair_lock_unlock(&gSyntheticLock);
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

static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    (void)proxy; (void)context;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        ChainSnapshot s = chainSnapshot();
        recordDiagnostic(DiagnosticFailure, ReasonEventTapDisabled, s.generation, s.phase,
                         event, CGPointZero, 0, 0, 0, NO, NO);
        interruptChain(ReasonEventTapDisabled); if (gEventTap) CGEventTapEnable(gEventTap, true); return event;
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
        interruptChain(ReasonEventTapDisabled);
        if (gClickTap) CGEventTapEnable(gClickTap, true);
        return event;
    }
    if (!event || ownEvent(event) || !atomic_load(&gEnabled)) return event;
    return bufferWeChatTapButton(type, event) ? NULL : event;
}

static CGEventRef downstreamObserverCallback(CGEventTapProxy proxy, CGEventType type,
                                             CGEventRef event, void *context) {
    (void)proxy;
    BOOL targetObserver = context != NULL;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        recordDiagnostic(DiagnosticFailure, ReasonObserverDisabled, 0, DragPhaseIdle,
                         NULL, CGPointZero, 0, 0, 0, NO, NO);
        CFMachPortRef tap = targetObserver ? gTargetObserverTap : gObserverTap;
        if (tap) CGEventTapEnable(tap, true);
        if (targetObserver) {
            if (!tap || !CGEventTapIsEnabled(tap)) atomic_store(&gObservedTargetPid, 0);
        } else atomic_store(&gObserverActive, tap && CGEventTapIsEnabled(tap));
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
    recordDiagnostic(targetObserver ? DiagnosticTargetObserved : DiagnosticDownstreamObserved, ReasonNone,
        (current || (!ownEvent(event) && active)) ? s.generation : 0,
        s.phase, event, CGEventGetLocation(event),
        0, 0, 0, NO, NO);
    return event;
}

static void completeTouch(DeviceState *s, double timestamp, BOOL *candidate,
                          unsigned long long *generation, BOOL *movement) {
    int duration = touchDurationMillis(s, timestamp);
    *candidate = s->chainCandidate; *generation = s->chainGeneration; *movement = s->movementConfirmed;
    atomic_store(&gLastDurationMillis, duration); atomic_store(&gLastFrames, s->touchingFrames);
    DiagnosticReason reason = ReasonNone; DiagnosticKind kind = DiagnosticReset;
    if (s->touchInvalid) {
        s->firstTapPending = NO; atomic_store(&gLastOutcome, ReleaseOutcomeInvalid); reason = ReasonMultiFinger;
    } else if (!s->chainCandidate && s->nativeButtonDownDuringTouch) {
        s->firstTapPending = NO; s->firstTapCompletedTimestamp = 0;
        atomic_store(&gLastOutcome, ReleaseOutcomeWaiting);
        reason = ReasonNativeButtonDuringTouch;
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
            if (atomic_load(&gEnabled) && nativeDraggingForDevice(device))
                atomic_store(&gLastOutcome, ReleaseOutcomeNativeDraggingOn);
        }
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
        if (postUp(number, releaseLocation, generation) && finishRelease(generation))
            atomic_store(&gLastOutcome, ReleaseOutcomeReleased);
        else { resetChain(generation, ReasonStale); atomic_store(&gLastOutcome, ReleaseOutcomeInterrupted); }
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

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(strong) NSStatusItem *statusItem;
@property(strong) NSMenuItem *enabledItem;
@property(strong) NSMenuItem *replacementStatus, *runtimeStatus, *diagnosticStatus, *accessibilityItem;
@property(assign) CFArrayRef deviceList;
@property(assign) void *multitouchHandle;
@property(assign) BOOL trackingWeChat;
@end

@implementation AppDelegate

- (AccessStatus)accessStatus:(BOOL)prompt {
    BOOL post = CGPreflightPostEventAccess(), listen = CGPreflightListenEventAccess();
    if (prompt && !post) CGRequestPostEventAccess(); if (prompt && !listen) CGRequestListenEventAccess();
    return CGPreflightPostEventAccess() && CGPreflightListenEventAccess() ? AccessGranted : AccessRequired;
}

- (void)removeTargetObserver {
    atomic_store(&gObservedTargetPid, 0);
    if (gTargetObserverTapSource) { CFRunLoopRemoveSource(CFRunLoopGetMain(), gTargetObserverTapSource, kCFRunLoopCommonModes); CFRelease(gTargetObserverTapSource); gTargetObserverTapSource = NULL; }
    if (gTargetObserverTap) { CFMachPortInvalidate(gTargetObserverTap); CFRelease(gTargetObserverTap); gTargetObserverTap = NULL; }
}

- (void)installTargetObserverForPid:(pid_t)pid {
    gTargetObserverTap = CGEventTapCreateForPid(pid,
        kCGTailAppendEventTap, kCGEventTapOptionListenOnly, diagnosticMouseMask(),
        downstreamObserverCallback, (void *)(uintptr_t)1);
    if (gTargetObserverTap) {
        gTargetObserverTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gTargetObserverTap, 0);
        if (gTargetObserverTapSource) {
            CFRunLoopAddSource(CFRunLoopGetMain(), gTargetObserverTapSource, kCFRunLoopCommonModes);
            atomic_store(&gObservedTargetPid, pid);
        } else {
            CFMachPortInvalidate(gTargetObserverTap); CFRelease(gTargetObserverTap); gTargetObserverTap = NULL;
        }
    }
    if (!atomic_load(&gObservedTargetPid))
        recordDiagnostic(DiagnosticFailure, ReasonTargetObserverUnavailable, 0, DragPhaseIdle,
                         NULL, CGPointZero, 0, 0, 0, NO, NO);
}

- (void)updateWeChatPid:(pid_t)pid {
    if (atomic_load(&gWeChatPid) != pid) {
        // A buffered click belongs to the old process. Never replay it into
        // another window after that process exits; invalidate its timer too.
        os_unfair_lock_lock(&gSyntheticLock);
        discardBufferedTapLocked();
        gReplayedButtonNumber = 0;
        atomic_store(&gWeChatPid, pid);
        os_unfair_lock_unlock(&gSyntheticLock);
        [self removeTargetObserver];
    }
    // Diagnostic failure must not disable buffering. Activation retries a tap
    // that could not be installed while the new application was launching.
    if (pid > 0 && (!gTargetObserverTap || !CFMachPortIsValid(gTargetObserverTap))) {
        [self removeTargetObserver];
        [self installTargetObserverForPid:pid];
    }
}

- (void)weChatApplicationChanged:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self weChatApplicationChanged:notification]; });
        return;
    }
    if (!self.trackingWeChat) return;
    NSRunningApplication *app = notification.userInfo[NSWorkspaceApplicationKey];
    if (![app.bundleIdentifier isEqualToString:@"com.tencent.xinWeChat"]) return;
    if ([notification.name isEqualToString:NSWorkspaceDidTerminateApplicationNotification]) {
        // A delayed termination for the old PID must not clear its replacement.
        if (app.processIdentifier == atomic_load(&gWeChatPid)) [self updateWeChatPid:0];
    } else if (!app.terminated) {
        [self updateWeChatPid:app.processIdentifier];
    }
}

- (void)startTrackingWeChat {
    if (!self.trackingWeChat) {
        self.trackingWeChat = YES;
        NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
        for (NSString *name in @[NSWorkspaceDidLaunchApplicationNotification,
                                NSWorkspaceDidTerminateApplicationNotification,
                                NSWorkspaceDidActivateApplicationNotification]) {
            [center addObserver:self selector:@selector(weChatApplicationChanged:) name:name object:nil];
        }
    }
    pid_t pid = 0;
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.tencent.xinWeChat"]) {
        if (!app.terminated) { pid = app.processIdentifier; break; }
    }
    [self updateWeChatPid:pid];
}

- (void)stopTrackingWeChat {
    self.trackingWeChat = NO;
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [self updateWeChatPid:0];
    [self removeTargetObserver];
}

- (BOOL)installEventTap {
    if (gSyntheticSource == NULL) return NO;
    if (gEventTap) { CGEventTapEnable(gEventTap, true); return YES; }
    CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved) | CGEventMaskBit(kCGEventLeftMouseDown) |
        CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventLeftMouseUp);
    // Down, drag, up, and conflicting native buttons share this input stage.
    gEventTap = CGEventTapCreate(InputTapLocation, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                 mask, eventTapCallback, NULL);
    if (!gEventTap) return NO;
    gEventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gEventTap, 0);
    if (!gEventTapSource) { CFRelease(gEventTap); gEventTap = NULL; return NO; }
    CFRunLoopAddSource(CFRunLoopGetMain(), gEventTapSource, kCFRunLoopCommonModes);
    // Target PID at HID can still refer to the previous front application.
    // Buffer clicks only after WindowServer has annotated their actual target.
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
    [self startTrackingWeChat];
    return YES;
}

- (void)removeEventTap {
    [self stopTrackingWeChat];
    if (gClickTapSource) { CFRunLoopRemoveSource(CFRunLoopGetMain(), gClickTapSource, kCFRunLoopCommonModes); CFRelease(gClickTapSource); gClickTapSource = NULL; }
    if (gClickTap) { CFMachPortInvalidate(gClickTap); CFRelease(gClickTap); gClickTap = NULL; }
    atomic_store(&gObserverActive, false);
    if (gObserverTapSource) { CFRunLoopRemoveSource(CFRunLoopGetMain(), gObserverTapSource, kCFRunLoopCommonModes); CFRelease(gObserverTapSource); gObserverTapSource = NULL; }
    if (gObserverTap) { CFMachPortInvalidate(gObserverTap); CFRelease(gObserverTap); gObserverTap = NULL; }
    if (gEventTapSource) { CFRunLoopRemoveSource(CFRunLoopGetMain(), gEventTapSource, kCFRunLoopCommonModes); CFRelease(gEventTapSource); gEventTapSource = NULL; }
    if (gEventTap) { CFMachPortInvalidate(gEventTap); CFRelease(gEventTap); gEventTap = NULL; }
}

- (void)updateStatus {
    if (self.replacementStatus) {
        self.replacementStatus.title = !atomic_load(&gEnabled)
            ? @"TapDrag: Disabled"
            : ([self accessStatus:NO] != AccessGranted
                ? @"TapDrag: Accessibility / Input Monitoring Required"
                : (atomic_load(&gAnyNativeDraggingEnabled)
                    ? @"TapDrag: Inactive; turn off macOS trackpad dragging"
                    : @"TapDrag: Ready"));
    }
    if (self.runtimeStatus) {
        switch ((ReleaseOutcome)atomic_load(&gLastOutcome)) {
            case ReleaseOutcomeWaiting: self.runtimeStatus.title = @"Last gesture: waiting"; break;
            case ReleaseOutcomeFirstTap: self.runtimeStatus.title = @"Last gesture: first tap captured"; break;
            case ReleaseOutcomeSecondTapNoDrag: self.runtimeStatus.title = @"Last gesture: second tap had no drag"; break;
            case ReleaseOutcomeStarting: self.runtimeStatus.title = @"Last gesture: drag starting"; break;
            case ReleaseOutcomeOwned: self.runtimeStatus.title = @"Last gesture: drag active"; break;
            case ReleaseOutcomeReleased: self.runtimeStatus.title = [NSString stringWithFormat:@"Last gesture: released immediately (%d ms, %d frames)", atomic_load(&gLastDurationMillis), atomic_load(&gLastFrames)]; break;
            case ReleaseOutcomeInterrupted: self.runtimeStatus.title = @"Last gesture: interrupted safely"; break;
            case ReleaseOutcomeInvalid: self.runtimeStatus.title = @"Last gesture: multi-finger contact rejected"; break;
            case ReleaseOutcomeNativeDraggingOn: self.runtimeStatus.title = @"Last gesture: native dragging is still on"; break;
        }
    }
    if (self.diagnosticStatus) {
        os_unfair_lock_lock(&gDiagnosticLock); uint64_t count = MIN(gRecordSequence, (uint64_t)DiagnosticCapacity); os_unfair_lock_unlock(&gDiagnosticLock);
        self.diagnosticStatus.title = [NSString stringWithFormat:@"Diagnostics: %llu events%@", count,
            atomic_load(&gLoggingFaulted) ? @", write failed" : (atomic_load(&gLoggingActive) ? @", auto saved" : @"")];
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
    self.replacementStatus = [self item:@"TapDrag: checking" action:nil menu:menu]; self.replacementStatus.enabled = NO;
    self.runtimeStatus = [self item:@"Last gesture: waiting" action:nil menu:menu]; self.runtimeStatus.enabled = NO;
    NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:@"Diagnostics" action:nil keyEquivalent:@""];
    NSMenu *diagnostics = [[NSMenu alloc] initWithTitle:@"Diagnostics"];
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
    if (enable) startLogging(); else { atomic_fetch_add(&gFeatureEpoch, 1); interruptChain(ReasonDisabled); os_unfair_lock_lock(&gStateLock); resetAllDevicesLocked(); os_unfair_lock_unlock(&gStateLock); stopLogging(); }
    [[NSUserDefaults standardUserDefaults] setBool:enable forKey:EnabledKey]; self.enabledItem.state = enable;
    atomic_store(&gLastOutcome, atomic_load(&gAnyNativeDraggingEnabled) ? ReleaseOutcomeNativeDraggingOn : ReleaseOutcomeWaiting); [self updateStatus];
}

- (void)requestAccessibility:(id)sender { (void)sender; AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES}); }
- (void)copyDiagnostics:(id)sender { (void)sender; NSPasteboard *p = NSPasteboard.generalPasteboard; [p clearContents]; [p setString:traceText(@"manual_copy") forType:NSPasteboardTypeString]; }
- (void)exportDiagnostics:(id)sender { (void)sender; NSSavePanel *p = NSSavePanel.savePanel; p.nameFieldStringValue = @"TapDrag-diagnostics.jsonl"; UTType *type = [UTType typeWithFilenameExtension:@"jsonl"]; if (type) p.allowedContentTypes = @[type]; if ([p runModal] == NSModalResponseOK && p.URL) [traceText(@"manual_export") writeToURL:p.URL atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
- (void)revealDiagnostics:(id)sender { (void)sender; NSURL *url = gAutomaticLogURL ? gAutomaticLogURL.URLByDeletingLastPathComponent : logDirectoryURL(); [[NSFileManager defaultManager] createDirectoryAtURL:url withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@(0700)} error:nil]; [[NSWorkspace sharedWorkspace] openURL:url]; }
- (void)clearDiagnostics:(id)sender { (void)sender; clearRecords(); [self updateStatus]; }
- (void)hideStatusItem:(id)sender { (void)sender; if (!self.statusItem) return; [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem]; self.statusItem = nil; self.enabledItem = nil; self.replacementStatus = self.runtimeStatus = self.diagnosticStatus = self.accessibilityItem = nil; }

- (void)menuWillOpen:(NSMenu *)menu {
    if (menu != self.statusItem.menu) return; BOOL old = atomic_load(&gAnyNativeDraggingEnabled); refreshDraggingPreferences();
    if (old != atomic_load(&gAnyNativeDraggingEnabled)) { atomic_fetch_add(&gFeatureEpoch, 1); interruptChain(ReasonDisabled); os_unfair_lock_lock(&gStateLock); resetAllDevicesLocked(); os_unfair_lock_unlock(&gStateLock); }
    BOOL trusted = AXIsProcessTrusted(); self.accessibilityItem.title = trusted ? @"Accessibility Permission Granted" : @"Accessibility Permission Required"; self.accessibilityItem.state = trusted;
    self.enabledItem.state = atomic_load(&gEnabled); [self updateStatus];
}

- (void)startMultitouch {
    self.multitouchHandle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/A/MultitouchSupport", RTLD_LAZY);
    if (!self.multitouchHandle) { self.statusItem.button.image = nil; self.statusItem.button.title = @"TD!"; return; }
    MTDeviceCreateDefaultFunction createDefault = (MTDeviceCreateDefaultFunction)dlsym(self.multitouchHandle, "MTDeviceCreateDefault");
    MTDeviceCreateListFunction createList = (MTDeviceCreateListFunction)dlsym(self.multitouchHandle, "MTDeviceCreateList");
    MTRegisterContactFrameCallbackFunction registerCallback = (MTRegisterContactFrameCallbackFunction)dlsym(self.multitouchHandle, "MTRegisterContactFrameCallback");
    MTDeviceStartFunction startDevice = (MTDeviceStartFunction)dlsym(self.multitouchHandle, "MTDeviceStart");
    gDeviceIsBuiltIn = (MTDeviceIsBuiltInFunction)dlsym(self.multitouchHandle, "MTDeviceIsBuiltIn");
    if (!createDefault || !registerCallback || !startDevice) { self.statusItem.button.image = nil; self.statusItem.button.title = @"TD!"; return; }
    NSMutableArray<NSValue *> *devices = [NSMutableArray array];
    if (createList) { self.deviceList = createList(); if (self.deviceList) for (CFIndex i = 0; i < CFArrayGetCount(self.deviceList); i++) { MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(self.deviceList, i); if (d) [devices addObject:[NSValue valueWithPointer:d]]; } }
    if (devices.count == 0) { MTDeviceRef d = createDefault(); if (d) [devices addObject:[NSValue valueWithPointer:d]]; }
    os_unfair_lock_lock(&gStateLock); gDeviceCount = 0;
    for (NSValue *value in devices) { if (gDeviceCount == MaximumDevices) break; memset(&gDevices[gDeviceCount], 0, sizeof(DeviceState)); gDevices[gDeviceCount++].device = value.pointerValue; }
    os_unfair_lock_unlock(&gStateLock); refreshDraggingPreferences();
    for (NSValue *value in devices) { registerCallback(value.pointerValue, contactFrameCallback); startDevice(value.pointerValue, 0); }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification; [[NSUserDefaults standardUserDefaults] registerDefaults:@{EnabledKey:@YES}];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    gNextEventNumber = SyntheticEventNumberMinimum + arc4random_uniform(SyntheticEventNumberMaximum); gSyntheticSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState); if (gSyntheticSource) CGEventSourceSetLocalEventsSuppressionInterval(gSyntheticSource, 0);
    refreshDraggingPreferences(); if ([d boolForKey:EnabledKey] && [self accessStatus:NO] == AccessGranted && [self installEventTap]) { atomic_store(&gEnabled, true); startLogging(); }
    [self setupStatusItem]; [self startMultitouch];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag { (void)sender; (void)flag; [self setupStatusItem]; return NO; }
- (void)applicationWillTerminate:(NSNotification *)notification { (void)notification; atomic_store(&gEnabled, false); atomic_fetch_add(&gFeatureEpoch, 1); interruptChain(ReasonDisabled); stopLogging(); [self removeEventTap]; if (gSyntheticSource) { CFRelease(gSyntheticSource); gSyntheticSource = NULL; } self.deviceList = NULL; self.multitouchHandle = NULL; }
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
