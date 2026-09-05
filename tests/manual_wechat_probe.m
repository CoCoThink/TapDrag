// Integration probe for the known, unsent test draft. Never sends keyboard input.
#define main tapDragApplicationMain
#include "../TapDrag/Sources/main.m"
#undef main

static id attribute(AXUIElementRef element, CFStringRef name) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

static void reportSelection(AXUIElementRef field) {
    id value = attribute(field, kAXSelectedTextRangeAttribute);
    CFRange range = CFRangeMake(-1, -1);
    if (value && CFGetTypeID((__bridge CFTypeRef)value) == AXValueGetTypeID())
        AXValueGetValue((__bridge AXValueRef)value, kAXValueCFRangeType, &range);
    printf("selection location=%ld length=%ld\n", range.location, range.length);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        printf("post_access=%d listen_access=%d ax_access=%d\n", CGPreflightPostEventAccess(),
               CGPreflightListenEventAccess(), AXIsProcessTrusted());
        if ((argc < 2 || argc > 4) || (strcmp(argv[1], "inspect") &&
            strcmp(argv[1], "single-hid") && strcmp(argv[1], "double-hid") &&
            strcmp(argv[1], "buffered-hid"))) {
            fprintf(stderr, "usage: %s inspect|single-hid|double-hid|buffered-hid [click-state [gap-ms]]\n", argv[0]);
            return 2;
        }
        BOOL doubleClick = strncmp(argv[1], "double", 6) == 0;
        int clickState = argc >= 3 ? atoi(argv[2]) : 1;
        int firstClickGap = argc == 4 ? atoi(argv[3]) : 120;
        if (firstClickGap < 0 || firstClickGap > 2000) return 2;
        if (clickState < 0 || clickState > 2) return 2;
        NSRunningApplication *app = [NSRunningApplication runningApplicationsWithBundleIdentifier:
                                     @"com.tencent.xinWeChat"].firstObject;
        if (!app) return 3;
        pid_t frontPid = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        printf("front_pid=%d\n", frontPid);
        AXUIElementRef root = AXUIElementCreateApplication(app.processIdentifier);
        id focused = attribute(root, kAXFocusedUIElementAttribute);
        CFRelease(root);
        if (!focused || CFGetTypeID((__bridge CFTypeRef)focused) != AXUIElementGetTypeID()) return 4;
        AXUIElementRef field = (__bridge AXUIElementRef)focused;
        if (![attribute(field, CFSTR("AXIdentifier")) isEqual:@"chat_input_field"] ||
            ![attribute(field, kAXValueAttribute) isEqual:@"0123456789 abcdefghij"]) return 5;
        id positionValue = attribute(field, kAXPositionAttribute);
        id sizeValue = attribute(field, kAXSizeAttribute);
        CGPoint position = CGPointZero;
        CGSize size = CGSizeZero;
        if (!positionValue || !sizeValue ||
            !AXValueGetValue((__bridge AXValueRef)positionValue, kAXValueCGPointType, &position) ||
            !AXValueGetValue((__bridge AXValueRef)sizeValue, kAXValueCGSizeType, &size)) return 6;
        printf("pid=%d input=(%.0f,%.0f,%.0f,%.0f)\n", app.processIdentifier,
               position.x, position.y, size.width, size.height);
        reportSelection(field);
        if (!strcmp(argv[1], "inspect")) return 0;
        if (size.width < 180 || size.height < 40) return 7;
        CGPoint start = CGPointMake(position.x + 14, position.y + 18);
        int64_t windowNumber = 0;
        NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
        for (NSDictionary *window in windows) {
            if ([window[(__bridge NSString *)kCGWindowLayer] intValue] != 0) continue;
            CGRect bounds = CGRectZero;
            if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)
                window[(__bridge NSString *)kCGWindowBounds], &bounds) && CGRectContainsPoint(bounds, start)) {
                int hitPid = [window[(__bridge NSString *)kCGWindowOwnerPID] intValue];
                printf("hit_pid=%d\n", hitPid);
                if (hitPid != app.processIdentifier) return 10;
                windowNumber = [window[(__bridge NSString *)kCGWindowNumber] longLongValue];
                break;
            }
        }
        if (!windowNumber) return 11;
        printf("window=%lld\n", windowNumber);
        gSyntheticSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        if (!gSyntheticSource) return 8;
        CGEventSourceSetLocalEventsSuppressionInterval(gSyntheticSource, 0);
        if (!strcmp(argv[1], "buffered-hid")) {
            MTDeviceRef device = (MTDeviceRef)(uintptr_t)1;
            atomic_store(&gEnabled, true);
            atomic_store(&gWeChatPid, app.processIdentifier);
            atomic_store(&gInternalDraggingPresent, true);
            atomic_store(&gInternalDraggingEnabled, false);
            atomic_store(&gBluetoothDraggingPresent, false);
            gDeviceCount = 1;
            gDevices[0] = (DeviceState){.device = device, .firstTapPending = YES};
            CGEventRef firstDown = createTaggedEvent(kCGEventLeftMouseDown, start, 12344);
            CGEventRef firstUp = createTaggedEvent(kCGEventLeftMouseUp, start, 12344);
            CGEventSetIntegerValueField(firstDown, kCGEventTargetUnixProcessID, app.processIdentifier);
            if (!bufferWeChatTapButton(kCGEventLeftMouseDown, firstDown) ||
                !bufferWeChatTapButton(kCGEventLeftMouseUp, firstUp)) return 12;
            CFRelease(firstDown); CFRelease(firstUp);
            gChain = (DragChain){.generation = 100, .phase = DragPhaseStarting,
                .device = device, .start = start, .latest = start,
                .startValid = YES, .latestValid = YES};
            if (!startSyntheticDrag(device, 100, atomic_load(&gFeatureEpoch))) return 13;
            ChainSnapshot snapshot = chainSnapshot();
            for (int i = 1; i <= 35; ++i) {
                CGEventRef movement = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
                    CGPointMake(start.x + 4 * i, start.y), kCGMouseButtonLeft);
                postNativeMovementAsDrag(movement, snapshot);
                CFRelease(movement);
                usleep(15000);
                if (i % 5 == 0) { printf("drag_step=%d ", i); reportSelection(field); }
            }
            int64_t number = 0;
            CGPoint end = CGPointZero;
            if (requestRelease(100, &number, &end) == ReleaseCaller) {
                postUp(number, end, 100);
                finishRelease(100);
            }
            usleep(150000);
            reportSelection(field);
            CFRelease(gSyntheticSource);
            return 0;
        }
        void (^post)(CGEventRef) = ^(CGEventRef event) {
            CGEventPost(InputTapLocation, event);
        };
        if (doubleClick) {
            CGEventRef clickDown = createTaggedEvent(kCGEventLeftMouseDown, start, 12344);
            CGEventRef clickUp = createTaggedEvent(kCGEventLeftMouseUp, start, 12344);
            if (!clickDown || !clickUp) return 9;
            post(clickDown);
            post(clickUp);
            CFRelease(clickDown); CFRelease(clickUp);
            usleep((unsigned int)firstClickGap * 1000);
        }
        CGEventRef down = createTaggedEvent(kCGEventLeftMouseDown, start, 12345);
        CGEventRef up = createTaggedEvent(kCGEventLeftMouseUp,
                                        CGPointMake(start.x + 140, start.y), 12345);
        if (!down || !up) return 9;
        CGEventSetIntegerValueField(down, kCGMouseEventClickState, clickState);
        CGEventSetIntegerValueField(up, kCGMouseEventClickState, clickState);
        post(down);
        CFRelease(down);
        usleep(15000);
        printf("after_down "); reportSelection(field);
        for (int i = 1; i <= 35; ++i) {
            CGEventRef drag = createTaggedEvent(kCGEventLeftMouseDragged,
                                  CGPointMake(start.x + 4 * i, start.y), 12345);
            if (!drag) break;
            CGEventSetDoubleValueField(drag, kCGMouseEventPressure, 1);
            CGEventSetIntegerValueField(drag, kCGMouseEventClickState, clickState);
            post(drag);
            CFRelease(drag);
            usleep(15000);
            if (i % 5 == 0) {
                printf("drag_step=%d ", i); reportSelection(field);
            }
        }
        CGEventSetTimestamp(up, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
        post(up);
        CFRelease(up);
        CFRelease(gSyntheticSource);
        usleep(150000);
        reportSelection(field);
    }
    return 0;
}
