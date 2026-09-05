#import <CoreGraphics/CoreGraphics.h>
static void capturePostedEvent(CGEventTapLocation location, CGEventRef event);
#define CGEventPost capturePostedEvent
#define main tapDragApplicationMain
#include "../TapDrag/Sources/main.m"
#undef main
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

static void testLoggingPolicy(void) {
    assert(!loggingShouldRun(NO, NO));
    assert(!loggingShouldRun(NO, YES));
    assert(!loggingShouldRun(YES, NO));
    assert(loggingShouldRun(YES, YES));
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

@interface TestRunningApplication : NSObject
@property(copy) NSString *bundleIdentifier;
@property(assign) pid_t processIdentifier;
@property(assign, getter=isTerminated) BOOL terminated;
@end
@implementation TestRunningApplication
@end

static void testPortCallback(CFMachPortRef port, void *message, CFIndex size, void *info) {
    (void)port; (void)message; (void)size; (void)info;
}

@interface TestWeChatDelegate : AppDelegate
@property(assign) int observerInstallCount;
@property(assign) pid_t lastObserverPid;
@property(assign) BOOL failObserver;
@end
@implementation TestWeChatDelegate
- (void)installTargetObserverForPid:(pid_t)pid {
    ++self.observerInstallCount;
    self.lastObserverPid = pid;
    if (self.failObserver) return;
    // A local port exercises lifecycle cleanup without installing a desktop tap.
    gTargetObserverTap = CFMachPortCreate(NULL, testPortCallback, NULL, NULL);
    assert(gTargetObserverTap);
    atomic_store(&gObservedTargetPid, pid);
}
@end

static void notifyTestApplication(AppDelegate *delegate, NSString *name,
                                  TestRunningApplication *app) {
    [delegate weChatApplicationChanged:[NSNotification notificationWithName:name
        object:nil userInfo:@{NSWorkspaceApplicationKey: app}]];
}

static void testWeChatFirstTapBuffer(void) {
    forceIdle();
    MTDeviceRef device = (MTDeviceRef)(uintptr_t)0x7779;
    DeviceState savedDevices[MaximumDevices];
    memcpy(savedDevices, gDevices, sizeof(gDevices));
    int savedCount = gDeviceCount;
    gDeviceCount = 1;
    gDevices[0] = (DeviceState){.device = device, .firstTapPending = YES};
    atomic_store(&gEnabled, true);
    atomic_store(&gWeChatPid, 23013);
    atomic_store(&gInternalDraggingPresent, true);
    atomic_store(&gInternalDraggingEnabled, false);
    atomic_store(&gBluetoothDraggingPresent, false);
    gSyntheticSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGPoint pointer = CGPointZero;
    assert(copyPointerLocation(&pointer));
    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown,
                                             pointer, kCGMouseButtonLeft);
    CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp,
                                           pointer, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(down, kCGEventTargetUnixProcessID, 23013);
    CGEventSetIntegerValueField(down, kCGMouseEventSubtype, NSEventSubtypeTouch);
    CGEventSetIntegerValueField(down, kCGMouseEventNumber, 77);
    CGEventSetIntegerValueField(up, kCGMouseEventNumber, 77);
    assert(clickBufferCallback(NULL, kCGEventLeftMouseDown, down, NULL) == NULL);
    assert(clickBufferCallback(NULL, kCGEventLeftMouseUp, up, NULL) == NULL);
    assert(postedEventCount == 0);
    unsigned long long token = gBufferedTapToken;
    expireBufferedTap(token);
    assert(postedEventCount == 2);
    assert(CGEventGetType(postedEvents[0]) == kCGEventLeftMouseDown);
    assert(CGEventGetType(postedEvents[1]) == kCGEventLeftMouseUp);
    assert(ownEvent(postedEvents[0]) && ownEvent(postedEvents[1]));
    expireBufferedTap(token);
    assert(postedEventCount == 2);
    clearPostedEvents();

    assert(bufferWeChatTapButton(kCGEventLeftMouseDown, down));
    assert(bufferWeChatTapButton(kCGEventLeftMouseUp, up));
    CGEventSetIntegerValueField(down, kCGMouseEventNumber, 78);
    CGEventSetIntegerValueField(up, kCGMouseEventNumber, 78);
    CGEventSetIntegerValueField(down, kCGMouseEventClickState, 2);
    assert(bufferWeChatTapButton(kCGEventLeftMouseDown, down));
    assert(bufferWeChatTapButton(kCGEventLeftMouseUp, up));
    assert(postedEventCount == 4);
    assert(CGEventGetIntegerValueField(postedEvents[2], kCGMouseEventClickState) == 2);
    assert(CGEventGetType(postedEvents[3]) == kCGEventLeftMouseUp);
    clearPostedEvents();

    assert(bufferWeChatTapButton(kCGEventLeftMouseDown, down));
    assert(bufferWeChatTapButton(kCGEventLeftMouseUp, up));
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
    assert(bufferWeChatTapButton(kCGEventLeftMouseDown, down));
    assert(bufferWeChatTapButton(kCGEventLeftMouseUp, up));
    expireBufferedTap(gBufferedTapToken);
    assert(postedEventCount == 3);
    assert(CGEventGetType(postedEvents[2]) == kCGEventMouseMoved);
    assert(CGPointEqualToPoint(CGEventGetLocation(postedEvents[2]), pointer));
    clearPostedEvents();

    CGEventSetIntegerValueField(down, kCGEventTargetUnixProcessID, 999);
    assert(!bufferWeChatTapButton(kCGEventLeftMouseDown, down));
    CGEventSetIntegerValueField(down, kCGEventTargetUnixProcessID, 23013);
    TestWeChatDelegate *delegate = [TestWeChatDelegate new];
    delegate.trackingWeChat = YES;
    TestRunningApplication *oldApp = [TestRunningApplication new];
    oldApp.bundleIdentifier = @"com.tencent.xinWeChat";
    oldApp.processIdentifier = 23013;
    oldApp.terminated = YES;
    assert(bufferWeChatTapButton(kCGEventLeftMouseDown, down));
    assert(bufferWeChatTapButton(kCGEventLeftMouseUp, up));
    token = gBufferedTapToken;
    notifyTestApplication(delegate, NSWorkspaceDidTerminateApplicationNotification, oldApp);
    assert(atomic_load(&gWeChatPid) == 0);
    assert(gBufferedTapDown == NULL && gBufferedTapUp == NULL);
    expireBufferedTap(token);
    assert(postedEventCount == 0);
    assert(!bufferWeChatTapButton(kCGEventLeftMouseDown, down));

    TestRunningApplication *newApp = [TestRunningApplication new];
    newApp.bundleIdentifier = @"com.tencent.xinWeChat";
    newApp.processIdentifier = 23014;
    notifyTestApplication(delegate, NSWorkspaceDidLaunchApplicationNotification, newApp);
    assert(atomic_load(&gWeChatPid) == 23014);
    assert(atomic_load(&gObservedTargetPid) == 23014);
    assert(delegate.lastObserverPid == 23014 && delegate.observerInstallCount == 1);
    assert(!bufferWeChatTapButton(kCGEventLeftMouseDown, down));
    CGEventSetIntegerValueField(down, kCGEventTargetUnixProcessID, 23014);
    assert(bufferWeChatTapButton(kCGEventLeftMouseDown, down));
    assert(bufferWeChatTapButton(kCGEventLeftMouseUp, up));
    token = gBufferedTapToken;
    notifyTestApplication(delegate, NSWorkspaceDidActivateApplicationNotification, newApp);
    notifyTestApplication(delegate, NSWorkspaceDidTerminateApplicationNotification, oldApp);
    notifyTestApplication(delegate, NSWorkspaceDidLaunchApplicationNotification, oldApp);
    assert(gBufferedTapToken == token && gBufferedTapDown);
    assert(atomic_load(&gWeChatPid) == 23014 && delegate.observerInstallCount == 1);

    TestRunningApplication *otherApp = [TestRunningApplication new];
    otherApp.bundleIdentifier = @"com.apple.finder";
    otherApp.processIdentifier = 42;
    notifyTestApplication(delegate, NSWorkspaceDidActivateApplicationNotification, otherApp);
    assert(atomic_load(&gWeChatPid) == 23014 && gBufferedTapToken == token);

    // A missed exit notification still requires clearing the old process's
    // pending click, and observer failure must not disable the new PID filter.
    newApp.processIdentifier = 23015;
    delegate.failObserver = YES;
    notifyTestApplication(delegate, NSWorkspaceDidLaunchApplicationNotification, newApp);
    assert(gBufferedTapDown == NULL && gTargetObserverTap == NULL);
    assert(atomic_load(&gWeChatPid) == 23015 && atomic_load(&gObservedTargetPid) == 0);
    expireBufferedTap(token);
    assert(postedEventCount == 0);
    CGEventSetIntegerValueField(down, kCGEventTargetUnixProcessID, 23015);
    assert(bufferWeChatTapButton(kCGEventLeftMouseDown, down));
    assert(bufferWeChatTapButton(kCGEventLeftMouseUp, up));
    token = gBufferedTapToken;
    delegate.failObserver = NO;
    notifyTestApplication(delegate, NSWorkspaceDidActivateApplicationNotification, newApp);
    assert(atomic_load(&gObservedTargetPid) == 23015);
    assert(delegate.observerInstallCount == 3 && gBufferedTapToken == token);
    [delegate stopTrackingWeChat];
    assert(atomic_load(&gWeChatPid) == 0 && atomic_load(&gObservedTargetPid) == 0);
    assert(gTargetObserverTap == NULL && gBufferedTapDown == NULL);
    notifyTestApplication(delegate, NSWorkspaceDidLaunchApplicationNotification, newApp);
    assert(atomic_load(&gWeChatPid) == 0);
    expireBufferedTap(token);
    assert(postedEventCount == 0);

    atomic_store(&gWeChatPid, 23013);
    CGEventSetIntegerValueField(down, kCGEventTargetUnixProcessID, 23013);
    atomic_store(&gInternalDraggingEnabled, true);
    assert(!bufferWeChatTapButton(kCGEventLeftMouseDown, down));
    CFRelease(down); CFRelease(up); CFRelease(gSyntheticSource);
    gSyntheticSource = NULL;
    atomic_store(&gEnabled, false);
    atomic_store(&gWeChatPid, 0);
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
    MTDeviceRef device = (MTDeviceRef)(uintptr_t)0x8888;
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
    clearRecords();
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
    // A leaked native move must be visible at both observer stages, but the
    // observers must neither consume it nor turn it into another drag.
    assert(downstreamObserverCallback(NULL, kCGEventMouseMoved, event, NULL) == event);
    assert(downstreamObserverCallback(NULL, kCGEventMouseMoved, event,
                                     (void *)(uintptr_t)1) == event);
    assert(CGEventGetType(event) == kCGEventMouseMoved);
    count = copyRecords(records, 8, NULL);
    assert(count == 5);
    assert(records[3].kind == DiagnosticDownstreamObserved);
    assert(records[4].kind == DiagnosticTargetObserved);
    assert(records[4].generation == chainSnapshot().generation);
    assert(records[4].eventType == kCGEventMouseMoved);
    downstreamObserverCallback(NULL, kCGEventTapDisabledByTimeout, NULL, NULL);
    assert(chainSnapshot().phase == DragPhaseOwned);
    atomic_store(&gEnabled, false);
    count = copyRecords(records, 8, NULL);
    downstreamObserverCallback(NULL, kCGEventLeftMouseUp, event, NULL);
    assert(copyRecords(records, 8, NULL) == count);
    CFRelease(event);
    forceIdle();
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
    testLoggingPolicy();
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
    testWeChatFirstTapBuffer();
    testSerializedDragTransaction();
    testDownstreamObserverDoesNotChangeOwnership();
    testDeviceSpecificDraggingPreferences();
    testSyntheticEventMetadata();
    testDiagnosticRing();
    return 0;
}
