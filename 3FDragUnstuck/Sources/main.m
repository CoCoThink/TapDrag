#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <stdint.h>
#import <stdatomic.h>

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef device, void *contacts, int contactCount, double timestamp, int frame);
typedef MTDeviceRef (*MTDeviceCreateDefaultFunction)(void);
typedef CFArrayRef (*MTDeviceCreateListFunction)(void);
typedef int (*MTRegisterContactFrameCallbackFunction)(MTDeviceRef device, MTContactCallbackFunction callback);
typedef int (*MTDeviceStartFunction)(MTDeviceRef device, int flags);

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

// MultitouchSupport is private. This prefix and layout are used only to read
// the contact state values that the existing double-tap workaround relies on.
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t pathIndex;
    uint32_t state;
    int32_t fingerID;
    int32_t handID;
    MTVector normalizedVector;
    float zTotal;
    int32_t field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absoluteVector;
    int32_t field14;
    int32_t field15;
    float zDensity;
} MTTouch;

typedef enum {
    MTTouchStateNotTracking = 0,
    MTTouchStateStartInRange = 1,
    MTTouchStateHoverInRange = 2,
    MTTouchStateMakeTouch = 3,
    MTTouchStateTouching = 4,
} MTTouchState;

typedef struct {
    MTDeviceRef device;
    int maxContacts;
    int contactCount;
    BOOL rawTouchMade;
    BOOL rawTouchInvalid;
    int rawTouchingFrames;
    double rawTouchStartedTimestamp;
    MTPoint rawTouchStartedPosition;
    BOOL rawTouchMoved;
    BOOL rawFirstTapPending;
    double rawFirstTapStartedTimestamp;
    BOOL rawChainCandidate;
} DeviceState;

typedef enum {
    DoubleTapDragAccessGranted,
    DoubleTapDragAccessNeedsEventControl,
    DoubleTapDragAccessEventTapUnavailable,
} DoubleTapDragAccessStatus;

typedef enum {
    DoubleTapReleaseOutcomeWaiting,
    DoubleTapReleaseOutcomeFirstTapCaptured,
    DoubleTapReleaseOutcomeSecondTouchNoDrag,
    DoubleTapReleaseOutcomeMultiFinger,
    DoubleTapReleaseOutcomeFirstTapExpired,
    DoubleTapReleaseOutcomeOverrideHeld,
    DoubleTapReleaseOutcomePosted,
    DoubleTapReleaseOutcomeChainDragStarted,
    DoubleTapReleaseOutcomeChainReleased,
    DoubleTapReleaseOutcomeChainInterrupted,
} DoubleTapReleaseOutcome;

typedef enum {
    RawTouchCompletionNone,
    RawTouchCompletionFirstTap,
    RawTouchCompletionSecondTouchNoDrag,
    RawTouchCompletionSecondTouchDrag,
    RawTouchCompletionInvalid,
} RawTouchCompletion;

typedef enum {
    DoubleTapChainIdle,
    DoubleTapChainAwaitingFirstTap,
    DoubleTapChainAwaitingSecondTap,
    DoubleTapChainSecondContact,
    DoubleTapChainStartingDrag,
    DoubleTapChainOwnedDrag,
    DoubleTapChainReleasing,
} DoubleTapChainPhase;

typedef enum {
    DoubleTapChainStartFailed,
    DoubleTapChainStartOwned,
    DoubleTapChainStartReleased,
} DoubleTapChainStartResult;

static atomic_bool gEnabled = true;
static atomic_bool gShiftOverrideEnabled = true;
static atomic_bool gDoubleTapDragReleaseEnabled = false;
static atomic_ullong gDoubleTapDragReleaseEpoch = 1;
static atomic_ullong gOverrideModifierMask = kCGEventFlagMaskAlternate;
static atomic_llong gLastThreeFingerPostMillis = 0;
static atomic_llong gLastDoubleTapPostMillis = 0;
static atomic_int gLastDoubleTapReleaseOutcome = DoubleTapReleaseOutcomeWaiting;
static atomic_int gLastDoubleTapTouchingFrames = 0;
static atomic_llong gLastDoubleTapTouchDurationMillis = 0;
static atomic_int gDoubleTapChainPhase = DoubleTapChainIdle;
static atomic_uintptr_t gDoubleTapChainDevice = 0;
static atomic_llong gDoubleTapChainDeadlineMillis = 0;
static atomic_bool gDoubleTapChainReleaseAfterStart = false;
static atomic_bool gRawDoubleTapSecondContactActive = false;
static atomic_bool gRawDoubleTapSecondContactSawDrag = false;
static os_unfair_lock gStateLock = OS_UNFAIR_LOCK_INIT;
static DeviceState gDeviceStates[16];
static int gDeviceStateCount = 0;
static CFMachPortRef gDoubleTapEventTap = NULL;
static CFRunLoopSourceRef gDoubleTapEventTapSource = NULL;
static NSString *const ShiftOverrideEnabledKey = @"ShiftOverrideEnabled";
static NSString *const OverrideModifierKey = @"OverrideModifier";
static NSString *const DoubleTapDragReleaseEnabledKey = @"DoubleTapDragReleaseEnabled";
static NSString *const OverrideModifierShift = @"Shift";
static NSString *const OverrideModifierControl = @"Control";
static NSString *const OverrideModifierOption = @"Option";
static NSString *const OverrideModifierFn = @"Fn";
static const int64_t SyntheticThreeFingerMouseUpUserData = 0x334644334655504DLL;
static const int64_t SyntheticDoubleTapMouseUpUserData = 0x334644445455504DLL;
static const int64_t SyntheticDoubleTapChainMouseUserData = 0x334644434841494ELL;
static const long long MinimumReleaseIntervalMillis = 80;
static const double MaximumTapDurationSeconds = 0.20;
static const float MinimumRawDragDistance = 0.0025f;
static const long long NativeGraceSafetyMarginMillis = 250;
static const long long MinimumNativeGraceWindowMillis = 1000;

static CGEventFlags modifierMaskForName(NSString *name) {
    if ([name isEqualToString:OverrideModifierShift]) {
        return kCGEventFlagMaskShift;
    }
    if ([name isEqualToString:OverrideModifierControl]) {
        return kCGEventFlagMaskControl;
    }
    if ([name isEqualToString:OverrideModifierFn]) {
        return kCGEventFlagMaskSecondaryFn;
    }
    return kCGEventFlagMaskAlternate;
}

static long long nowMillis(void) {
    return (long long)(CFAbsoluteTimeGetCurrent() * 1000.0);
}

static BOOL isOverrideModifierHeld(void) {
    return atomic_load(&gShiftOverrideEnabled) &&
           (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & atomic_load(&gOverrideModifierMask));
}

