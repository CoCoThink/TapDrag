#define main threeFDragUnstuckApplicationMain
#include "../3FDragUnstuck/Sources/main.m"
#undef main

#include <assert.h>

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

static void testOwnedIdentityTransfer(void) {
    MTDeviceRef device = (MTDeviceRef)(uintptr_t)0x7777;
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
    assert(dragOwnsContinuousContact(&state, device, owned));

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
    assert(!dragOwnsContinuousContact(&state, device, owned));
    owned.phase = DragPhaseOwned;
    owned.generation = 43;
    assert(!dragOwnsContinuousContact(&state, device, owned));
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
    assert(state.maximumSquaredDistance > 0);
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
}

static void testRecognitionWindows(void) {
    assert(doubleTapDragGapForSystemMillis(800) == 160);
    assert(doubleTapDragGapForSystemMillis(528) == 160);
    assert(doubleTapDragGapForSystemMillis(552) == 160);
    assert(doubleTapDragGapForSystemMillis(640) == 160);
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
    state.maximumSquaredDistance = 0.000001f;
    state.pointerStart = CGPointMake(100, 120);
    BOOL candidate = NO;
    BOOL movement = NO;
    unsigned long long generation = 0;
    completeTouch(&state, 10.05, &candidate, &generation, &movement);
    assert(!candidate);
    assert(!movement);
    assert(state.firstTapPending);
    assert(state.firstTapCompletedTimestamp == 10.05);
    assert(atomic_load(&gLastOutcome) == ReleaseOutcomeFirstTap);

    state.touchMade = YES;
    state.touchStartedTimestamp = 11.0;
    state.touchInvalid = YES;
    state.maximumTouching = 2;
    completeTouch(&state, 11.02, &candidate, &generation, &movement);
    assert(!state.firstTapPending);
    assert(atomic_load(&gLastOutcome) == ReleaseOutcomeInvalid);

    state.touchMade = YES;
    state.touchStartedTimestamp = 12.0;
    state.maximumTouching = 1;
    state.nativeButtonDownDuringTouch = YES;
    completeTouch(&state, 12.08, &candidate, &generation, &movement);
    assert(!state.firstTapPending);
    assert(atomic_load(&gLastOutcome) == ReleaseOutcomeWaiting);
}

static void testReplacementStateMachine(void) {
    forceIdle();
    MTDeviceRef device = (MTDeviceRef)(uintptr_t)0x1234;
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
    MTDeviceRef device = (MTDeviceRef)(uintptr_t)0x5678;
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
    MTDeviceRef device = (MTDeviceRef)(uintptr_t)0xabcd;
    unsigned long long oldGeneration = 0;
    assert(beginSecondContact(device, CGPointZero, YES, 100, &oldGeneration));
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
}

static BOOL fakeDeviceIsBuiltIn(MTDeviceRef device) {
    return device == (MTDeviceRef)(uintptr_t)1;
}

static void testDeviceSpecificDraggingPreferences(void) {
    MTDeviceIsBuiltInFunction previous = gDeviceIsBuiltIn;
    gDeviceIsBuiltIn = fakeDeviceIsBuiltIn;
    atomic_store(&gInternalDraggingPresent, true);
    atomic_store(&gInternalDraggingEnabled, false);
    atomic_store(&gBluetoothDraggingPresent, true);
    atomic_store(&gBluetoothDraggingEnabled, true);
    assert(!nativeDraggingForDevice((MTDeviceRef)(uintptr_t)1));
    assert(nativeDraggingForDevice((MTDeviceRef)(uintptr_t)2));
    gDeviceIsBuiltIn = previous;
}

static void testSyntheticEventMetadata(void) {
    gSyntheticSource = CGEventSourceCreate(
        kCGEventSourceStateCombinedSessionState);
    assert(gSyntheticSource != NULL);
    CGEventRef down = createTaggedEvent(kCGEventLeftMouseDown,
                                        CGPointMake(10, 20),
                                        42);
    assert(down != NULL);
    assert(ownEvent(down));
    assert(CGEventGetIntegerValueField(down, kCGMouseEventNumber) == 42);
    assert(CGEventGetIntegerValueField(down, kCGMouseEventClickState) == 1);
    CFRelease(down);

    gNextEventNumber = SyntheticEventNumberMaximum;
    assert(nextEventNumberLocked() == SyntheticEventNumberMaximum);
    assert(nextEventNumberLocked() == SyntheticEventNumberMinimum);
    CFRelease(gSyntheticSource);
    gSyntheticSource = NULL;
}

static void testDiagnosticRing(void) {
    clearRecords();
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
    NSString *text = traceText(@"test");
    assert([text containsString:@"\"second_contact\""]);
    assert([text containsString:@"\"movement_confirmed\""]);
}

int main(void) {
    testTouchCounting();
    testIdentityBoundary();
    testOwnedIdentityTransfer();
    testMovementIncludesBreakFrame();
    testPhysicalMovementHysteresis();
    testRecognitionWindows();
    testIdentityRestartCannotBecomeSecondContact();
    testFirstTapClassification();
    testReplacementStateMachine();
    testOwnedReleaseOwnership();
    testStaleGenerationCannotReleaseNewDrag();
    testNativeEventPolicy();
    testDeviceSpecificDraggingPreferences();
    testSyntheticEventMetadata();
    testDiagnosticRing();
    return 0;
}
