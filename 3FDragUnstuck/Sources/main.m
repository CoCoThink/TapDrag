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
    BOOL rawFirstTapPending;
    double rawFirstTapStartedTimestamp;
} DeviceState;

typedef enum {
    DoubleTapDragAccessGranted,
    DoubleTapDragAccessNeedsAccessibility,
} DoubleTapDragAccessStatus;

typedef enum {
    DoubleTapReleaseOutcomeWaiting,
    DoubleTapReleaseOutcomeFirstTapCaptured,
    DoubleTapReleaseOutcomeSecondTouchTooShort,
    DoubleTapReleaseOutcomeMultiFinger,
    DoubleTapReleaseOutcomeFirstTapExpired,
    DoubleTapReleaseOutcomeOverrideHeld,
    DoubleTapReleaseOutcomePosted,
} DoubleTapReleaseOutcome;

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
static os_unfair_lock gStateLock = OS_UNFAIR_LOCK_INIT;
static DeviceState gDeviceStates[16];
static int gDeviceStateCount = 0;
static NSString *const ShiftOverrideEnabledKey = @"ShiftOverrideEnabled";
static NSString *const OverrideModifierKey = @"OverrideModifier";
static NSString *const DoubleTapDragReleaseEnabledKey = @"DoubleTapDragReleaseEnabled";
static NSString *const OverrideModifierShift = @"Shift";
static NSString *const OverrideModifierControl = @"Control";
static NSString *const OverrideModifierOption = @"Option";
static NSString *const OverrideModifierFn = @"Fn";
static const int64_t SyntheticThreeFingerMouseUpUserData = 0x334644334655504DLL;
static const int64_t SyntheticDoubleTapMouseUpUserData = 0x334644445455504DLL;
static const long long MinimumReleaseIntervalMillis = 80;
static const double MaximumTapDurationSeconds = 0.20;

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