static BOOL claimReleaseSlot(atomic_llong *lastPostMillis) {
    long long now = nowMillis();
    long long last = atomic_load(lastPostMillis);

    for (;;) {
        if (now - last < MinimumReleaseIntervalMillis) {
            return NO;
        }
        if (atomic_compare_exchange_weak(lastPostMillis, &last, now)) {
            return YES;
        }
    }
}

static CGEventRef createTaggedLeftMouseEvent(CGEventType type, CGPoint location, int64_t userData, int clickState) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source == NULL) {
        return NULL;
    }

    CGEventRef event = CGEventCreateMouseEvent(source, type, location, kCGMouseButtonLeft);
    CFRelease(source);
    if (event == NULL) {
        return NULL;
    }

    CGEventSetIntegerValueField(event, kCGEventSourceUserData, userData);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, clickState);
    return event;
}

static void postTaggedLeftMouseEvent(CGEventType type, CGPoint location, int64_t userData, int clickState) {
    CGEventRef event = createTaggedLeftMouseEvent(type, location, userData, clickState);
    if (event == NULL) {
        return;
    }

    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static BOOL copyCurrentPointerLocation(CGPoint *location) {
    CGEventRef current = CGEventCreate(NULL);
    if (current == NULL) {
        return NO;
    }

    *location = CGEventGetLocation(current);
    CFRelease(current);
    return YES;
}

static void postLeftMouseUpAtLocation(CGPoint location, int64_t userData) {
    postTaggedLeftMouseEvent(kCGEventLeftMouseUp, location, userData, 1);
}

static void postLeftMouseUpAtCurrentPointerWithUserData(int64_t userData) {
    CGPoint location;
    if (copyCurrentPointerLocation(&location)) {
        postLeftMouseUpAtLocation(location, userData);
    }
}

static void postLeftMouseUpAtCurrentPointer(void) {
    postLeftMouseUpAtCurrentPointerWithUserData(SyntheticThreeFingerMouseUpUserData);
}

static DeviceState *deviceStateForDeviceLocked(MTDeviceRef device) {
    for (int i = 0; i < gDeviceStateCount; i++) {
        if (gDeviceStates[i].device == device) {
            return &gDeviceStates[i];
        }
    }
    return NULL;
}

static long long systemDoubleClickIntervalMillis(void) {
    return MAX(1LL, (long long)([NSEvent doubleClickInterval] * 1000.0));
}

static long long nativeGraceWindowMillis(void) {
    return MAX(MinimumNativeGraceWindowMillis,
               systemDoubleClickIntervalMillis() + NativeGraceSafetyMarginMillis);
}

static void resetDoubleTapChainState(void) {
    atomic_store(&gDoubleTapChainPhase, DoubleTapChainIdle);
    atomic_store(&gDoubleTapChainDevice, 0);
    atomic_store(&gDoubleTapChainDeadlineMillis, 0);
    atomic_store(&gDoubleTapChainReleaseAfterStart, false);
}

static void armDoubleTapChainForDevice(MTDeviceRef device) {
    atomic_store(&gDoubleTapChainDevice, (uintptr_t)device);
    atomic_store(&gDoubleTapChainReleaseAfterStart, false);
    atomic_store(&gDoubleTapChainDeadlineMillis, nowMillis() + nativeGraceWindowMillis());
    atomic_store(&gDoubleTapChainPhase, DoubleTapChainAwaitingFirstTap);
}

static BOOL doubleTapChainAwaitsFirstTapForDevice(MTDeviceRef device) {
    if (atomic_load(&gDoubleTapChainPhase) != DoubleTapChainAwaitingFirstTap ||
        atomic_load(&gDoubleTapChainDevice) != (uintptr_t)device) {
        return NO;
    }
    if (nowMillis() <= atomic_load(&gDoubleTapChainDeadlineMillis)) {
        return YES;
    }
    resetDoubleTapChainState();
    return NO;
}

static BOOL doubleTapChainAwaitsSecondTapForDevice(MTDeviceRef device) {
    if (atomic_load(&gDoubleTapChainPhase) != DoubleTapChainAwaitingSecondTap ||
        atomic_load(&gDoubleTapChainDevice) != (uintptr_t)device) {
        return NO;
    }
    if (nowMillis() <= atomic_load(&gDoubleTapChainDeadlineMillis)) {
        return YES;
    }
    resetDoubleTapChainState();
    return NO;
}

static BOOL isTaggedDoubleTapEvent(CGEventRef event) {
    int64_t userData = CGEventGetIntegerValueField(event, kCGEventSourceUserData);
    return userData == SyntheticDoubleTapMouseUpUserData ||
           userData == SyntheticDoubleTapChainMouseUserData;
}

static BOOL beginOwnedDoubleTapChainRelease(void) {
    int expectedPhase = DoubleTapChainOwnedDrag;
    return atomic_compare_exchange_strong(&gDoubleTapChainPhase,
                                          &expectedPhase,
                                          DoubleTapChainReleasing);
}

static void resetRawCurrentTouchLocked(DeviceState *state) {
    state->rawTouchMade = NO;
    state->rawTouchInvalid = NO;
    state->rawTouchingFrames = 0;
    state->rawTouchStartedTimestamp = 0;
    state->rawTouchStartedPosition = (MTPoint){0, 0};
    state->rawTouchMoved = NO;
    state->rawChainCandidate = NO;
}

static void resetRawDoubleTapStateLocked(DeviceState *state) {
    resetRawCurrentTouchLocked(state);
    state->rawFirstTapPending = NO;
    state->rawFirstTapStartedTimestamp = 0;
}

static BOOL isActualTouchState(uint32_t touchState) {
    return touchState == MTTouchStateMakeTouch || touchState == MTTouchStateTouching;
}

static BOOL isRawSecondTapWindowLocked(const DeviceState *state, double timestamp) {
    if (!state->rawTouchMade || !state->rawFirstTapPending ||
        timestamp < state->rawFirstTapStartedTimestamp) {
        return NO;
    }
    return timestamp - state->rawFirstTapStartedTimestamp <=
        (double)systemDoubleClickIntervalMillis() / 1000.0;
}

// Tap-to-drag is two real one-finger contact cycles. The first is brief; the
// second persists while the pointer is dragged and ends with the desired release.
static void observeRawTouchFrameLocked(DeviceState *state, const void *contacts, int contactCount, double timestamp) {
    if (contacts == NULL || contactCount <= 0) {
        return;
    }

    const MTTouch *touches = (const MTTouch *)contacts;
    const MTTouch *primaryTouch = NULL;
    int actualTouchCount = 0;
    for (int i = 0; i < contactCount; i++) {
        const MTTouch *touch = &touches[i];
        if (isActualTouchState(touch->state)) {
            actualTouchCount++;
            if (primaryTouch == NULL) {
                primaryTouch = touch;
            }
        }
    }

    if (actualTouchCount > 1) {
        state->rawTouchInvalid = YES;
        return;
    }
    if (primaryTouch == NULL) {
        return;
    }

    if (!state->rawTouchMade &&
        (primaryTouch->state == MTTouchStateMakeTouch || primaryTouch->state == MTTouchStateTouching)) {
        state->rawTouchMade = YES;
        state->rawTouchStartedTimestamp = timestamp;
        state->rawTouchStartedPosition = primaryTouch->normalizedVector.position;
        state->rawTouchMoved = NO;
    }
    if (state->rawTouchMade && primaryTouch->state == MTTouchStateTouching) {
        state->rawTouchingFrames++;
        float deltaX = primaryTouch->normalizedVector.position.x - state->rawTouchStartedPosition.x;
        float deltaY = primaryTouch->normalizedVector.position.y - state->rawTouchStartedPosition.y;
        if (deltaX * deltaX + deltaY * deltaY >= MinimumRawDragDistance * MinimumRawDragDistance) {
            state->rawTouchMoved = YES;
        }
    }
}

static BOOL startRawDoubleTapChainCandidateLocked(MTDeviceRef device, DeviceState *state, double timestamp) {
    if (state->rawChainCandidate || state->rawTouchInvalid || !state->rawTouchMade ||
        !state->rawFirstTapPending || !doubleTapChainAwaitsSecondTapForDevice(device)) {
        return NO;
    }

    double interval = (double)systemDoubleClickIntervalMillis() / 1000.0;
    if (timestamp < state->rawFirstTapStartedTimestamp ||
        timestamp - state->rawFirstTapStartedTimestamp > interval) {
        resetDoubleTapChainState();
        return NO;
    }

    if (isOverrideModifierHeld()) {
        resetDoubleTapChainState();
        return NO;
    }

    int expectedPhase = DoubleTapChainAwaitingSecondTap;
    if (!atomic_compare_exchange_strong(&gDoubleTapChainPhase, &expectedPhase, DoubleTapChainSecondContact)) {
        return NO;
    }
    state->rawChainCandidate = YES;
    return YES;
}

static RawTouchCompletion completeRawDoubleTapLocked(DeviceState *state,
                                                     double completedTimestamp,
                                                     BOOL sawNativeDrag) {
    int touchingFrames = state->rawTouchingFrames;
    atomic_store(&gLastDoubleTapTouchingFrames, touchingFrames);

    if (state->rawTouchInvalid) {
        atomic_store(&gLastDoubleTapReleaseOutcome, DoubleTapReleaseOutcomeMultiFinger);
        resetRawDoubleTapStateLocked(state);
        return RawTouchCompletionInvalid;
    }
    if (!state->rawTouchMade) {
        resetRawCurrentTouchLocked(state);
        return RawTouchCompletionNone;
    }

    double touchStartedTimestamp = state->rawTouchStartedTimestamp;
    long long touchDurationMillis = MAX(0LL, (long long)((completedTimestamp - touchStartedTimestamp) * 1000.0));
    atomic_store(&gLastDoubleTapTouchDurationMillis, touchDurationMillis);
    BOOL previousTapIsRecent = state->rawFirstTapPending &&
        touchStartedTimestamp >= state->rawFirstTapStartedTimestamp &&
        touchStartedTimestamp - state->rawFirstTapStartedTimestamp <= (double)systemDoubleClickIntervalMillis() / 1000.0;
    BOOL isShortTap = touchDurationMillis <= (long long)(MaximumTapDurationSeconds * 1000.0);

    if (previousTapIsRecent) {
        state->rawFirstTapPending = NO;
        state->rawFirstTapStartedTimestamp = 0;
        BOOL isDrag = state->rawTouchMoved || sawNativeDrag;
        atomic_store(&gLastDoubleTapReleaseOutcome,
                     isDrag ? DoubleTapReleaseOutcomeWaiting : DoubleTapReleaseOutcomeSecondTouchNoDrag);
        resetRawCurrentTouchLocked(state);
        return isDrag ? RawTouchCompletionSecondTouchDrag : RawTouchCompletionSecondTouchNoDrag;
    }

    if (state->rawFirstTapPending && !previousTapIsRecent) {
        atomic_store(&gLastDoubleTapReleaseOutcome, DoubleTapReleaseOutcomeFirstTapExpired);
    }

    if (isShortTap) {
        state->rawFirstTapPending = YES;
        state->rawFirstTapStartedTimestamp = touchStartedTimestamp;
        atomic_store(&gLastDoubleTapReleaseOutcome, DoubleTapReleaseOutcomeFirstTapCaptured);
        resetRawCurrentTouchLocked(state);
        return RawTouchCompletionFirstTap;
    } else {
        state->rawFirstTapPending = NO;
        state->rawFirstTapStartedTimestamp = 0;
    }

    resetRawCurrentTouchLocked(state);
    return RawTouchCompletionNone;
}

static void resetDeviceTouchStatesLocked(void) {
    for (int i = 0; i < gDeviceStateCount; i++) {
        gDeviceStates[i].maxContacts = 0;
        gDeviceStates[i].contactCount = 0;
        resetRawDoubleTapStateLocked(&gDeviceStates[i]);
    }
    atomic_store(&gRawDoubleTapSecondContactActive, false);
    atomic_store(&gRawDoubleTapSecondContactSawDrag, false);
}

static BOOL isDoubleTapDragReleaseEnabledForEpoch(unsigned long long epoch) {
    return atomic_load(&gEnabled) &&
           atomic_load(&gDoubleTapDragReleaseEnabled) &&
           atomic_load(&gDoubleTapDragReleaseEpoch) == epoch;
}

static DoubleTapChainStartResult startDoubleTapChainDragBeforeEvent(CGEventTapProxy proxy, CGEventRef event) {
    int expectedPhase = DoubleTapChainSecondContact;
    if (!atomic_compare_exchange_strong(&gDoubleTapChainPhase, &expectedPhase, DoubleTapChainStartingDrag)) {
        return DoubleTapChainStartFailed;
    }

    CGEventRef down = createTaggedLeftMouseEvent(kCGEventLeftMouseDown,
                                                  CGEventGetLocation(event),
                                                  SyntheticDoubleTapChainMouseUserData,
                                                  1);
    if (down == NULL) {
        atomic_store(&gDoubleTapChainPhase, DoubleTapChainSecondContact);
        return DoubleTapChainStartFailed;
    }
    CGEventTapPostEvent(proxy, down);
    CFRelease(down);

    atomic_store(&gDoubleTapChainPhase, DoubleTapChainOwnedDrag);
    atomic_store(&gLastDoubleTapReleaseOutcome, DoubleTapReleaseOutcomeChainDragStarted);

    if (atomic_exchange(&gDoubleTapChainReleaseAfterStart, false)) {
        atomic_store(&gDoubleTapChainPhase, DoubleTapChainReleasing);
        postLeftMouseUpAtCurrentPointerWithUserData(SyntheticDoubleTapChainMouseUserData);
        armDoubleTapChainForDevice((MTDeviceRef)atomic_load(&gDoubleTapChainDevice));
        atomic_store(&gLastDoubleTapReleaseOutcome, DoubleTapReleaseOutcomeChainReleased);
        return DoubleTapChainStartReleased;
    }
    return DoubleTapChainStartOwned;
}

static CGEventRef doubleTapEventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)refcon;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        int phase = atomic_load(&gDoubleTapChainPhase);
        if (phase == DoubleTapChainOwnedDrag || phase == DoubleTapChainStartingDrag ||
            phase == DoubleTapChainReleasing) {
            postLeftMouseUpAtCurrentPointerWithUserData(SyntheticDoubleTapChainMouseUserData);
        }
        resetDoubleTapChainState();
        atomic_store(&gLastDoubleTapReleaseOutcome, DoubleTapReleaseOutcomeChainInterrupted);
        if (gDoubleTapEventTap != NULL) {
            CGEventTapEnable(gDoubleTapEventTap, true);
        }
        return event;
    }

    if (event == NULL || !atomic_load(&gEnabled) || !atomic_load(&gDoubleTapDragReleaseEnabled) ||
        isTaggedDoubleTapEvent(event)) {
        return event;
    }

    if (type == kCGEventLeftMouseDragged && atomic_load(&gRawDoubleTapSecondContactActive)) {
        atomic_store(&gRawDoubleTapSecondContactSawDrag, true);
    }

    long long now = nowMillis();
    int phase = atomic_load(&gDoubleTapChainPhase);
    if ((phase == DoubleTapChainAwaitingFirstTap || phase == DoubleTapChainAwaitingSecondTap) &&
        now > atomic_load(&gDoubleTapChainDeadlineMillis)) {
        resetDoubleTapChainState();
        phase = DoubleTapChainIdle;
    }

    if (phase == DoubleTapChainReleasing) {
        return NULL;
    }

    if (phase != DoubleTapChainSecondContact && phase != DoubleTapChainStartingDrag && phase != DoubleTapChainOwnedDrag) {
        return event;
    }

    if (type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp) {
        return NULL;
    }

    if (phase == DoubleTapChainStartingDrag) {
        return NULL;
    }

    if (type != kCGEventMouseMoved && type != kCGEventLeftMouseDragged) {
        return event;
    }

    if (phase == DoubleTapChainSecondContact) {
        DoubleTapChainStartResult startResult = startDoubleTapChainDragBeforeEvent(proxy, event);
        if (startResult != DoubleTapChainStartOwned) {
            return NULL;
        }
        phase = atomic_load(&gDoubleTapChainPhase);
    }

    if (phase != DoubleTapChainOwnedDrag) {
        return NULL;
    }

    CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventSetType(event, kCGEventLeftMouseDragged);
    return event;
}

