#import "AppDelegate.h"

#import "MultitouchManager.h"
#import "TapDragEngine.h"

#import <ServiceManagement/ServiceManagement.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface TDAppDelegate () <NSMenuDelegate, TDMultitouchManagerDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenuItem *enabledItem;
@property(nonatomic, strong) NSMenuItem *launchAtLoginItem;
@property(nonatomic, strong) NSMenuItem *loginApprovalItem;
@property(nonatomic, strong) NSMenuItem *gestureStatusItem;
@property(nonatomic, strong) NSMenuItem *diagnosticStatus;
@property(nonatomic, strong) NSMenuItem *accessibilityItem;
@property(nonatomic, strong) NSMenuItem *automaticLoggingItem;
@property(nonatomic, strong) NSTimer *configurationTimer;
@property(nonatomic, strong) TDMultitouchManager *multitouchManager;
@property(nonatomic, assign) BOOL systemAwake;
@property(nonatomic, assign) BOOL userSessionActive;
@property(nonatomic, assign) BOOL inputSessionActive;
- (void)resumeInputIfReady;
@end

@implementation TDAppDelegate

// Posting and listening are separate TCC capabilities. Both are required: the
// app observes native input and emits a complete replacement mouse transaction.
- (BOOL)hasInputAccess:(BOOL)prompt {
    BOOL post = CGPreflightPostEventAccess();
    BOOL listen = CGPreflightListenEventAccess();
    if (!prompt) return post && listen;
    if (!post) CGRequestPostEventAccess();
    if (!listen) CGRequestListenEventAccess();
    return CGPreflightPostEventAccess() && CGPreflightListenEventAccess();
}

- (void)updateLaunchAtLoginStatus {
    // SMAppService is the source of truth; no duplicate preference is stored.
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    switch (status) {
        case SMAppServiceStatusEnabled:
            self.launchAtLoginItem.state = NSControlStateValueOn;
            break;
        case SMAppServiceStatusRequiresApproval:
            self.launchAtLoginItem.state = NSControlStateValueMixed;
            break;
        case SMAppServiceStatusNotRegistered:
        case SMAppServiceStatusNotFound:
            self.launchAtLoginItem.state = NSControlStateValueOff;
            break;
    }
    self.loginApprovalItem.hidden =
        status != SMAppServiceStatusRequiresApproval;
}

- (void)openLoginItemsSettings:(id)sender {
    (void)sender;
    [SMAppService openSystemSettingsLoginItems];
}

- (void)toggleLaunchAtLogin:(id)sender {
    (void)sender;
    SMAppService *service = SMAppService.mainAppService;
    SMAppServiceStatus status = service.status;
    BOOL disable = status == SMAppServiceStatusEnabled ||
        status == SMAppServiceStatusRequiresApproval;
    NSError *error = nil;
    BOOL success = disable ? [service unregisterAndReturnError:&error]
                           : [service registerAndReturnError:&error];
    [self updateLaunchAtLoginStatus];
    if (!disable && service.status == SMAppServiceStatusRequiresApproval) {
        [self openLoginItemsSettings:nil];
    } else if (!success) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Launch at Login Could Not Be Updated";
        alert.informativeText = error.localizedDescription ?:
            @"macOS could not update the login item. Please try again.";
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Open Login Items Settings"];
        if ([alert runModal] == NSAlertSecondButtonReturn) {
            [self openLoginItemsSettings:nil];
        }
    }
}

- (void)updateStatus {
    [self updateLaunchAtLoginStatus];
    TDGestureEngineStatus status = TDGestureEngineGetStatus();
    if (self.gestureStatusItem) {
        NSString *title = @"TapDrag: Ready";
        if (!status.enabled) {
            title = @"TapDrag: Disabled";
        } else if (![self hasInputAccess:NO]) {
            title = @"TapDrag: Accessibility / Input Monitoring Required";
        } else if (status.inputSuspended) {
            title = status.multitouchReady
                ? @"TapDrag: Paused; event taps unavailable"
                : @"TapDrag: Paused; trackpad unavailable";
        } else if (status.nativeDraggingEnabled) {
            title = @"TapDrag: Inactive; turn off macOS trackpad dragging";
        }
        self.gestureStatusItem.title = title;
    }
    if (self.diagnosticStatus) {
        NSString *loggingStatus = @", memory only";
        if (status.loggingFaulted) {
            loggingStatus = @", write failed";
        } else if (status.loggingActive) {
            loggingStatus = @", auto saved";
        } else if (status.automaticLoggingEnabled) {
            loggingStatus = @", auto save paused";
        }
        self.diagnosticStatus.title = [NSString stringWithFormat:
            @"Diagnostics: %llu events%@", status.diagnosticCount,
            loggingStatus];
        self.automaticLoggingItem.state = status.automaticLoggingEnabled
            ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (NSMenuItem *)item:(NSString *)title action:(SEL)action menu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:action
                                           keyEquivalent:@""];
    item.target = self;
    [menu addItem:item];
    return item;
}

