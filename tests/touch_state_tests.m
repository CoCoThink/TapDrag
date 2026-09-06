#import <CoreGraphics/CoreGraphics.h>
static void capturePostedEvent(CGEventTapLocation location, CGEventRef event);
static CGEventRef createTestMouseEvent(CGEventSourceRef source, CGEventType type,
                                       CGPoint location, CGMouseButton button) {
    (void)source;
    return CGEventCreateMouseEvent(NULL, type, location, button);
}
#define CGEventPost capturePostedEvent
#define TD_CREATE_MOUSE_EVENT(source, type, location, button) \
    createTestMouseEvent((source), (type), (location), (button))
// Headless/sandboxed AppKit can return zero for the session's click interval.
#define TD_SYSTEM_DOUBLE_CLICK_INTERVAL() 0.8
#include "../TapDrag/Sources/TapDragEngine.m"
#undef TD_SYSTEM_DOUBLE_CLICK_INTERVAL
#undef TD_CREATE_MOUSE_EVENT
#undef CGEventPost

#include <assert.h>

static CGEventRef postedEvents[16];
static size_t postedEventCount;

static void capturePostedEvent(CGEventTapLocation location, CGEventRef event) {
    assert(location == kCGHIDEventTap);
    assert(postedEventCount < 16);
    postedEvents[postedEventCount++] = CGEventCreateCopy(event);
}

static MTTouch touch(uint32_t state, int32_t path, int32_t finger,
                     float x, float y) {
    MTTouch value = {0};
    value.state = state;
    value.pathIndex = path;
    value.fingerID = finger;
    value.normalizedVector.position = (MTPoint){x, y};
    return value;
}

static void forceIdle(void) {
    os_unfair_lock_lock(&gChainLock);
    resetChainLocked(ReasonDisabled);
    os_unfair_lock_unlock(&gChainLock);
}

static void testTouchCounting(void) {
    MTTouch contacts[] = {
        touch(MTTouchStateMakeTouch, 1, 1, 0.2f, 0.3f),
        touch(MTTouchStateBreakTouch, 2, 2, 0.4f, 0.5f),
        touch(MTTouchStateTouching, 3, 3, 0.6f, 0.7f),
    };
    assert(touchingCount(contacts, 3) == 2);
    assert(touchingCount(NULL, 0) == 0);
}

static void testIdentityBoundary(void) {
    DeviceState state = {0};
    state.identityValid = YES;
    state.pathIndex = 10;
    state.fingerID = 20;
    MTTouch same = touch(MTTouchStateTouching, 10, 20, 0, 0);
    assert(frameContainsIdentity(&state, &same, 1));

    MTTouch replacement[] = {
        touch(MTTouchStateBreakTouch, 10, 20, 0, 0),
        touch(MTTouchStateMakeTouch, 11, 21, 0, 0),
    };
    assert(!frameContainsIdentity(&state, replacement, 2));
    assert(frameReplacesIdentity(&state, replacement, 2));
}

static void testContinuousIdentityTransfer(void) {
    TDMTDeviceRef device = (TDMTDeviceRef)(uintptr_t)0x7777;
    DeviceState state = {0};
    state.device = device;
    state.chainCandidate = YES;
    state.chainGeneration = 42;
    state.movementConfirmed = YES;
    state.touchStartedTimestamp = 10.0;
    state.pathIndex = 1;
    state.fingerID = 2;
    ChainSnapshot owned = {.phase = DragPhaseOwned,
                           .generation = 42,
                           .device = device};
    assert(contactCanTransferIdentity(&state, device, owned));

    MTTouch replacement = touch(MTTouchStateMakeTouch, 9, 10,
                                0.6f, 0.7f);
    replacement.absoluteVector.position = (MTPoint){60.0f, 70.0f};
    assert(adoptReplacementIdentity(&state, &replacement, 1));
    assert(state.pathIndex == 9);
    assert(state.fingerID == 10);
    assert(state.touchStartedTimestamp == 10.0);
    assert(state.chainGeneration == 42);
    assert(state.movementConfirmed);

    owned.phase = DragPhaseCandidate;
    assert(contactCanTransferIdentity(&state, device, owned));
    owned.phase = DragPhaseStarting;
    assert(contactCanTransferIdentity(&state, device, owned));
    owned.phase = DragPhaseOwned;
    owned.generation = 43;
    assert(!contactCanTransferIdentity(&state, device, owned));

    DeviceState firstContact = {0};
    firstContact.touchMade = YES;
    firstContact.touchStartedTimestamp = 20.0;
    firstContact.firstTapPending = YES;
    ChainSnapshot idle = {.phase = DragPhaseIdle};
    assert(contactCanTransferIdentity(&firstContact, device, idle));
    assert(adoptReplacementIdentity(&firstContact, &replacement, 1));
    assert(firstContact.touchStartedTimestamp == 20.0);
    assert(firstContact.firstTapPending);

    owned.phase = DragPhaseReleasing;
    owned.generation = 42;
    assert(!contactCanTransferIdentity(&state, device, owned));
}

static void testMovementIncludesBreakFrame(void) {
    DeviceState state = {0};
    state.touchMade = YES;
    state.identityValid = YES;
    state.pathIndex = 5;
    state.fingerID = 7;
    state.touchStartedPosition = (MTPoint){0.2f, 0.2f};
    state.touchStartedAbsolutePosition = (MTPoint){20.0f, 20.0f};
    MTTouch end = touch(MTTouchStateBreakTouch, 5, 7, 0.21f, 0.2f);
    end.absoluteVector.position = (MTPoint){21.4f, 20.0f};
    observeBreak(&state, &end, 1);
    assert(state.touchMoved);
    assert(state.maximumSquaredDistanceMM > 1.3f * 1.3f);
}