static void stopDoubleTapChainAndReleaseIfNeeded(void) {
    int phase = atomic_load(&gDoubleTapChainPhase);
    resetDoubleTapChainState();
    if (phase == DoubleTapChainOwnedDrag || phase == DoubleTapChainStartingDrag ||
        phase == DoubleTapChainReleasing) {
        postLeftMouseUpAtCurrentPointerWithUserData(SyntheticDoubleTapChainMouseUserData);
    }
}

static int contactFrameCallback(MTDeviceRef device, void *contacts, int contactCount, double timestamp, int frame) {
    (void)frame;

    BOOL shouldPostThreeFinger = NO;
    BOOL shouldPostDoubleTap = NO;
    BOOL shouldPostChainUp = NO;
    BOOL shouldRearmChainAfterUp = NO;
    BOOL shouldPostInterruptedChainUp = NO;
    unsigned long long doubleTapEnableEpoch = 0;
    unsigned long long chainEnableEpoch = 0;

    os_unfair_lock_lock(&gStateLock);
    DeviceState *state = deviceStateForDeviceLocked(device);

    if (state == NULL) {
        os_unfair_lock_unlock(&gStateLock);
        return 0;
    }

    if (!atomic_load(&gEnabled)) {
        int chainPhase = atomic_load(&gDoubleTapChainPhase);
        shouldPostInterruptedChainUp = chainPhase == DoubleTapChainOwnedDrag ||
            chainPhase == DoubleTapChainStartingDrag ||
            chainPhase == DoubleTapChainReleasing;
        resetDoubleTapChainState();
        state->maxContacts = 0;
        state->contactCount = 0;
        resetRawDoubleTapStateLocked(state);
        atomic_store(&gRawDoubleTapSecondContactActive, false);
        atomic_store(&gRawDoubleTapSecondContactSawDrag, false);
        os_unfair_lock_unlock(&gStateLock);
        if (shouldPostInterruptedChainUp) {
            postLeftMouseUpAtCurrentPointerWithUserData(SyntheticDoubleTapChainMouseUserData);
        }
        return 0;
    }

    if (contactCount > 0) {
        if (state->contactCount == 0) {
            state->maxContacts = 0;
            resetRawCurrentTouchLocked(state);
            atomic_store(&gRawDoubleTapSecondContactActive, false);
            atomic_store(&gRawDoubleTapSecondContactSawDrag, false);
        }
        state->contactCount = contactCount;
        state->maxContacts = MAX(state->maxContacts, contactCount);
        if (atomic_load(&gDoubleTapDragReleaseEnabled)) {
            observeRawTouchFrameLocked(state, contacts, contactCount, timestamp);
            if (isRawSecondTapWindowLocked(state, timestamp)) {
                atomic_store(&gRawDoubleTapSecondContactActive, true);
            }
            startRawDoubleTapChainCandidateLocked(device, state, timestamp);
            if (state->rawTouchInvalid && state->rawChainCandidate) {
                int chainPhase = atomic_load(&gDoubleTapChainPhase);
                if (chainPhase == DoubleTapChainOwnedDrag) {
                    shouldPostInterruptedChainUp = beginOwnedDoubleTapChainRelease();
                } else if (chainPhase == DoubleTapChainStartingDrag) {
                    atomic_store(&gDoubleTapChainReleaseAfterStart, true);
                } else {
                    resetDoubleTapChainState();
                }
                state->rawChainCandidate = NO;
                atomic_store(&gLastDoubleTapReleaseOutcome, DoubleTapReleaseOutcomeChainInterrupted);
            }
        } else {
            resetRawDoubleTapStateLocked(state);
        }
        os_unfair_lock_unlock(&gStateLock);
        if (shouldPostInterruptedChainUp) {
            postLeftMouseUpAtCurrentPointerWithUserData(SyntheticDoubleTapChainMouseUserData);
            resetDoubleTapChainState();
        }
        return 0;
    }

    if (state->contactCount == 0) {
        os_unfair_lock_unlock(&gStateLock);
        return 0;
    }

    int completedMaxContacts = state->maxContacts;
    shouldPostThreeFinger = completedMaxContacts == 3;
    if (atomic_load(&gDoubleTapDragReleaseEnabled)) {
        BOOL wasChainCandidate = state->rawChainCandidate;
        BOOL sawNativeDrag = atomic_exchange(&gRawDoubleTapSecondContactSawDrag, false);
        atomic_store(&gRawDoubleTapSecondContactActive, false);
        RawTouchCompletion completion = completeRawDoubleTapLocked(state, timestamp, sawNativeDrag);

        if (wasChainCandidate) {
            int chainPhase = atomic_load(&gDoubleTapChainPhase);
            if (completion == RawTouchCompletionInvalid) {
                if (chainPhase == DoubleTapChainOwnedDrag) {
                    if (beginOwnedDoubleTapChainRelease()) {
                        shouldPostChainUp = YES;
                        chainEnableEpoch = atomic_load(&gDoubleTapDragReleaseEpoch);
                    }
                } else if (chainPhase == DoubleTapChainStartingDrag) {
                    atomic_store(&gDoubleTapChainReleaseAfterStart, true);
                } else {
                    resetDoubleTapChainState();
                }
                atomic_store(&gLastDoubleTapReleaseOutcome, DoubleTapReleaseOutcomeChainInterrupted);
            } else if (chainPhase == DoubleTapChainOwnedDrag) {
                if (beginOwnedDoubleTapChainRelease()) {
                    shouldPostChainUp = YES;
                    shouldRearmChainAfterUp = YES;
                    chainEnableEpoch = atomic_load(&gDoubleTapDragReleaseEpoch);
                }
            } else if (chainPhase == DoubleTapChainStartingDrag) {
                atomic_store(&gDoubleTapChainReleaseAfterStart, true);
            } else if (chainPhase == DoubleTapChainSecondContact) {
                state->rawFirstTapPending = NO;
                state->rawFirstTapStartedTimestamp = 0;
                resetDoubleTapChainState();
            } else {
                resetDoubleTapChainState();
            }
        } else if (completion == RawTouchCompletionFirstTap &&
                   doubleTapChainAwaitsFirstTapForDevice(device)) {
            int expectedPhase = DoubleTapChainAwaitingFirstTap;
            if (atomic_compare_exchange_strong(&gDoubleTapChainPhase,
                                               &expectedPhase,
                                               DoubleTapChainAwaitingSecondTap)) {
                atomic_store(&gDoubleTapChainDeadlineMillis,
                             nowMillis() + systemDoubleClickIntervalMillis());
            }
        } else if (completion == RawTouchCompletionSecondTouchDrag) {
            if (isOverrideModifierHeld()) {
                atomic_store(&gLastDoubleTapReleaseOutcome, DoubleTapReleaseOutcomeOverrideHeld);
            } else if (claimReleaseSlot(&gLastDoubleTapPostMillis)) {
                shouldPostDoubleTap = YES;
                doubleTapEnableEpoch = atomic_load(&gDoubleTapDragReleaseEpoch);
            }
        }
    }
    state->maxContacts = 0;
    state->contactCount = 0;
    os_unfair_lock_unlock(&gStateLock);

    if (shouldPostThreeFinger && !isOverrideModifierHeld() &&
        claimReleaseSlot(&gLastThreeFingerPostMillis)) {
        postLeftMouseUpAtCurrentPointer();
    }

    if (shouldPostChainUp) {
        postLeftMouseUpAtCurrentPointerWithUserData(SyntheticDoubleTapChainMouseUserData);
        if (shouldRearmChainAfterUp && isDoubleTapDragReleaseEnabledForEpoch(chainEnableEpoch)) {
            armDoubleTapChainForDevice(device);
        } else {
            resetDoubleTapChainState();
        }
        atomic_store(&gLastDoubleTapReleaseOutcome, DoubleTapReleaseOutcomeChainReleased);
    }

    if (shouldPostDoubleTap && isDoubleTapDragReleaseEnabledForEpoch(doubleTapEnableEpoch)) {
        postLeftMouseUpAtCurrentPointerWithUserData(SyntheticDoubleTapMouseUpUserData);
        armDoubleTapChainForDevice(device);
        atomic_store(&gLastDoubleTapReleaseOutcome, DoubleTapReleaseOutcomePosted);
    }
    return 0;
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenuItem *enabledItem;
@property(nonatomic, strong) NSMenuItem *shiftOverrideItem;
@property(nonatomic, strong) NSMenuItem *doubleTapDragReleaseItem;
@property(nonatomic, strong) NSMenuItem *overrideModifierItem;
@property(nonatomic, strong) NSMenuItem *shiftModifierItem;
@property(nonatomic, strong) NSMenuItem *controlModifierItem;
@property(nonatomic, strong) NSMenuItem *optionModifierItem;
@property(nonatomic, strong) NSMenuItem *fnModifierItem;
@property(nonatomic, strong) NSMenuItem *accessibilityItem;
@property(nonatomic, strong) NSMenuItem *doubleTapDragStatusItem;
@property(nonatomic, strong) NSMenuItem *doubleTapReleaseRuntimeItem;
@property(nonatomic, strong) NSMenuItem *hideMenuBarIconItem;
@property(nonatomic, assign) CFArrayRef deviceList;
@property(nonatomic, assign) void *multitouchHandle;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        ShiftOverrideEnabledKey: @YES,
        OverrideModifierKey: OverrideModifierOption,
        DoubleTapDragReleaseEnabledKey: @NO
    }];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    atomic_store(&gShiftOverrideEnabled, [defaults boolForKey:ShiftOverrideEnabledKey]);
    atomic_store(&gOverrideModifierMask, modifierMaskForName([defaults stringForKey:OverrideModifierKey]));
    atomic_store(&gDoubleTapDragReleaseEnabled, NO);
    if ([defaults boolForKey:DoubleTapDragReleaseEnabledKey] &&
        [self doubleTapDragAccessStatusRequestingIfNeeded:NO] == DoubleTapDragAccessGranted &&
        [self installDoubleTapEventTap]) {
        atomic_fetch_add(&gDoubleTapDragReleaseEpoch, 1);
        atomic_store(&gDoubleTapDragReleaseEnabled, YES);
    }
    [self setupStatusItem];
    [self requestAccessibilityIfNeeded:NO];
    [self updateDoubleTapDragAccessStatus];
    [self startMultitouchCallback];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender;
    (void)flag;
    [self showMenuBarIcon];
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    int chainPhase = atomic_load(&gDoubleTapChainPhase);
    atomic_store(&gDoubleTapDragReleaseEnabled, NO);
    atomic_fetch_add(&gDoubleTapDragReleaseEpoch, 1);
    resetDoubleTapChainState();
    os_unfair_lock_lock(&gStateLock);
    resetDeviceTouchStatesLocked();
    os_unfair_lock_unlock(&gStateLock);
    if (chainPhase == DoubleTapChainOwnedDrag || chainPhase == DoubleTapChainStartingDrag ||
        chainPhase == DoubleTapChainReleasing) {
        postLeftMouseUpAtCurrentPointerWithUserData(SyntheticDoubleTapChainMouseUserData);
    }
    [self removeDoubleTapEventTap];
    // MultitouchSupport owns callbacks without a stable public unregister API.
    // Let process teardown reclaim these private-framework resources.
    self.deviceList = NULL;
    self.multitouchHandle = NULL;
}