- (void)setupStatusItem {
    if (self.statusItem) return;
    self.statusItem = [[NSStatusBar systemStatusBar]
        statusItemWithLength:NSVariableStatusItemLength];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"hand.tap.fill"
                              accessibilityDescription:@"TapDrag"];
    if (image) {
        image.template = YES;
        self.statusItem.button.image = image;
    } else {
        self.statusItem.button.title = @"TD";
    }
    self.statusItem.button.toolTip = @"TapDrag";

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.delegate = self;
    self.enabledItem = [self item:@"Enabled"
                           action:@selector(toggleEnabled:) menu:menu];
    self.enabledItem.state = TDGestureEngineGetStatus().enabled;
    self.launchAtLoginItem = [self item:@"Launch at Login"
                                   action:@selector(toggleLaunchAtLogin:)
                                     menu:menu];
    self.loginApprovalItem = [self item:@"Approve Launch at Login..."
                                   action:@selector(openLoginItemsSettings:)
                                     menu:menu];
    self.loginApprovalItem.hidden = YES;
    self.gestureStatusItem = [self item:@"TapDrag: checking"
                                  action:nil menu:menu];
    self.gestureStatusItem.enabled = NO;

    NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:@"Diagnostics"
                                                  action:nil
                                           keyEquivalent:@""];
    NSMenu *diagnostics = [[NSMenu alloc] initWithTitle:@"Diagnostics"];
    self.automaticLoggingItem = [self item:@"Automatic Logging"
                                      action:@selector(toggleAutomaticLogging:)
                                        menu:diagnostics];
    self.diagnosticStatus = [self item:@"Diagnostics: 0 events"
                                 action:nil menu:diagnostics];
    self.diagnosticStatus.enabled = NO;
    [diagnostics addItem:[NSMenuItem separatorItem]];
    [self item:@"Copy Diagnostic Summary"
         action:@selector(copyDiagnostics:) menu:diagnostics];
    [self item:@"Export Diagnostic Trace..."
         action:@selector(exportDiagnostics:) menu:diagnostics];
    [self item:@"Reveal Automatic Diagnostic Logs"
         action:@selector(revealDiagnostics:) menu:diagnostics];
    [self item:@"Clear Diagnostic Trace"
         action:@selector(clearDiagnostics:) menu:diagnostics];
    root.submenu = diagnostics;
    [menu addItem:root];

    self.accessibilityItem = [self item:@"Accessibility Permission Required"
                                  action:@selector(requestAccessibility:)
                                    menu:menu];
    [self item:@"Hide Menu Bar Icon" action:@selector(hideStatusItem:)
           menu:menu];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                  action:@selector(terminate:)
                                           keyEquivalent:@"q"];
    quit.target = NSApp;
    [menu addItem:quit];
    self.statusItem.menu = menu;
    [self updateStatus];
}

- (void)toggleEnabled:(id)sender {
    (void)sender;
    BOOL enable = !TDGestureEngineGetStatus().enabled;
    if (enable) TDGestureEngineRefreshDraggingPreferences();
    if (enable && (![self hasInputAccess:YES] ||
        !TDGestureEngineInstallEventTaps())) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"TapDrag Was Not Enabled";
        alert.informativeText = @"Grant Accessibility and, if requested, Input Monitoring permission to this app, then try again.";
        [alert addButtonWithTitle:@"Open Accessibility Settings"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
                @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
        }
        return;
    }
    TDGestureEngineSetEnabled(enable);
    [NSUserDefaults.standardUserDefaults setBool:enable
                                           forKey:TDEnabledDefaultsKey];
    self.enabledItem.state = enable;
    [self updateStatus];
}