static void postLeftMouseUpAtLocation(CGPoint location, int64_t userData) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source == NULL) {
        return;
    }

    CGEventRef event = CGEventCreateMouseEvent(source, kCGEventLeftMouseUp, location, kCGMouseButtonLeft);
    CFRelease(source);
    if (event == NULL) {
        return;
    }

    CGEventSetIntegerValueField(event, kCGEventSourceUserData, userData);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void postLeftMouseUpAtCurrentPointerWithUserData(int64_t userData) {
    CGEventRef current = CGEventCreate(NULL);
    if (current == NULL) {
        return;
    }

    CGPoint location = CGEventGetLocation(current);
    CFRelease(current);

    postLeftMouseUpAtLocation(location, userData);
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

static void resetRawCurrentTouchLocked(DeviceState *state) {
    state->rawTouchMade = NO;
    state->rawTouchInvalid = NO;
    state->rawTouchingFrames = 0;
    state->rawTouchStartedTimestamp = 0;
}

static void resetRawDoubleTapStateLocked(DeviceState *state) {
    resetRawCurrentTouchLocked(state);
    state->rawFirstTapPending = NO;
    state->rawFirstTapStartedTimestamp = 0;
}

static BOOL isActualTouchState(uint32_t touchState) {
    return touchState == MTTouchStateMakeTouch || touchState == MTTouchStateTouching;
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

    if (primaryTouch->state == MTTouchStateMakeTouch ||
        (!state->rawTouchMade && primaryTouch->state == MTTouchStateTouching)) {
        state->rawTouchMade = YES;
        state->rawTouchStartedTimestamp = timestamp;
    }
    if (state->rawTouchMade && primaryTouch->state == MTTouchStateTouching) {
        state->rawTouchingFrames++;
    }
}

static BOOL completeRawDoubleTapLocked(DeviceState *state, double completedTimestamp) {
    int touchingFrames = state->rawTouchingFrames;
    atomic_store(&gLastDoubleTapTouchingFrames, touchingFrames);

    if (state->rawTouchInvalid) {
        atomic_store(&gLastDoubleTapReleaseOutcome, DoubleTapReleaseOutcomeMultiFinger);
        resetRawDoubleTapStateLocked(state);
        return NO;
    }
    if (!state->rawTouchMade) {
        resetRawCurrentTouchLocked(state);
        return NO;
    }

    double touchStartedTimestamp = state->rawTouchStartedTimestamp;
    long long touchDurationMillis = MAX(0LL, (long long)((completedTimestamp - touchStartedTimestamp) * 1000.0));
    atomic_store(&gLastDoubleTapTouchDurationMillis, touchDurationMillis);
    BOOL previousTapIsRecent = state->rawFirstTapPending &&
        touchStartedTimestamp >= state->rawFirstTapStartedTimestamp &&
        touchStartedTimestamp - state->rawFirstTapStartedTimestamp <= (double)systemDoubleClickIntervalMillis() / 1000.0;
    BOOL isShortTap = touchDurationMillis <= (long long)(MaximumTapDurationSeconds * 1000.0);
    BOOL isLongSecondTouch = !isShortTap;

    if (previousTapIsRecent && isLongSecondTouch) {
        state->rawFirstTapPending = NO;
        state->rawFirstTapStartedTimestamp = 0;
        resetRawCurrentTouchLocked(state);
        return YES;
    }

    if (state->rawFirstTapPending && !previousTapIsRecent) {
        atomic_store(&gLastDoubleTapReleaseOutcome, DoubleTapReleaseOutcomeFirstTapExpired);
    }

    if (isShortTap) {
        state->rawFirstTapPending = YES;
        state->rawFirstTapStartedTimestamp = touchStartedTimestamp;
        atomic_store(&gLastDoubleTapReleaseOutcome,
                     previousTapIsRecent ? DoubleTapReleaseOutcomeSecondTouchTooShort : DoubleTapReleaseOutcomeFirstTapCaptured);
    } else {
        state->rawFirstTapPending = NO;
        state->rawFirstTapStartedTimestamp = 0;
    }

    resetRawCurrentTouchLocked(state);
    return NO;
}

static void resetDeviceTouchStatesLocked(void) {
    for (int i = 0; i < gDeviceStateCount; i++) {
        gDeviceStates[i].maxContacts = 0;
        gDeviceStates[i].contactCount = 0;
        resetRawDoubleTapStateLocked(&gDeviceStates[i]);
    }
}

static BOOL isDoubleTapDragReleaseEnabledForEpoch(unsigned long long epoch) {
    return atomic_load(&gEnabled) &&
           atomic_load(&gDoubleTapDragReleaseEnabled) &&
           atomic_load(&gDoubleTapDragReleaseEpoch) == epoch;
}

static int contactFrameCallback(MTDeviceRef device, void *contacts, int contactCount, double timestamp, int frame) {
    (void)frame;

    BOOL shouldPostThreeFinger = NO;
    BOOL shouldPostDoubleTap = NO;
    unsigned long long doubleTapEnableEpoch = 0;

    os_unfair_lock_lock(&gStateLock);
    DeviceState *state = deviceStateForDeviceLocked(device);

    if (state == NULL) {
        os_unfair_lock_unlock(&gStateLock);
        return 0;
    }

    if (!atomic_load(&gEnabled)) {
        state->maxContacts = 0;
        state->contactCount = 0;
        resetRawDoubleTapStateLocked(state);
        os_unfair_lock_unlock(&gStateLock);
        return 0;
    }

    if (contactCount > 0) {
        if (state->contactCount == 0) {
            state->maxContacts = 0;
            resetRawCurrentTouchLocked(state);
        }
        state->contactCount = contactCount;
        state->maxContacts = MAX(state->maxContacts, contactCount);
        if (atomic_load(&gDoubleTapDragReleaseEnabled)) {
            observeRawTouchFrameLocked(state, contacts, contactCount, timestamp);
        } else {
            resetRawDoubleTapStateLocked(state);
        }
        os_unfair_lock_unlock(&gStateLock);
        return 0;
    }

    if (state->contactCount == 0) {
        os_unfair_lock_unlock(&gStateLock);
        return 0;
    }

    int completedMaxContacts = state->maxContacts;
    shouldPostThreeFinger = completedMaxContacts == 3;
    if (atomic_load(&gDoubleTapDragReleaseEnabled) && completeRawDoubleTapLocked(state, timestamp)) {
        if (isOverrideModifierHeld()) {
            atomic_store(&gLastDoubleTapReleaseOutcome, DoubleTapReleaseOutcomeOverrideHeld);
        } else if (claimReleaseSlot(&gLastDoubleTapPostMillis)) {
            shouldPostDoubleTap = YES;
            doubleTapEnableEpoch = atomic_load(&gDoubleTapDragReleaseEpoch);
        }
    }
    state->maxContacts = 0;
    state->contactCount = 0;
    os_unfair_lock_unlock(&gStateLock);

    if (shouldPostThreeFinger && !isOverrideModifierHeld() &&
        claimReleaseSlot(&gLastThreeFingerPostMillis)) {
        postLeftMouseUpAtCurrentPointer();
    }

    if (shouldPostDoubleTap && isDoubleTapDragReleaseEnabledForEpoch(doubleTapEnableEpoch)) {
        postLeftMouseUpAtCurrentPointerWithUserData(SyntheticDoubleTapMouseUpUserData);
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
        [self doubleTapDragAccessStatusRequestingIfNeeded:NO] == DoubleTapDragAccessGranted) {
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
    atomic_store(&gDoubleTapDragReleaseEnabled, NO);
    atomic_fetch_add(&gDoubleTapDragReleaseEpoch, 1);
    os_unfair_lock_lock(&gStateLock);
    resetDeviceTouchStatesLocked();
    os_unfair_lock_unlock(&gStateLock);
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

- (DoubleTapDragAccessStatus)doubleTapDragAccessStatusRequestingIfNeeded:(BOOL)prompt {
    BOOL canPost = CGPreflightPostEventAccess();
    if (prompt && !canPost) {
        CGRequestPostEventAccess();
    }
    canPost = CGPreflightPostEventAccess();
    return canPost ? DoubleTapDragAccessGranted : DoubleTapDragAccessNeedsAccessibility;
}

- (NSString *)doubleTapDragAccessStatusTitle:(DoubleTapDragAccessStatus)status {
    switch (status) {
        case DoubleTapDragAccessGranted:
            return @"Double-Tap Drag: Event Posting Permission Granted";
        case DoubleTapDragAccessNeedsAccessibility:
            return @"Double-Tap Drag: Accessibility / Event Posting Required";
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
    (void)status;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Double-Tap Drag Fast Release Was Not Enabled";
    alert.informativeText = @"This build needs Accessibility permission to post the immediate mouse-up event. Grant permission to this exact app, then quit and reopen it. Rebuilding an ad-hoc-signed app can require granting permission again.";
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
        case DoubleTapReleaseOutcomeSecondTouchTooShort:
            return [NSString stringWithFormat:@"Double-Tap last: second touch too short (%lld ms, %d frames)", durationMillis, touchingFrames];
        case DoubleTapReleaseOutcomeMultiFinger:
            return @"Double-Tap last: ignored multi-finger touch";
        case DoubleTapReleaseOutcomeFirstTapExpired:
            return @"Double-Tap last: first tap expired";
        case DoubleTapReleaseOutcomeOverrideHeld:
            return @"Double-Tap last: native release kept (override held)";
        case DoubleTapReleaseOutcomePosted:
            return [NSString stringWithFormat:@"Double-Tap last: immediate mouse-up posted (%lld ms, %d frames)", durationMillis, touchingFrames];
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