static void testPhysicalMovementHysteresis(void) {
    DeviceState state = {0};
    state.touchStartedPosition = (MTPoint){0.5f, 0.5f};
    state.touchStartedAbsolutePosition = (MTPoint){50.0f, 30.0f};
    observePosition(&state, (MTPoint){0.504f, 0.5f},
                    (MTPoint){50.8f, 30.0f});
    assert(!state.touchMoved);
    observePosition(&state, (MTPoint){0.506f, 0.5f},
                    (MTPoint){51.31f, 30.0f});
    assert(state.touchMoved);

    DeviceState physicalWins = {0};
    physicalWins.touchStartedPosition = (MTPoint){0.5f, 0.5f};
    physicalWins.touchStartedAbsolutePosition = (MTPoint){50.0f, 30.0f};
    observePosition(&physicalWins, (MTPoint){0.52f, 0.5f},
                    (MTPoint){50.92f, 30.0f});
    assert(!physicalWins.touchMoved);

    DeviceState fallback = {0};
    fallback.touchStartedPosition = (MTPoint){0.5f, 0.5f};
    fallback.touchStartedAbsolutePosition = (MTPoint){NAN, NAN};
    observePosition(&fallback, (MTPoint){0.52f, 0.5f},
                    (MTPoint){NAN, NAN});
    assert(fallback.touchMoved);

    DeviceState zeroAbsolute = {0};
    zeroAbsolute.touchStartedPosition = (MTPoint){0.5f, 0.5f};
    zeroAbsolute.touchStartedAbsolutePosition = (MTPoint){0, 0};
    observePosition(&zeroAbsolute, (MTPoint){0.52f, 0.5f},
                    (MTPoint){0, 0});
    assert(zeroAbsolute.touchMoved);
}

static void testRecognitionWindows(void) {
    assert(doubleTapDragGapForSystemMillis(800) == 160);
    assert(doubleTapDragGapForSystemMillis(300) == 160);
    assert(doubleTapDragGapForSystemMillis(100) == 100);
    assert(doubleTapDragGapForSystemMillis(0) == 1);
    assert(!secondContactGapIsValid(0, 600));
    assert(!secondContactGapIsValid(29, 600));
    assert(secondContactGapIsValid(30, 600));
    assert(secondContactGapIsValid(112, 160));
    assert(secondContactGapIsValid(160, 160));
    assert(!secondContactGapIsValid(168, 160));

    DeviceState accepted = {0};
    accepted.touchMade = YES;
    accepted.touchStartedTimestamp = 10.0;
    accepted.maximumTouching = 1;
    BOOL candidate = NO, movement = NO;
    unsigned long long generation = 0;
    completeTouch(&accepted, 10.24, &candidate, &generation, &movement);
    assert(accepted.firstTapPending);

    DeviceState rejected = {0};
    rejected.touchMade = YES;
    rejected.touchStartedTimestamp = 20.0;
    rejected.maximumTouching = 1;
    completeTouch(&rejected, 20.26, &candidate, &generation, &movement);
    assert(!rejected.firstTapPending);
}

static void testIdentityRestartCannotBecomeSecondContact(void) {
    DeviceState state = {0};
    state.touchMade = YES;
    state.touchStartedTimestamp = 10.0;
    state.maximumTouching = 1;
    BOOL candidate = NO, movement = NO;
    unsigned long long generation = 0;
    completeTouch(&state, 10.08, &candidate, &generation, &movement);
    assert(state.firstTapPending);

    long long sameFrameGap = llround((10.08 - state.firstTapCompletedTimestamp) * 1000.0);
    assert(sameFrameGap == 0);
    assert(!secondContactGapIsValid(sameFrameGap, 600));
}

static void testFirstTapClassification(void) {
    forceIdle();
    DeviceState state = {0};
    state.touchMade = YES;
    state.touchStartedTimestamp = 10.0;
    state.touchingFrames = 3;
    state.maximumTouching = 1;
    state.pointerStart = CGPointMake(100, 120);
    BOOL candidate = NO;
    BOOL movement = NO;
    unsigned long long generation = 0;
    completeTouch(&state, 10.05, &candidate, &generation, &movement);
    assert(!candidate);
    assert(!movement);
    assert(state.firstTapPending);
    assert(state.firstTapCompletedTimestamp == 10.05);
    assert(state.firstTapCompletedUptime > 0);
    assert(state.firstTapPointerValid);

    state.touchMade = YES;
    state.touchStartedTimestamp = 11.0;
    state.touchInvalid = YES;
    state.maximumTouching = 2;
    completeTouch(&state, 11.02, &candidate, &generation, &movement);
    assert(!state.firstTapPending);
    assert(state.firstTapCompletedUptime == 0);
    assert(!state.firstTapPointerValid);

    state.touchMade = YES;
    state.touchStartedTimestamp = 12.0;
    state.maximumTouching = 1;
    state.nativeButtonDownDuringTouch = YES;
    completeTouch(&state, 12.08, &candidate, &generation, &movement);
    assert(!state.firstTapPending);
}

static void testReplacementStateMachine(void) {
    forceIdle();
    TDMTDeviceRef device = (TDMTDeviceRef)(uintptr_t)0x1234;
    unsigned long long generation = 0;
    assert(beginSecondContact(device, CGPointMake(200, 220), YES, 175,
                              &generation));
    ChainSnapshot snapshot = chainSnapshot();
    assert(snapshot.phase == DragPhaseCandidate);
    assert(snapshot.device == device);

    long long downNotBefore = 0;
    assert(promoteContact(device, generation, CGPointMake(210, 230), YES,
                          ReasonMovement,
                          &downNotBefore));
    assert(chainSnapshot().phase == DragPhaseStarting);
    assert(downNotBefore > 0);

    int64_t eventNumber = 0;
    CGPoint location = CGPointZero;
    assert(requestRelease(generation, &eventNumber, &location) ==
           ReleaseStarter);
    assert(chainSnapshot().phase == DragPhaseReleasing);
    assert(finishRelease(generation));
    assert(chainSnapshot().phase == DragPhaseIdle);
    assert(!finishRelease(generation));
}