- (void)toggleAutomaticLogging:(id)sender {
    (void)sender;
    BOOL enabled = !TDGestureEngineGetStatus().automaticLoggingEnabled;
    TDGestureEngineSetAutomaticLoggingEnabled(enabled);
    [NSUserDefaults.standardUserDefaults setBool:enabled
                                           forKey:TDAutomaticLoggingDefaultsKey];
    [self updateStatus];
}

- (void)requestAccessibility:(id)sender {
    (void)sender;
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{
        (__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES
    });
}

- (void)copyDiagnostics:(id)sender {
    (void)sender;
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:TDGestureEngineDiagnosticText(@"manual_copy")
                  forType:NSPasteboardTypeString];
}

- (void)exportDiagnostics:(id)sender {
    (void)sender;
    NSSavePanel *panel = NSSavePanel.savePanel;
    panel.nameFieldStringValue = @"TapDrag-diagnostics.jsonl";
    UTType *type = [UTType typeWithFilenameExtension:@"jsonl"];
    if (type) panel.allowedContentTypes = @[type];
    if ([panel runModal] == NSModalResponseOK && panel.URL) {
        [TDGestureEngineDiagnosticText(@"manual_export")
            writeToURL:panel.URL atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
    }
}

- (void)revealDiagnostics:(id)sender {
    (void)sender;
    NSURL *url = TDGestureEngineDiagnosticDirectoryURL();
    [NSFileManager.defaultManager createDirectoryAtURL:url
                           withIntermediateDirectories:YES
                                            attributes:@{NSFilePosixPermissions: @(0700)}
                                                 error:nil];
    [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)clearDiagnostics:(id)sender {
    (void)sender;
    TDGestureEngineClearDiagnostics();
    [self updateStatus];
}

- (void)hideStatusItem:(id)sender {
    (void)sender;
    if (!self.statusItem) return;
    [NSStatusBar.systemStatusBar removeStatusItem:self.statusItem];
    self.statusItem = nil;
    self.enabledItem = nil;
    self.launchAtLoginItem = nil;
    self.loginApprovalItem = nil;
    self.automaticLoggingItem = nil;
    self.gestureStatusItem = nil;
    self.diagnosticStatus = nil;
    self.accessibilityItem = nil;
}

- (void)menuWillOpen:(NSMenu *)menu {
    if (menu != self.statusItem.menu) return;
    [self refreshRuntimeConfiguration:nil];
    BOOL trusted = AXIsProcessTrusted();
    self.accessibilityItem.title = trusted
        ? @"Accessibility Permission Granted"
        : @"Accessibility Permission Required";
    self.accessibilityItem.state = trusted;
    self.enabledItem.state = TDGestureEngineGetStatus().enabled;
    [self updateStatus];
}

- (void)refreshRuntimeConfiguration:(NSTimer *)timer {
    (void)timer;
    BOOL changed = TDGestureEngineRefreshDraggingPreferences();

    BOOL tapStateChanged = NO;
    TDGestureEngineStatus status = TDGestureEngineGetStatus();
    if (self.inputSessionActive && status.enabled &&
        !status.multitouchReady && [self.multitouchManager rebuildDevices]) {
        [self resumeInputIfReady];
        tapStateChanged = YES;
        status = TDGestureEngineGetStatus();
    }
    if (self.inputSessionActive && status.enabled &&
        !TDGestureEngineEventTapsValid()) {
        BOOL wasSuspended = status.inputSuspended;
        if (!wasSuspended) {
            TDGestureEngineSuspendInput(TDInputResetEventTapDisabled);
        }
        if (status.multitouchReady && [self hasInputAccess:NO] &&
            TDGestureEngineInstallEventTaps()) {
            TDGestureEngineResumeInput();
        }
        tapStateChanged = wasSuspended !=
            TDGestureEngineGetStatus().inputSuspended;
    }
    if (changed || tapStateChanged) [self updateStatus];
}

- (void)reconcileInputSession {
    BOOL shouldBeActive = self.systemAwake && self.userSessionActive;
    if (shouldBeActive == self.inputSessionActive) return;
    self.inputSessionActive = shouldBeActive;
    if (!shouldBeActive) {
        // Close the gate before stopping devices so late callbacks cannot begin
        // a gesture while macOS is suspending or switching the user session.
        TDGestureEngineSuspendInput(TDInputResetSystemSuspended);
        [self.multitouchManager stopDevices];
    } else {
        TDGestureEngineSuspendInput(TDInputResetSystemResumed);
        [self.multitouchManager rebuildDevices];
        TDGestureEngineRefreshDraggingPreferences();
        [self resumeInputIfReady];
    }
    [self updateStatus];
}

- (void)systemWillSleep:(NSNotification *)notification {
    (void)notification;
    self.systemAwake = NO;
    [self reconcileInputSession];
}

- (void)systemDidWake:(NSNotification *)notification {
    (void)notification;
    self.systemAwake = YES;
    [self reconcileInputSession];
}

- (void)userSessionDidResign:(NSNotification *)notification {
    (void)notification;
    self.userSessionActive = NO;
    [self reconcileInputSession];
}

- (void)userSessionDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    self.userSessionActive = YES;
    [self reconcileInputSession];
}

- (void)multitouchManagerTopologyDidChange:(TDMultitouchManager *)manager {
    if (!self.inputSessionActive) return;
    // Device references are private-framework objects. Suspend the engine while
    // the manager releases the old list and installs the new one.
    TDGestureEngineSuspendInput(TDInputResetDeviceTopology);
    [manager rebuildDevices];
    [self resumeInputIfReady];
    [self updateStatus];
}

- (void)resumeInputIfReady {
    TDGestureEngineStatus status = TDGestureEngineGetStatus();
    if (!status.enabled) {
        TDGestureEngineResumeInput();
        return;
    }
    if (!status.multitouchReady) {
        TDGestureEngineSuspendInput(TDInputResetMultitouchUnavailable);
        return;
    }
    if (![self hasInputAccess:NO]) return;
    if (!TDGestureEngineInstallEventTaps()) {
        TDGestureEngineSuspendInput(TDInputResetEventTapDisabled);
        return;
    }
    TDGestureEngineResumeInput();
}

- (void)startMultitouch {
    self.multitouchManager = [[TDMultitouchManager alloc]
        initWithDelegate:self];
    [self.multitouchManager start];
    [self resumeInputIfReady];
    [self updateStatus];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        TDEnabledDefaultsKey: @YES,
        TDAutomaticLoggingDefaultsKey: @YES,
    }];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.systemAwake = YES;
    self.userSessionActive = YES;
    self.inputSessionActive = YES;
    // Initialize event creation before enabling persisted state. Raw devices
    // are started afterward and are the final prerequisite for opening input.
    TDGestureEngineInitialize();
    TDGestureEngineSetAutomaticLoggingEnabled(
        [defaults boolForKey:TDAutomaticLoggingDefaultsKey]);
    TDGestureEngineRefreshDraggingPreferences();
    if ([defaults boolForKey:TDEnabledDefaultsKey] &&
        [self hasInputAccess:NO] &&
        TDGestureEngineInstallEventTaps()) {
        TDGestureEngineSetEnabled(YES);
    }
    [self setupStatusItem];
    [self startMultitouch];

    NSNotificationCenter *notifications =
        NSWorkspace.sharedWorkspace.notificationCenter;
    [notifications addObserver:self selector:@selector(systemWillSleep:)
                          name:NSWorkspaceWillSleepNotification object:nil];
    [notifications addObserver:self selector:@selector(systemDidWake:)
                          name:NSWorkspaceDidWakeNotification object:nil];
    [notifications addObserver:self selector:@selector(userSessionDidResign:)
                          name:NSWorkspaceSessionDidResignActiveNotification
                        object:nil];
    [notifications addObserver:self selector:@selector(userSessionDidBecomeActive:)
                          name:NSWorkspaceSessionDidBecomeActiveNotification
                        object:nil];
    self.configurationTimer = [NSTimer timerWithTimeInterval:1.0
        target:self selector:@selector(refreshRuntimeConfiguration:)
        userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.configurationTimer
                           forMode:NSRunLoopCommonModes];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender
                     hasVisibleWindows:(BOOL)flag {
    (void)sender;
    (void)flag;
    [self setupStatusItem];
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.configurationTimer invalidate];
    self.configurationTimer = nil;
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    // Shut down gesture ownership before unloading MultitouchSupport callbacks.
    TDGestureEngineShutdown();
    [self.multitouchManager invalidate];
    self.multitouchManager = nil;
}

@end