- (void)setupStatusItem {
    if (self.statusItem != nil) {
        return;
    }

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"3F+";
    self.statusItem.button.toolTip = @"3FDragUnstuck Enhanced";

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.delegate = self;

    self.enabledItem = [[NSMenuItem alloc] initWithTitle:@"Enabled" action:@selector(toggleEnabled:) keyEquivalent:@""];
    self.enabledItem.target = self;
    self.enabledItem.state = NSControlStateValueOn;
    [menu addItem:self.enabledItem];

    self.shiftOverrideItem = [[NSMenuItem alloc] initWithTitle:@"Override Enabled" action:@selector(toggleShiftOverride:) keyEquivalent:@""];
    self.shiftOverrideItem.target = self;
    self.shiftOverrideItem.state = atomic_load(&gShiftOverrideEnabled) ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:self.shiftOverrideItem];

    self.doubleTapDragReleaseItem = [[NSMenuItem alloc] initWithTitle:@"Fast Release for Double-Tap Drag (Experimental)" action:@selector(toggleDoubleTapDragRelease:) keyEquivalent:@""];
    self.doubleTapDragReleaseItem.target = self;
    [self updateDoubleTapDragReleaseMenuState];
    [menu addItem:self.doubleTapDragReleaseItem];

    self.doubleTapDragStatusItem = [[NSMenuItem alloc] initWithTitle:@"Double-Tap Drag: Checking Permissions" action:nil keyEquivalent:@""];
    self.doubleTapDragStatusItem.enabled = NO;
    [self updateDoubleTapDragAccessStatus];
    [menu addItem:self.doubleTapDragStatusItem];

    self.doubleTapReleaseRuntimeItem = [[NSMenuItem alloc] initWithTitle:@"Double-Tap last: waiting for first tap" action:nil keyEquivalent:@""];
    self.doubleTapReleaseRuntimeItem.enabled = NO;
    [self updateDoubleTapReleaseRuntimeStatus];
    [menu addItem:self.doubleTapReleaseRuntimeItem];

    self.overrideModifierItem = [[NSMenuItem alloc] initWithTitle:@"Override Modifier" action:nil keyEquivalent:@""];
    NSMenu *modifierMenu = [[NSMenu alloc] initWithTitle:@"Override Modifier"];
    self.shiftModifierItem = [[NSMenuItem alloc] initWithTitle:@"Shift" action:@selector(selectOverrideModifier:) keyEquivalent:@""];
    self.controlModifierItem = [[NSMenuItem alloc] initWithTitle:@"Control" action:@selector(selectOverrideModifier:) keyEquivalent:@""];
    self.optionModifierItem = [[NSMenuItem alloc] initWithTitle:@"Option" action:@selector(selectOverrideModifier:) keyEquivalent:@""];
    self.fnModifierItem = [[NSMenuItem alloc] initWithTitle:@"Fn (Globe)" action:@selector(selectOverrideModifier:) keyEquivalent:@""];
    self.shiftModifierItem.target = self;
    self.controlModifierItem.target = self;
    self.optionModifierItem.target = self;
    self.fnModifierItem.target = self;
    self.shiftModifierItem.representedObject = OverrideModifierShift;
    self.controlModifierItem.representedObject = OverrideModifierControl;
    self.optionModifierItem.representedObject = OverrideModifierOption;
    self.fnModifierItem.representedObject = OverrideModifierFn;
    [modifierMenu addItem:self.shiftModifierItem];
    [modifierMenu addItem:self.controlModifierItem];
    [modifierMenu addItem:self.optionModifierItem];
    [modifierMenu addItem:self.fnModifierItem];
    self.overrideModifierItem.submenu = modifierMenu;
    [self updateOverrideModifierMenuState];
    [menu addItem:self.overrideModifierItem];

    self.accessibilityItem = [[NSMenuItem alloc] initWithTitle:@"Accessibility Permission Required" action:@selector(requestAccessibilityPermission:) keyEquivalent:@""];
    self.accessibilityItem.target = self;
    [menu addItem:self.accessibilityItem];

    self.hideMenuBarIconItem = [[NSMenuItem alloc] initWithTitle:@"Hide Menu Bar Icon" action:@selector(hideMenuBarIcon:) keyEquivalent:@""];
    self.hideMenuBarIconItem.target = self;
    [menu addItem:self.hideMenuBarIconItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    [menu addItem:quit];

    self.statusItem.menu = menu;
}