static void testOwnedReleaseOwnership(void) {
    forceIdle();
    TDMTDeviceRef device = (TDMTDeviceRef)(uintptr_t)0x5678;
    unsigned long long generation = 0;
    assert(beginSecondContact(device, CGPointMake(300, 320), YES, 180,
                              &generation));
    os_unfair_lock_lock(&gChainLock);
    gChain.phase = DragPhaseOwned;
    gChain.eventNumber = 77;
    gChain.latest = CGPointMake(340, 360);
    gChain.latestValid = YES;
    os_unfair_lock_unlock(&gChainLock);

    int64_t eventNumber = 0;
    CGPoint location = CGPointZero;
    assert(requestRelease(generation, &eventNumber, &location) ==
           ReleaseCaller);
    assert(eventNumber == 77);
    assert(CGPointEqualToPoint(location, CGPointMake(340, 360)));
    assert(chainSnapshot().phase == DragPhaseReleasing);
    assert(finishRelease(generation));
    assert(chainSnapshot().phase == DragPhaseIdle);
}

static void testStaleGenerationCannotReleaseNewDrag(void) {
    forceIdle();
    TDMTDeviceRef device = (TDMTDeviceRef)(uintptr_t)0xabcd;
    unsigned long long oldGeneration = 0;
    assert(beginSecondContact(device, CGPointZero, YES, 100,
                              &oldGeneration));
    assert(resetChain(oldGeneration, ReasonDisabled));
    unsigned long long currentGeneration = 0;
    assert(beginSecondContact(device, CGPointZero, YES, 100,
                              &currentGeneration));
    assert(currentGeneration != oldGeneration);
    int64_t eventNumber = 0;
    CGPoint location = CGPointZero;
    assert(requestRelease(oldGeneration, &eventNumber, &location) ==
           ReleaseInactive);
    assert(chainSnapshot().generation == currentGeneration);
    assert(chainSnapshot().phase == DragPhaseCandidate);
    resetChain(currentGeneration, ReasonDisabled);
}

static void testNativeEventPolicy(void) {
    ChainSnapshot snapshot = {.phase = DragPhaseCandidate,
                              .eventNumber = 0};
    assert(dispositionForEvent(snapshot, kCGEventLeftMouseDown) ==
           NativePass);
    assert(dispositionForEvent(snapshot, kCGEventLeftMouseUp) ==
           NativePass);

    snapshot.phase = DragPhaseStarting;
    assert(dispositionForEvent(snapshot, kCGEventLeftMouseDragged) ==
           NativePass);
    assert(dispositionForEvent(snapshot, kCGEventLeftMouseUp) ==
           NativePass);

    snapshot.phase = DragPhaseOwned;
    snapshot.eventNumber = 88;
    assert(dispositionForEvent(snapshot, kCGEventMouseMoved) ==
           NativeReplaceDrag);
    assert(dispositionForEvent(snapshot, kCGEventLeftMouseDragged) ==
           NativeReplaceDrag);
    assert(dispositionForEvent(snapshot, kCGEventLeftMouseUp) ==
           NativeFilter);

    snapshot.phase = DragPhaseReleasing;
    assert(dispositionForEvent(snapshot, kCGEventLeftMouseDown) ==
           NativeFilter);
    snapshot.eventNumber = 0;
    assert(dispositionForEvent(snapshot, kCGEventLeftMouseDown) ==
           NativePass);
    forceIdle();
}

static void clearPostedEvents(void) {
    for (size_t i = 0; i < postedEventCount; ++i) CFRelease(postedEvents[i]);
    postedEventCount = 0;
}

static void setFirstTapCandidate(DeviceState *state, TDMTDeviceRef device,
                                 CGPoint pointer, uint64_t completedUptime) {
    *state = (DeviceState){
        .device = device,
        .firstTapPending = YES,
        .firstTapCompletedUptime = completedUptime,
        .firstTapPointer = pointer,
        .firstTapPointerValid = YES,
    };
}

