#import "MultitouchManager.h"

#import "TapDragEngine.h"

#import <IOKit/IOKitLib.h>
#import <dlfcn.h>

typedef TDMTDeviceRef (*MTDeviceCreateDefaultFunction)(void);
typedef CFArrayRef (*MTDeviceCreateListFunction)(void);
typedef int (*MTRegisterContactFrameCallbackFunction)(
    TDMTDeviceRef, TDMTContactCallbackFunction);
typedef int (*MTDeviceStartFunction)(TDMTDeviceRef, int);
typedef int (*MTDeviceStopFunction)(TDMTDeviceRef);

@interface TDMultitouchManager ()
@property(nonatomic, strong) NSArray *deviceList;
@property(nonatomic, assign) void *frameworkHandle;
@property(nonatomic, assign) IONotificationPortRef hotplugPort;
@property(nonatomic, assign) io_iterator_t addedTrackpads;
@property(nonatomic, assign) io_iterator_t removedTrackpads;
@end

@implementation TDMultitouchManager {
    MTDeviceCreateDefaultFunction _createDefault;
    MTDeviceCreateListFunction _createList;
    MTRegisterContactFrameCallbackFunction _registerContactCallback;
    MTDeviceStartFunction _startDevice;
    MTDeviceStopFunction _stopDevice;
    BOOL _frameworkAvailable;
    BOOL _invalidated;
}

static void drainDeviceIterator(io_iterator_t iterator) {
    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        IOObjectRelease(service);
    }
}

static void topologyChanged(void *context, io_iterator_t iterator) {
    // IOKit requires notification iterators to be drained before the next
    // notification can be delivered.
    drainDeviceIterator(iterator);
    TDMultitouchManager *manager = (__bridge TDMultitouchManager *)context;
    [manager.delegate multitouchManagerTopologyDidChange:manager];
}

- (instancetype)initWithDelegate:(id<TDMultitouchManagerDelegate>)delegate {
    self = [super init];
    if (self) _delegate = delegate;
    return self;
}

- (BOOL)loadFramework {
    if (self.frameworkHandle) return _frameworkAvailable;
    self.frameworkHandle = dlopen(
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/A/MultitouchSupport",
        RTLD_LAZY);
    if (!self.frameworkHandle) return NO;

    // MultitouchSupport is private API, so resolve its ABI at runtime instead
    // of creating a hard load dependency that would prevent app startup.
    _createDefault = (MTDeviceCreateDefaultFunction)dlsym(
        self.frameworkHandle, "MTDeviceCreateDefault");
    _createList = (MTDeviceCreateListFunction)dlsym(
        self.frameworkHandle, "MTDeviceCreateList");
    _registerContactCallback = (MTRegisterContactFrameCallbackFunction)dlsym(
        self.frameworkHandle, "MTRegisterContactFrameCallback");
    _startDevice = (MTDeviceStartFunction)dlsym(
        self.frameworkHandle, "MTDeviceStart");
    _stopDevice = (MTDeviceStopFunction)dlsym(
        self.frameworkHandle, "MTDeviceStop");
    TDMTDeviceGetSensorDimensionsFunction sensorDimensions =
        (TDMTDeviceGetSensorDimensionsFunction)dlsym(
            self.frameworkHandle, "MTDeviceGetSensorDimensions");
    TDMTDeviceIsBuiltInFunction deviceIsBuiltIn =
        (TDMTDeviceIsBuiltInFunction)dlsym(self.frameworkHandle, "MTDeviceIsBuiltIn");

    _frameworkAvailable = (_createList || _createDefault) &&
        _registerContactCallback && _startDevice && _stopDevice;
    if (!_frameworkAvailable) return NO;
    TDGestureEngineConfigureMultitouch(deviceIsBuiltIn, sensorDimensions);
    return YES;
}