- (void)showMenuBarIcon {
    [self setupStatusItem];
    [self requestAccessibilityIfNeeded:NO];
}

- (void)hideMenuBarIcon:(id)sender {
    (void)sender;
    if (self.statusItem == nil) {
        return;
    }

    [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem];
    self.statusItem = nil;
    self.enabledItem = nil;
    self.shiftOverrideItem = nil;
    self.doubleTapDragReleaseItem = nil;
    self.overrideModifierItem = nil;
    self.shiftModifierItem = nil;
    self.controlModifierItem = nil;
    self.optionModifierItem = nil;
    self.fnModifierItem = nil;
    self.accessibilityItem = nil;
    self.doubleTapDragStatusItem = nil;
    self.doubleTapReleaseRuntimeItem = nil;
    self.hideMenuBarIconItem = nil;
}

- (void)toggleEnabled:(id)sender {
    (void)sender;
    BOOL enabled = !atomic_load(&gEnabled);
    atomic_store(&gEnabled, enabled);
    if (!enabled) {
        atomic_fetch_add(&gDoubleTapDragReleaseEpoch, 1);
        stopDoubleTapChainAndReleaseIfNeeded();
        os_unfair_lock_lock(&gStateLock);
        resetDeviceTouchStatesLocked();
        os_unfair_lock_unlock(&gStateLock);
        atomic_store(&gLastDoubleTapReleaseOutcome, DoubleTapReleaseOutcomeWaiting);
        atomic_store(&gLastDoubleTapTouchingFrames, 0);
        atomic_store(&gLastDoubleTapTouchDurationMillis, 0);
    }
    self.enabledItem.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)toggleShiftOverride:(id)sender {
    (void)sender;
    BOOL enabled = !atomic_load(&gShiftOverrideEnabled);
    atomic_store(&gShiftOverrideEnabled, enabled);
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:ShiftOverrideEnabledKey];
    self.shiftOverrideItem.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)toggleDoubleTapDragRelease:(id)sender {
    (void)sender;
    BOOL shouldEnable = !atomic_load(&gDoubleTapDragReleaseEnabled);
    if (shouldEnable) {
        DoubleTapDragAccessStatus accessStatus = [self doubleTapDragAccessStatusRequestingIfNeeded:YES];
        if (accessStatus == DoubleTapDragAccessGranted && ![self installDoubleTapEventTap]) {
            accessStatus = DoubleTapDragAccessEventTapUnavailable;
        }
        if (accessStatus != DoubleTapDragAccessGranted) {
            atomic_store(&gDoubleTapDragReleaseEnabled, NO);
            [self updateDoubleTapDragReleaseMenuState];
            [self updateDoubleTapDragAccessStatus];
            [self presentDoubleTapDragAccessAlertForStatus:accessStatus];
            return;
        }
        atomic_fetch_add(&gDoubleTapDragReleaseEpoch, 1);
        atomic_store(&gDoubleTapDragReleaseEnabled, YES);
    } else {
        atomic_store(&gDoubleTapDragReleaseEnabled, NO);
        atomic_fetch_add(&gDoubleTapDragReleaseEpoch, 1);
        stopDoubleTapChainAndReleaseIfNeeded();
        os_unfair_lock_lock(&gStateLock);
        resetDeviceTouchStatesLocked();
        os_unfair_lock_unlock(&gStateLock);
    }

    atomic_store(&gLastDoubleTapReleaseOutcome, DoubleTapReleaseOutcomeWaiting);
    atomic_store(&gLastDoubleTapTouchingFrames, 0);
    atomic_store(&gLastDoubleTapTouchDurationMillis, 0);
    [[NSUserDefaults standardUserDefaults] setBool:shouldEnable forKey:DoubleTapDragReleaseEnabledKey];
    [self updateDoubleTapDragReleaseMenuState];
    [self updateDoubleTapDragAccessStatus];
    [self updateDoubleTapReleaseRuntimeStatus];
}