static void testFirstTapBuffer(void) {
    forceIdle();
    TDMTDeviceRef device = (TDMTDeviceRef)(uintptr_t)0x7779;
    DeviceState savedDevices[TDMaximumMultitouchDevices];
    memcpy(savedDevices, gDevices, sizeof(gDevices));
    int savedCount = gDeviceCount;
    gDeviceCount = 1;
    atomic_store(&gEnabled, true);
    atomic_store(&gInternalDraggingPresent, true);
    atomic_store(&gInternalDraggingEnabled, false);
    atomic_store(&gBluetoothDraggingPresent, false);
    gSyntheticSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGPoint pointer = CGPointZero;
    assert(copyPointerLocation(&pointer));
    setFirstTapCandidate(&gDevices[0], device, pointer,
                         clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown,
                                             pointer, kCGMouseButtonLeft);
    CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp,
                                           pointer, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(down, kCGEventTargetUnixProcessID, 23013);
    CGEventSetIntegerValueField(down, kCGMouseEventSubtype, NSEventSubtypeTouch);
    CGEventSetIntegerValueField(down, kCGMouseEventNumber, 77);
    CGEventSetIntegerValueField(up, kCGMouseEventNumber, 77);
    // Dock must not see the first click before the downstream buffer runs.
    assert(eventTapCallback(NULL, kCGEventLeftMouseDown, down, NULL) == NULL);
    assert(eventTapCallback(NULL, kCGEventLeftMouseUp, up, NULL) == NULL);
    assert(postedEventCount == 0);
    unsigned long long token = gBufferedTapToken;
    expireBufferedTap(token);
    assert(postedEventCount == 2);
    assert(CGEventGetType(postedEvents[0]) == kCGEventLeftMouseDown);
    assert(CGEventGetType(postedEvents[1]) == kCGEventLeftMouseUp);
    assert(ownEvent(postedEvents[0]) && ownEvent(postedEvents[1]));
    for (size_t i = 0; i < postedEventCount; ++i) {
        CGEventRef event = postedEvents[i];
        assert(eventTapCallback(NULL, CGEventGetType(event), event, NULL) == event);
        assert(clickBufferCallback(NULL, CGEventGetType(event), event, NULL) == event);
    }
    expireBufferedTap(token);
    assert(postedEventCount == 2);
    clearPostedEvents();

    setFirstTapCandidate(&gDevices[0], device, pointer,
                         clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    CGEventSetIntegerValueField(down, kCGMouseEventNumber, 76);
    assert(bufferTrackpadTapButton(kCGEventLeftMouseDown, down));
    interruptChain(ReasonDisabled);
    assert(gBufferedTapDown == NULL);
    assert(postedEventCount == 0);

    CGEventSetIntegerValueField(down, kCGMouseEventNumber, 77);
    assert(bufferTrackpadTapButton(kCGEventLeftMouseDown, down));
    assert(bufferTrackpadTapButton(kCGEventLeftMouseUp, up));
    CGEventSetIntegerValueField(down, kCGMouseEventNumber, 78);
    CGEventSetIntegerValueField(up, kCGMouseEventNumber, 78);
    CGEventSetIntegerValueField(down, kCGMouseEventClickState, 2);
    assert(bufferTrackpadTapButton(kCGEventLeftMouseDown, down));
    assert(bufferTrackpadTapButton(kCGEventLeftMouseUp, up));
    assert(postedEventCount == 4);
    assert(CGEventGetIntegerValueField(postedEvents[2], kCGMouseEventClickState) == 2);
    assert(CGEventGetType(postedEvents[3]) == kCGEventLeftMouseUp);
    clearPostedEvents();

    assert(bufferTrackpadTapButton(kCGEventLeftMouseDown, down));
    assert(bufferTrackpadTapButton(kCGEventLeftMouseUp, up));
    token = gBufferedTapToken;
    gChain = (DragChain){.generation = 500, .phase = DragPhaseStarting, .device = device,
        .start = CGPointMake(10, 20), .latest = CGPointMake(40, 20),
        .startValid = YES, .latestValid = YES};
    assert(startSyntheticDrag(device, 500, atomic_load(&gFeatureEpoch)));
    assert(gBufferedTapDown == NULL);
    assert(postedEventCount == 2);
    assert(CGEventGetType(postedEvents[1]) == kCGEventLeftMouseDragged);
    expireBufferedTap(token);
    assert(postedEventCount == 2);
    interruptChain(ReasonDisabled);
    assert(postedEventCount == 3);
    assert(CGEventGetType(postedEvents[2]) == kCGEventLeftMouseUp);
    clearPostedEvents();

    CGEventSetLocation(down, CGPointMake(pointer.x + 50, pointer.y));
    CGEventSetLocation(up, CGPointMake(pointer.x + 50, pointer.y));
    setFirstTapCandidate(&gDevices[0], device, CGEventGetLocation(down),
                         clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    assert(bufferTrackpadTapButton(kCGEventLeftMouseDown, down));
    assert(bufferTrackpadTapButton(kCGEventLeftMouseUp, up));
    expireBufferedTap(gBufferedTapToken);
    assert(postedEventCount == 3);
    assert(CGEventGetType(postedEvents[2]) == kCGEventMouseMoved);
    assert(CGPointEqualToPoint(CGEventGetLocation(postedEvents[2]), pointer));
    clearPostedEvents();

    setFirstTapCandidate(&gDevices[0], device, pointer,
                         clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    atomic_store(&gInternalDraggingEnabled, true);
    assert(!bufferTrackpadTapButton(kCGEventLeftMouseDown, down));
    CFRelease(down); CFRelease(up); CFRelease(gSyntheticSource);
    gSyntheticSource = NULL;
    atomic_store(&gEnabled, false);
    memcpy(gDevices, savedDevices, sizeof(gDevices));
    gDeviceCount = savedCount;
    forceIdle();
}

static void testFirstTapCorrelation(void) {
    forceIdle();
    DeviceState savedDevices[TDMaximumMultitouchDevices];
    memcpy(savedDevices, gDevices, sizeof(gDevices));
    int savedCount = gDeviceCount;
    TDMTDeviceRef device = (TDMTDeviceRef)(uintptr_t)0x7780;
    CGPoint pointer = CGPointZero;
    assert(copyPointerLocation(&pointer));
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    gDeviceCount = 1;
    setFirstTapCandidate(&gDevices[0], device, pointer, now);
    atomic_store(&gEnabled, true);
    atomic_store(&gInternalDraggingPresent, true);
    atomic_store(&gInternalDraggingEnabled, false);
    atomic_store(&gBluetoothDraggingPresent, false);
    gSyntheticSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    assert(gSyntheticSource);

    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown,
                                             pointer, kCGMouseButtonLeft);
    CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp,
                                           pointer, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(down, kCGEventTargetUnixProcessID, 999);
    CGEventSetIntegerValueField(down, kCGMouseEventSubtype, NSEventSubtypeTouch);
    CGEventSetIntegerValueField(down, kCGMouseEventNumber, 91);
    CGEventSetIntegerValueField(up, kCGMouseEventNumber, 91);
    assert(bufferTrackpadTapButton(kCGEventLeftMouseDown, down));
    assert(bufferTrackpadTapButton(kCGEventLeftMouseUp, up));
    expireBufferedTap(gBufferedTapToken);
    assert(postedEventCount == 2);
    clearPostedEvents();

    uint64_t maximumAge = (uint64_t)(doubleTapDragGapMillis() +
        FirstClickAllowanceMillis) * NSEC_PER_MSEC;
    setFirstTapCandidate(&gDevices[0], device, pointer,
                         clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - maximumAge - NSEC_PER_MSEC);
    assert(!bufferTrackpadTapButton(kCGEventLeftMouseDown, down));

    setFirstTapCandidate(&gDevices[0], device, pointer,
                         clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    CGEventSetLocation(down, CGPointMake(pointer.x +
        MaximumFirstTapEventDistancePoints + 1.0, pointer.y));
    assert(!bufferTrackpadTapButton(kCGEventLeftMouseDown, down));
    CGEventSetLocation(down, pointer);

    CGEventSetIntegerValueField(down, kCGMouseEventSubtype, 0);
    assert(!bufferTrackpadTapButton(kCGEventLeftMouseDown, down));
    CGEventSetIntegerValueField(down, kCGMouseEventSubtype, NSEventSubtypeTouch);

    gDevices[0].touchingCount = gDevices[0].maximumTouching = 1;
    assert(!bufferTrackpadTapButton(kCGEventLeftMouseDown, down));
    gDevices[0].chainCandidate = YES;
    gDevices[0].chainGeneration = 550;
    gChain = (DragChain){.phase = DragPhaseCandidate, .device = device,
        .generation = 551};
    assert(!bufferTrackpadTapButton(kCGEventLeftMouseDown, down));
    gChain.generation = 550;
    gDevices[0].touchInvalid = YES;
    assert(!bufferTrackpadTapButton(kCGEventLeftMouseDown, down));
    gDevices[0].touchInvalid = NO;
    gDevices[0].touchingCount = 2;
    assert(!bufferTrackpadTapButton(kCGEventLeftMouseDown, down));
    forceIdle();
    setFirstTapCandidate(&gDevices[0], device, pointer,
                         clock_gettime_nsec_np(CLOCK_UPTIME_RAW));

    gDeviceCount = 2;
    setFirstTapCandidate(&gDevices[1], (TDMTDeviceRef)(uintptr_t)0x7781,
                         pointer, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    assert(!bufferTrackpadTapButton(kCGEventLeftMouseDown, down));

    CFRelease(down); CFRelease(up); CFRelease(gSyntheticSource);
    gSyntheticSource = NULL;
    atomic_store(&gEnabled, false);
    memcpy(gDevices, savedDevices, sizeof(gDevices));
    gDeviceCount = savedCount;
    forceIdle();
}

static void testDelayedFirstTapButtons(void) {
    forceIdle();
    DeviceState savedDevices[TDMaximumMultitouchDevices];
    memcpy(savedDevices, gDevices, sizeof(gDevices));
    int savedCount = gDeviceCount;
    TDMTDeviceRef device = (TDMTDeviceRef)(uintptr_t)0x7782;
    atomic_store(&gEnabled, true);
    atomic_store(&gInternalDraggingPresent, true);
    atomic_store(&gInternalDraggingEnabled, false);
    atomic_store(&gBluetoothDraggingPresent, false);
    gSyntheticSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    assert(gSyntheticSource);
    gDeviceCount = 1;

    for (int downstream = 0; downstream < 2; ++downstream) {
        for (int upArrival = 0; upArrival < 3; ++upArrival) {
            gDevices[0] = (DeviceState){.device = device};
            MTTouch first = touch(MTTouchStateMakeTouch, 1, 1, 0.5f, 0.5f);
            TDGestureEngineContactFrameCallback(device, &first, 1, 10.0, 1);
            TDGestureEngineContactFrameCallback(device, NULL, 0, 10.06, 2);
            assert(gDevices[0].firstTapPending);
            CGPoint pointer = gDevices[0].firstTapPointer;
            MTTouch second = touch(MTTouchStateMakeTouch, 2, 2, 0.5f, 0.5f);
            TDGestureEngineContactFrameCallback(device, &second, 1, 10.12, 3);
            assert(gDevices[0].chainCandidate);
            unsigned long long generation = gDevices[0].chainGeneration;

            CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown,
                                                     pointer, kCGMouseButtonLeft);
            CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp,
                                                   pointer, kCGMouseButtonLeft);
            CGEventSetIntegerValueField(down, kCGMouseEventSubtype, NSEventSubtypeTouch);
            CGEventSetIntegerValueField(down, kCGMouseEventNumber, 92);
            CGEventSetIntegerValueField(up, kCGMouseEventNumber, 92);
            CGEventRef (*callback)(CGEventTapProxy, CGEventType, CGEventRef, void *) =
                downstream ? clickBufferCallback : eventTapCallback;
            // The first native down arrives only after the second raw contact.
            assert(callback(NULL, kCGEventLeftMouseDown, down, NULL) == NULL);
            assert(!gDevices[0].nativeButtonDownDuringTouch);
            if (upArrival == 0)
                assert(callback(NULL, kCGEventLeftMouseUp, up, NULL) == NULL);
            unsigned long long token = gBufferedTapToken;
            expireBufferedTap(token);
            assert(postedEventCount == 0);

            long long notBefore = 0;
            CGPoint latest = CGPointMake(pointer.x + 30, pointer.y);
            assert(promoteContact(device, generation, latest, YES,
                                  ReasonMovement, &notBefore));
            gDevices[0].movementConfirmed = gDevices[0].startRequested = YES;
            gChain.downNotBeforeMillis = 0;
            assert(startSyntheticDrag(device, generation, atomic_load(&gFeatureEpoch)));
            assert(gBufferedTapDown == NULL);
            assert(postedEventCount == 2);
            assert(CGEventGetType(postedEvents[0]) == kCGEventLeftMouseDown);
            assert(CGEventGetType(postedEvents[1]) == kCGEventLeftMouseDragged);
            if (upArrival == 1)
                assert(callback(NULL, kCGEventLeftMouseUp, up, NULL) == NULL);

            TDGestureEngineContactFrameCallback(device, NULL, 0, 10.18, 4);
            assert(chainSnapshot().phase == DragPhaseIdle);
            assert(postedEventCount == 3);
            assert(CGEventGetType(postedEvents[2]) == kCGEventLeftMouseUp);
            if (upArrival == 2)
                assert(callback(NULL, kCGEventLeftMouseUp, up, NULL) == NULL);
            assert(!gDiscardedTapUpPending);
            expireBufferedTap(token);
            assert(postedEventCount == 3);
            clearPostedEvents();
            CFRelease(down); CFRelease(up);
        }
    }

    // A downstream button that missed the HID ownership check must not end a drag.
    gChain = (DragChain){.phase = DragPhaseOwned, .generation = 600,
        .device = device, .eventNumber = 100};
    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown,
                                             CGPointZero, kCGMouseButtonLeft);
    CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp,
                                           CGPointZero, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(down, kCGMouseEventNumber, 93);
    CGEventSetIntegerValueField(up, kCGMouseEventNumber, 93);
    assert(clickBufferCallback(NULL, kCGEventLeftMouseDown, down, NULL) == NULL);
    forceIdle();
    assert(clickBufferCallback(NULL, kCGEventLeftMouseUp, up, NULL) == NULL);
    assert(postedEventCount == 0);
    // A fresh physical press remains immediate, even if an old up never arrived.
    gDiscardedTapUpPending = YES;
    gDiscardedTapUpNumber = 93;
    assert(eventTapCallback(NULL, kCGEventLeftMouseDown, down, NULL) == down);
    assert(eventTapCallback(NULL, kCGEventLeftMouseUp, up, NULL) == up);
    assert(!gDiscardedTapUpPending);

    CFRelease(down); CFRelease(up); CFRelease(gSyntheticSource);
    gSyntheticSource = NULL;
    atomic_store(&gEnabled, false);
    memcpy(gDevices, savedDevices, sizeof(gDevices));
    gDeviceCount = savedCount;
    forceIdle();
}

static void testSerializedDragTransaction(void) {
    forceIdle();
    gSyntheticSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    assert(gSyntheticSource != NULL);
    atomic_store(&gEnabled, true);
    atomic_store(&gInternalDraggingPresent, true);
    atomic_store(&gInternalDraggingEnabled, false);
    atomic_store(&gBluetoothDraggingPresent, false);
    TDMTDeviceRef device = (TDMTDeviceRef)(uintptr_t)0x8888;
    os_unfair_lock_lock(&gChainLock);
    gChain.generation = 100;
    gChain.phase = DragPhaseStarting;
    gChain.device = device;
    gChain.start = gChain.latest = CGPointMake(10, 20);
    gChain.startValid = gChain.latestValid = YES;
    os_unfair_lock_unlock(&gChainLock);
    assert(startSyntheticDrag(device, 100, atomic_load(&gFeatureEpoch)));
    ChainSnapshot snapshot = chainSnapshot();
    assert(postedEventCount == 1);
    assert(CGEventGetType(postedEvents[0]) == kCGEventLeftMouseDown);
    CGEventRef movement = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
                                                  CGPointMake(11, 21),
                                                  kCGMouseButtonLeft);
    assert(movement != NULL);
    CGEventSetIntegerValueField(movement, kCGEventTargetUnixProcessID, 4106);
    CGEventSetIntegerValueField(movement,
        kCGEventTargetProcessSerialNumber, 9876);
    CGEventSetIntegerValueField(movement,
        kCGMouseEventWindowUnderMousePointer, 1234);
    CGEventSetIntegerValueField(movement,
        kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, 1235);
    CGEventSetIntegerValueField(movement, kCGMouseEventDeltaX, -8);
    CGEventSetIntegerValueField(movement, kCGMouseEventDeltaY, 3);
    CGEventSetFlags(movement, kCGEventFlagMaskShift);
    assert(eventTapCallback(NULL, kCGEventMouseMoved, movement, NULL) == NULL);
    assert(postedEventCount == 2);
    CGEventRef drag = postedEvents[1];
    assert(CGEventGetType(drag) == kCGEventLeftMouseDragged);
    assert(CGEventGetType(movement) == kCGEventMouseMoved);
    assert(CGPointEqualToPoint(CGEventGetLocation(drag), CGPointMake(11, 21)));
    assert(CGEventGetFlags(drag) == kCGEventFlagMaskShift);
    assert(CGEventGetIntegerValueField(drag, kCGMouseEventDeltaX) == -8);
    assert(CGEventGetIntegerValueField(drag, kCGMouseEventDeltaY) == 3);
    assert(CGEventGetDoubleValueField(drag, kCGMouseEventPressure) == 1.0);
    assert(CGEventGetIntegerValueField(drag, kCGEventTargetUnixProcessID) != 4106);
    assert(CGEventGetIntegerValueField(drag, kCGMouseEventWindowUnderMousePointer) != 1234);
    // Posted events must pass through without being converted or posted again.
    assert(eventTapCallback(NULL, kCGEventLeftMouseDragged, drag, NULL) == drag);
    assert(postedEventCount == 2);

    int64_t number = 0;
    CGPoint location = CGPointZero;
    assert(requestRelease(snapshot.generation, &number, &location) == ReleaseCaller);
    assert(!postNativeMovementAsDrag(movement, snapshot));
    assert(postUp(number, location, snapshot.generation));
    assert(finishRelease(snapshot.generation));
    assert(!postNativeMovementAsDrag(movement, snapshot));
    assert(postedEventCount == 3);
    assert(CGEventGetType(postedEvents[2]) == kCGEventLeftMouseUp);
    for (size_t i = 0; i < postedEventCount; i++) {
        assert(ownEvent(postedEvents[i]));
        assert(CGEventGetIntegerValueField(postedEvents[i], kCGMouseEventNumber) == number);
        assert(CGEventGetIntegerValueField(postedEvents[i], kCGMouseEventClickState) == 1);
        assert(CGEventGetIntegerValueField(postedEvents[i], kCGMouseEventSubtype) == NSEventSubtypeTouch);
        assert([NSEvent eventWithCGEvent:postedEvents[i]].subtype == NSEventSubtypeTouch);
        assert(CGEventGetIntegerValueField(postedEvents[i], kCGEventSourceUnixProcessID) == getpid());
        assert(CGEventGetTimestamp(postedEvents[i]) > 0);
        if (i) assert(CGEventGetTimestamp(postedEvents[i]) >= CGEventGetTimestamp(postedEvents[i - 1]));
    }
    for (size_t i = 0; i < postedEventCount; i++) CFRelease(postedEvents[i]);
    postedEventCount = 0;
    CFRelease(movement);
    CFRelease(gSyntheticSource);
    gSyntheticSource = NULL;
    atomic_store(&gEnabled, false);
    forceIdle();
}