- (void)setupHotplugNotifications {
    if (self.hotplugPort) return;
    self.hotplugPort = IONotificationPortCreate(kIOMainPortDefault);
    if (!self.hotplugPort) return;
    CFRunLoopSourceRef source = IONotificationPortGetRunLoopSource(self.hotplugPort);
    if (source) {
        CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    }

    CFMutableDictionaryRef matching = IOServiceMatching("AppleMultitouchDevice");
    if (!matching) return;
    // IOServiceAddMatchingNotification consumes one dictionary reference per
    // registration. Retain once because the same matcher is registered twice.
    CFRetain(matching);
    kern_return_t added = IOServiceAddMatchingNotification(
        self.hotplugPort, kIOFirstMatchNotification, matching, topologyChanged,
        (__bridge void *)self, &_addedTrackpads);
    kern_return_t removed = IOServiceAddMatchingNotification(
        self.hotplugPort, kIOTerminatedNotification, matching, topologyChanged,
        (__bridge void *)self, &_removedTrackpads);
    if (added == KERN_SUCCESS) drainDeviceIterator(self.addedTrackpads);
    if (removed == KERN_SUCCESS) drainDeviceIterator(self.removedTrackpads);
}

- (void)teardownHotplugNotifications {
    if (self.addedTrackpads) {
        IOObjectRelease(self.addedTrackpads);
        self.addedTrackpads = IO_OBJECT_NULL;
    }
    if (self.removedTrackpads) {
        IOObjectRelease(self.removedTrackpads);
        self.removedTrackpads = IO_OBJECT_NULL;
    }
    if (self.hotplugPort) {
        IONotificationPortDestroy(self.hotplugPort);
        self.hotplugPort = NULL;
    }
}

- (void)start {
    [self rebuildDevices];
    if (_frameworkAvailable) [self setupHotplugNotifications];
}

- (void)stopDevices {
    // Remove devices from the engine first. A final callback racing with stop
    // then finds no state and cannot begin a new gesture.
    TDGestureEngineSetMultitouchDevices(NULL, 0);
    NSArray *devices = self.deviceList;
    if (devices && _stopDevice) {
        for (id value in devices) {
            _stopDevice((__bridge TDMTDeviceRef)value);
        }
    }
    self.deviceList = nil;
}

- (BOOL)rebuildDevices {
    if (_invalidated) return NO;
    if (![self loadFramework]) return NO;
    [self stopDevices];

    CFArrayRef discovered = _createList ? _createList() : NULL;
    CFMutableArrayRef active = CFArrayCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (!active) {
        if (discovered) CFRelease(discovered);
        return NO;
    }
    if (discovered) {
        for (CFIndex i = 0; i < CFArrayGetCount(discovered) &&
             CFArrayGetCount(active) < (CFIndex)TDMaximumMultitouchDevices; ++i) {
            TDMTDeviceRef device = (TDMTDeviceRef)CFArrayGetValueAtIndex(
                discovered, i);
            if (device && TDGestureEngineShouldUseMultitouchDevice(device)) {
                CFArrayAppendValue(active, device);
            }
        }
        CFRelease(discovered);
    }
    if (CFArrayGetCount(active) == 0 && _createDefault) {
        TDMTDeviceRef device = _createDefault();
        if (device) {
            if (TDGestureEngineShouldUseMultitouchDevice(device)) {
                CFArrayAppendValue(active, device);
            }
            CFRelease(device);
        }
    }
    if (CFArrayGetCount(active) == 0) {
        CFRelease(active);
        return NO;
    }

    // Keep the CF device objects alive while callbacks are registered. The
    // engine stores non-owning references; deviceList owns their lifetime.
    self.deviceList = CFBridgingRelease(active);
    TDMTDeviceRef devices[TDMaximumMultitouchDevices] = {0};
    NSUInteger count = self.deviceList.count;
    for (NSUInteger i = 0; i < count; ++i) {
        devices[i] = (__bridge TDMTDeviceRef)self.deviceList[i];
    }
    for (NSUInteger i = 0; i < count; ++i) {
        _registerContactCallback(devices[i], TDGestureEngineContactFrameCallback);
    }
    TDGestureEngineSetMultitouchDevices(devices, count);
    for (NSUInteger i = 0; i < count; ++i) {
        _startDevice(devices[i], 0);
    }
    TDGestureEngineRefreshDraggingPreferences();
    return YES;
}

- (void)invalidate {
    if (_invalidated) return;
    _invalidated = YES;
    [self teardownHotplugNotifications];
    [self stopDevices];
    TDGestureEngineConfigureMultitouch(NULL, NULL);
    if (self.frameworkHandle) {
        dlclose(self.frameworkHandle);
        self.frameworkHandle = NULL;
    }
    _createDefault = NULL;
    _createList = NULL;
    _registerContactCallback = NULL;
    _startDevice = NULL;
    _stopDevice = NULL;
    _frameworkAvailable = NO;
}

- (void)dealloc {
    [self invalidate];
}

@end