- (void)selectOverrideModifier:(id)sender {
    NSString *name = [sender representedObject];
    if (name == nil) {
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:name forKey:OverrideModifierKey];
    atomic_store(&gOverrideModifierMask, modifierMaskForName(name));
    [self updateOverrideModifierMenuState];
}

- (void)updateOverrideModifierMenuState {
    NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey:OverrideModifierKey];
    self.shiftModifierItem.state = [name isEqualToString:OverrideModifierShift] ? NSControlStateValueOn : NSControlStateValueOff;
    self.controlModifierItem.state = [name isEqualToString:OverrideModifierControl] ? NSControlStateValueOn : NSControlStateValueOff;
    self.optionModifierItem.state = [name isEqualToString:OverrideModifierOption] ? NSControlStateValueOn : NSControlStateValueOff;
    self.fnModifierItem.state = [name isEqualToString:OverrideModifierFn] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)updateDoubleTapDragReleaseMenuState {
    self.doubleTapDragReleaseItem.state = atomic_load(&gDoubleTapDragReleaseEnabled) ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    [self requestAccessibilityIfNeeded:NO];
    [self updateDoubleTapDragAccessStatus];
    [self updateDoubleTapDragReleaseMenuState];
    [self updateDoubleTapReleaseRuntimeStatus];
}