static void testDownstreamObserverDoesNotChangeOwnership(void) {
    forceIdle();
    TDGestureEngineClearDiagnostics();
    atomic_store(&gEnabled, true);
    os_unfair_lock_lock(&gChainLock);
    gChain.generation = 200;
    gChain.phase = DragPhaseOwned;
    gChain.eventNumber = 91;
    os_unfair_lock_unlock(&gChainLock);
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown,
                                              CGPointMake(40, 50), kCGMouseButtonLeft);
    assert(event != NULL);
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, DoubleTapTag);
    CGEventSetIntegerValueField(event, kCGMouseEventNumber, 91);
    assert(downstreamObserverCallback(NULL, kCGEventLeftMouseDown, event, NULL) == event);
    assert(chainSnapshot().phase == DragPhaseOwned);
    assert(CGEventGetType(event) == kCGEventLeftMouseDown);

    forceIdle();
    CGEventSetType(event, kCGEventLeftMouseUp);
    assert(downstreamObserverCallback(NULL, kCGEventLeftMouseUp, event, NULL) == event);
    assert(chainSnapshot().phase == DragPhaseIdle);
    assert(CGEventGetIntegerValueField(event, kCGMouseEventNumber) == 91);
    DiagnosticRecord records[8] = {0};
    size_t count = copyRecords(records, 8, NULL);
    assert(count == 3);
    assert(records[0].kind == DiagnosticDownstreamObserved);
    assert(records[0].generation == 200);
    assert(records[2].kind == DiagnosticDownstreamObserved);
    assert(records[2].generation == 0);
    assert(records[2].eventNumber == 91);

    CFRelease(event);
    event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
                                    CGPointMake(45, 50), kCGMouseButtonLeft);
    assert(event != NULL && !ownEvent(event));
    downstreamObserverCallback(NULL, kCGEventMouseMoved, event, NULL);
    assert(copyRecords(records, 8, NULL) == count);

    // Losing diagnostics must never interrupt or release an active drag.
    os_unfair_lock_lock(&gChainLock);
    gChain.phase = DragPhaseOwned;
    gChain.eventNumber = 92;
    os_unfair_lock_unlock(&gChainLock);
    // A leaked native move must be visible to diagnostics, but the observer
    // must neither consume it nor turn it into another drag.
    assert(downstreamObserverCallback(NULL, kCGEventMouseMoved, event, NULL) == event);
    assert(CGEventGetType(event) == kCGEventMouseMoved);
    count = copyRecords(records, 8, NULL);
    assert(count == 4);
    assert(records[3].kind == DiagnosticDownstreamObserved);
    assert(records[3].generation == chainSnapshot().generation);
    assert(records[3].eventType == kCGEventMouseMoved);
    downstreamObserverCallback(NULL, kCGEventTapDisabledByTimeout, NULL, NULL);
    assert(chainSnapshot().phase == DragPhaseOwned);
    atomic_store(&gEnabled, false);
    count = copyRecords(records, 8, NULL);
    downstreamObserverCallback(NULL, kCGEventLeftMouseUp, event, NULL);
    assert(copyRecords(records, 8, NULL) == count);
    CFRelease(event);
    forceIdle();
}


static BOOL fakeDeviceIsBuiltIn(TDMTDeviceRef device) {
    return device == (TDMTDeviceRef)(uintptr_t)1;
}

static int fakeSensorDimensions(TDMTDeviceRef device, int *rows, int *columns) {
    *columns = 20;
    if (device == (TDMTDeviceRef)(uintptr_t)3) return -1;
    *rows = device == (TDMTDeviceRef)(uintptr_t)1 ? 2 : 10;
    return 0;
}

static void testMultitouchDeviceFiltering(void) {
    TDMTDeviceGetSensorDimensionsFunction previous = gDeviceGetSensorDimensions;
    gDeviceGetSensorDimensions = fakeSensorDimensions;
    assert(!TDGestureEngineShouldUseMultitouchDevice((TDMTDeviceRef)(uintptr_t)1));
    assert(TDGestureEngineShouldUseMultitouchDevice((TDMTDeviceRef)(uintptr_t)2));
    assert(TDGestureEngineShouldUseMultitouchDevice((TDMTDeviceRef)(uintptr_t)3));
    gDeviceGetSensorDimensions = NULL;
    assert(TDGestureEngineShouldUseMultitouchDevice((TDMTDeviceRef)(uintptr_t)1));
    gDeviceGetSensorDimensions = previous;
}