- (void)requestAccessibilityPermission:(id)sender {
    (void)sender;
    if (![self requestAccessibilityIfNeeded:YES]) {
        NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

- (BOOL)requestAccessibilityIfNeeded:(BOOL)prompt {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @(prompt)};
    BOOL trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    if (self.accessibilityItem != nil) {
        self.accessibilityItem.title = trusted ? @"Accessibility Permission Granted" : @"Accessibility Permission Required";
        self.accessibilityItem.state = trusted ? NSControlStateValueOn : NSControlStateValueOff;
    }
    return trusted;
}

- (BOOL)installDoubleTapEventTap {
    if (gDoubleTapEventTap != NULL) {
        if (!CGEventTapIsEnabled(gDoubleTapEventTap)) {
            CGEventTapEnable(gDoubleTapEventTap, true);
        }
        return YES;
    }

    CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved) |
        CGEventMaskBit(kCGEventLeftMouseDown) |
        CGEventMaskBit(kCGEventLeftMouseDragged) |
        CGEventMaskBit(kCGEventLeftMouseUp);
    CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap,
                                         kCGHeadInsertEventTap,
                                         kCGEventTapOptionDefault,
                                         mask,
                                         doubleTapEventTapCallback,
                                         NULL);
    if (tap == NULL) {
        return NO;
    }

    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    if (source == NULL) {
        CFRelease(tap);
        return NO;
    }

    gDoubleTapEventTap = tap;
    gDoubleTapEventTapSource = source;
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    return YES;
}

- (void)removeDoubleTapEventTap {
    CFMachPortRef tap = gDoubleTapEventTap;
    CFRunLoopSourceRef source = gDoubleTapEventTapSource;
    gDoubleTapEventTap = NULL;
    gDoubleTapEventTapSource = NULL;
    if (source != NULL) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
        CFRelease(source);
    }
    if (tap != NULL) {
        CFMachPortInvalidate(tap);
        CFRelease(tap);
    }
}

- (DoubleTapDragAccessStatus)doubleTapDragAccessStatusRequestingIfNeeded:(BOOL)prompt {
    BOOL canPost = CGPreflightPostEventAccess();
    BOOL canListen = CGPreflightListenEventAccess();
    if (prompt && !canPost) {
        CGRequestPostEventAccess();
    }
    if (prompt && !canListen) {
        CGRequestListenEventAccess();
    }
    canPost = CGPreflightPostEventAccess();
    canListen = CGPreflightListenEventAccess();
    return canPost && canListen ? DoubleTapDragAccessGranted : DoubleTapDragAccessNeedsEventControl;
}