static void testDeviceSpecificDraggingPreferences(void) {
    TDMTDeviceIsBuiltInFunction previous = gDeviceIsBuiltIn;
    gDeviceIsBuiltIn = fakeDeviceIsBuiltIn;
    atomic_store(&gInternalDraggingPresent, true);
    atomic_store(&gInternalDraggingEnabled, false);
    atomic_store(&gBluetoothDraggingPresent, true);
    atomic_store(&gBluetoothDraggingEnabled, true);
    assert(!nativeDraggingForDevice((TDMTDeviceRef)(uintptr_t)1));
    assert(nativeDraggingForDevice((TDMTDeviceRef)(uintptr_t)2));

    atomic_store(&gInternalDraggingPresent, false);
    assert(nativeDraggingForDevice((TDMTDeviceRef)(uintptr_t)1));
    atomic_store(&gInternalDraggingPresent, true);
    atomic_store(&gBluetoothDraggingPresent, false);
    assert(nativeDraggingForDevice((TDMTDeviceRef)(uintptr_t)2));
    gDeviceIsBuiltIn = previous;
}

static void testInputSuspensionGate(void) {
    BOOL previousEnabled = atomic_load(&gEnabled);
    BOOL previousSuspended = atomic_load(&gInputSuspended);
    BOOL previousInternalPresent = atomic_load(&gInternalDraggingPresent);
    BOOL previousInternalEnabled = atomic_load(&gInternalDraggingEnabled);
    TDMTDeviceIsBuiltInFunction previousClassifier = gDeviceIsBuiltIn;
    gDeviceIsBuiltIn = fakeDeviceIsBuiltIn;
    atomic_store(&gEnabled, true);
    atomic_store(&gInternalDraggingPresent, true);
    atomic_store(&gInternalDraggingEnabled, false);
    atomic_store(&gInputSuspended, false);
    assert(replacementActive((TDMTDeviceRef)(uintptr_t)1));
    atomic_store(&gInputSuspended, true);
    assert(!replacementActive((TDMTDeviceRef)(uintptr_t)1));
    atomic_store(&gEnabled, previousEnabled);
    atomic_store(&gInputSuspended, previousSuspended);
    atomic_store(&gInternalDraggingPresent, previousInternalPresent);
    atomic_store(&gInternalDraggingEnabled, previousInternalEnabled);
    gDeviceIsBuiltIn = previousClassifier;
}