- (NSString *)doubleTapDragAccessStatusTitle:(DoubleTapDragAccessStatus)status {
    switch (status) {
        case DoubleTapDragAccessGranted:
            return @"Double-Tap Drag: Event Control Permission Granted";
        case DoubleTapDragAccessNeedsEventControl:
            return @"Double-Tap Drag: Accessibility / Input Monitoring Required";
        case DoubleTapDragAccessEventTapUnavailable:
            return @"Double-Tap Drag: Event Filter Unavailable";
    }
    return @"Double-Tap Drag: Permission Status Unknown";
}

- (void)updateDoubleTapDragAccessStatus {
    if (self.doubleTapDragStatusItem == nil) {
        return;
    }

    DoubleTapDragAccessStatus status = [self doubleTapDragAccessStatusRequestingIfNeeded:NO];
    self.doubleTapDragStatusItem.title = [self doubleTapDragAccessStatusTitle:status];
}

- (void)openAccessibilityPrivacySettings {
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)presentDoubleTapDragAccessAlertForStatus:(DoubleTapDragAccessStatus)status {
    NSAlert *alert = [[NSAlert alloc] init];
    if (status == DoubleTapDragAccessEventTapUnavailable) {
        alert.messageText = @"Double-Tap Drag Event Filter Was Not Enabled";
        alert.informativeText = @"macOS allowed event access but did not create the session event filter required for consecutive double-tap drags. Quit and reopen this exact build, then verify Accessibility and Input Monitoring access before trying again.";
    } else {
        alert.messageText = @"Double-Tap Drag Fast Release Was Not Enabled";
        alert.informativeText = @"This build needs permission to synthesize and monitor mouse events for the consecutive-drag workaround. Grant Accessibility access to this exact app; if macOS separately requests Input Monitoring, grant that as well. Rebuilding an ad-hoc-signed app can require granting permission again.";
    }
    [alert addButtonWithTitle:@"Open Accessibility Settings"];
    [alert addButtonWithTitle:@"Cancel"];

    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        [self openAccessibilityPrivacySettings];
    }
}

- (NSString *)doubleTapReleaseRuntimeStatusTitle {
    int outcome = atomic_load(&gLastDoubleTapReleaseOutcome);
    int touchingFrames = atomic_load(&gLastDoubleTapTouchingFrames);
    long long durationMillis = atomic_load(&gLastDoubleTapTouchDurationMillis);
    switch (outcome) {
        case DoubleTapReleaseOutcomeFirstTapCaptured:
            return @"Double-Tap last: first tap captured";
        case DoubleTapReleaseOutcomeSecondTouchNoDrag:
            return [NSString stringWithFormat:@"Double-Tap last: second touch ended without drag (%lld ms, %d frames)", durationMillis, touchingFrames];
        case DoubleTapReleaseOutcomeMultiFinger:
            return @"Double-Tap last: ignored multi-finger touch";
        case DoubleTapReleaseOutcomeFirstTapExpired:
            return @"Double-Tap last: first tap expired";
        case DoubleTapReleaseOutcomeOverrideHeld:
            return @"Double-Tap last: native release kept (override held)";
        case DoubleTapReleaseOutcomePosted:
            return [NSString stringWithFormat:@"Double-Tap last: immediate release posted; next drag armed (%lld ms, %d frames)", durationMillis, touchingFrames];
        case DoubleTapReleaseOutcomeChainDragStarted:
            return @"Double-Tap last: consecutive drag active";
        case DoubleTapReleaseOutcomeChainReleased:
            return @"Double-Tap last: consecutive drag released";
        case DoubleTapReleaseOutcomeChainInterrupted:
            return @"Double-Tap last: consecutive drag returned to native input";
        case DoubleTapReleaseOutcomeWaiting:
            return @"Double-Tap last: waiting for first tap";
    }
    return @"Double-Tap last: unknown state";
}

- (void)updateDoubleTapReleaseRuntimeStatus {
    if (self.doubleTapReleaseRuntimeItem != nil) {
        self.doubleTapReleaseRuntimeItem.title = [self doubleTapReleaseRuntimeStatusTitle];
    }
}

- (void)startMultitouchCallback {
    const char *path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/A/MultitouchSupport";
    self.multitouchHandle = dlopen(path, RTLD_LAZY);
    if (self.multitouchHandle == NULL) {
        NSLog(@"Failed to load MultitouchSupport: %s", dlerror());
        self.statusItem.button.title = @"3F!";
        return;
    }

    MTDeviceCreateDefaultFunction createDefault = (MTDeviceCreateDefaultFunction)dlsym(self.multitouchHandle, "MTDeviceCreateDefault");
    MTDeviceCreateListFunction createList = (MTDeviceCreateListFunction)dlsym(self.multitouchHandle, "MTDeviceCreateList");
    MTRegisterContactFrameCallbackFunction registerCallback = (MTRegisterContactFrameCallbackFunction)dlsym(self.multitouchHandle, "MTRegisterContactFrameCallback");
    MTDeviceStartFunction startDevice = (MTDeviceStartFunction)dlsym(self.multitouchHandle, "MTDeviceStart");

    if (createDefault == NULL || registerCallback == NULL || startDevice == NULL) {
        NSLog(@"Failed to resolve MultitouchSupport symbols");
        self.statusItem.button.title = @"3F!";
        return;
    }

    NSMutableArray<NSValue *> *devices = [NSMutableArray array];
    if (createList != NULL) {
        self.deviceList = createList();
        if (self.deviceList != NULL) {
            CFIndex count = CFArrayGetCount(self.deviceList);
            for (CFIndex i = 0; i < count; i++) {
                MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(self.deviceList, i);
                if (device != NULL) {
                    [devices addObject:[NSValue valueWithPointer:device]];
                }
            }
        }
    }

    if (devices.count == 0) {
        MTDeviceRef defaultDevice = createDefault();
        if (defaultDevice != NULL) {
            [devices addObject:[NSValue valueWithPointer:defaultDevice]];
        }
    }

    if (devices.count == 0) {
        NSLog(@"No multitouch devices found");
        self.statusItem.button.title = @"3F!";
        return;
    }

    os_unfair_lock_lock(&gStateLock);
    gDeviceStateCount = 0;
    for (NSValue *value in devices) {
        if (gDeviceStateCount >= 16) {
            break;
        }
        gDeviceStates[gDeviceStateCount].device = [value pointerValue];
        gDeviceStates[gDeviceStateCount].maxContacts = 0;
        gDeviceStates[gDeviceStateCount].contactCount = 0;
        resetRawDoubleTapStateLocked(&gDeviceStates[gDeviceStateCount]);
        gDeviceStateCount++;
    }
    os_unfair_lock_unlock(&gStateLock);

    for (NSValue *value in devices) {
        MTDeviceRef device = [value pointerValue];
        registerCallback(device, contactFrameCallback);
        startDevice(device, 0);
    }
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