static void testInputReadinessIsAtomic(void) {
    DeviceState previousDevices[TDMaximumMultitouchDevices];
    memcpy(previousDevices, gDevices, sizeof(gDevices));
    int previousCount = gDeviceCount;
    BOOL previousReady = atomic_load(&gMultitouchReady);
    BOOL previousEnabled = atomic_load(&gEnabled);
    BOOL previousSuspended = atomic_load(&gInputSuspended);

    TDMTDeviceRef device = (TDMTDeviceRef)(uintptr_t)0x9001;
    TDGestureEngineSetMultitouchDevices(&device, 1);
    assert(TDGestureEngineGetStatus().multitouchReady);

    atomic_store(&gEnabled, true);
    atomic_store(&gInputSuspended, true);
    assert(!TDGestureEngineResumeInput());
    assert(TDGestureEngineGetStatus().inputSuspended);

    atomic_store(&gEnabled, false);
    assert(TDGestureEngineResumeInput());
    TDGestureEngineSetMultitouchDevices(NULL, 0);
    assert(!TDGestureEngineGetStatus().multitouchReady);

    memcpy(gDevices, previousDevices, sizeof(gDevices));
    gDeviceCount = previousCount;
    atomic_store(&gMultitouchReady, previousReady);
    atomic_store(&gEnabled, previousEnabled);
    atomic_store(&gInputSuspended, previousSuspended);
}

static void testLogRetention(void) {
    NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSFileManager *manager = NSFileManager.defaultManager;
    assert([manager createDirectoryAtURL:directory withIntermediateDirectories:YES
                              attributes:nil error:nil]);
    NSURL *protectedURL = nil;
    for (NSUInteger i = 0; i < AutomaticLogLimit + 3; i++) {
        NSURL *file = [directory URLByAppendingPathComponent:
            [NSString stringWithFormat:@"double-tap-%02lu.jsonl", (unsigned long)i]];
        assert([[NSData data] writeToURL:file options:0 error:nil]);
        if (i == 0) protectedURL = file;
    }
    pruneLogs(directory, protectedURL);
    NSArray<NSURL *> *remaining = [manager contentsOfDirectoryAtURL:directory
        includingPropertiesForKeys:nil options:0 error:nil];
    assert(remaining.count == AutomaticLogLimit);
    assert([manager fileExistsAtPath:protectedURL.path]);
    assert([manager removeItemAtURL:directory error:nil]);
}

static void testSyntheticEventMetadata(void) {
    gSyntheticSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    assert(gSyntheticSource != NULL);
    assert(CGEventSourceGetSourceStateID(gSyntheticSource) ==
           kCGEventSourceStateHIDSystemState);
    CGEventRef down = createTaggedEvent(kCGEventLeftMouseDown,
                                        CGPointMake(10, 20),
                                        42);
    assert(down != NULL);
    assert(ownEvent(down));
    assert(CGEventGetIntegerValueField(down, kCGMouseEventNumber) == 42);
    assert(CGEventGetIntegerValueField(down, kCGMouseEventClickState) == 1);
    assert(CGEventGetIntegerValueField(down, kCGMouseEventSubtype) == NSEventSubtypeTouch);
    assert(CGEventGetIntegerValueField(down, kCGEventSourceStateID) ==
           kCGEventSourceStateHIDSystemState);
    assert(CGEventGetIntegerValueField(down, kCGEventSourceUnixProcessID) ==
           getpid());
    CFRelease(down);

    gNextEventNumber = SyntheticEventNumberMaximum;
    assert(nextEventNumberLocked() == SyntheticEventNumberMaximum);
    assert(nextEventNumberLocked() == SyntheticEventNumberMinimum);
    CFRelease(gSyntheticSource);
    gSyntheticSource = NULL;
}

static void testDiagnosticRing(void) {
    TDGestureEngineClearDiagnostics();
    recordDiagnostic(DiagnosticSecondContact, ReasonSecondTap, 99,
                     DragPhaseCandidate, NULL, CGPointMake(30, 40),
                     12, 3, 1, NO, NO);
    recordDiagnostic(DiagnosticMovement, ReasonMovement, 99,
                     DragPhaseStarting, NULL, CGPointMake(31, 41),
                     20, 4, 1, YES, NO);
    DiagnosticRecord records[4] = {0};
    unsigned int dropped = 0;
    assert(copyRecords(records, 4, &dropped) == 2);
    assert(dropped == 0);
    assert(records[0].generation == 99);
    assert(records[0].kind == DiagnosticSecondContact);
    assert(records[1].moved == YES);
    NSString *text = TDGestureEngineDiagnosticText(@"test");
    assert([text containsString:@"\"second_contact\""]);
    assert([text containsString:@"\"movement_confirmed\""]);
    assert([text containsString:@"\"first_click_allowance_ms\":20"]);
    assert([text containsString:@"\"diagnostic_schema\":6"]);

    TDGestureEngineClearDiagnostics();
    for (NSUInteger i = 0; i < DiagnosticCapacity + 3; ++i) {
        recordDiagnostic(DiagnosticMovement, ReasonMovement, i,
                         DragPhaseOwned, NULL, CGPointZero,
                         0, 0, 1, YES, NO);
    }
    assert(copyRecords(records, 4, NULL) == 4);
    assert(records[0].sequence == DiagnosticCapacity - 1);
    assert(records[3].sequence == DiagnosticCapacity + 2);
}

int main(void) {
    testTouchCounting();
    testIdentityBoundary();
    testContinuousIdentityTransfer();
    testMovementIncludesBreakFrame();
    testPhysicalMovementHysteresis();
    testRecognitionWindows();
    testIdentityRestartCannotBecomeSecondContact();
    testFirstTapClassification();
    testReplacementStateMachine();
    testOwnedReleaseOwnership();
    testStaleGenerationCannotReleaseNewDrag();
    testNativeEventPolicy();
    testFirstTapBuffer();
    testFirstTapCorrelation();
    testDelayedFirstTapButtons();
    testSerializedDragTransaction();
    testDownstreamObserverDoesNotChangeOwnership();
    testMultitouchDeviceFiltering();
    testDeviceSpecificDraggingPreferences();
    testInputSuspensionGate();
    testInputReadinessIsAtomic();
    testLogRetention();
    testSyntheticEventMetadata();
    testDiagnosticRing();
    return 0;
}
