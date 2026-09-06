#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <stddef.h>
#include <stdint.h>

// TapDragEngine owns all gesture state and event-tap resources. Its public
// operations keep state transitions atomic so callers cannot leave the raw
// device list, suspension gate, and gesture state machine out of sync.
typedef void *TDMTDeviceRef;
typedef int (*TDMTContactCallbackFunction)(TDMTDeviceRef, void *, int, double, int);
typedef BOOL (*TDMTDeviceIsBuiltInFunction)(TDMTDeviceRef);
typedef int (*TDMTDeviceGetSensorDimensionsFunction)(TDMTDeviceRef, int *, int *);

enum { TDMaximumMultitouchDevices = 16 };

typedef NS_ENUM(NSInteger, TDInputResetReason) {
    TDInputResetDisabled,
    TDInputResetNativeDragging,
    TDInputResetEventTapDisabled,
    TDInputResetSystemSuspended,
    TDInputResetSystemResumed,
    TDInputResetDeviceTopology,
    TDInputResetMultitouchUnavailable,
};

typedef struct {
    BOOL enabled;
    BOOL inputSuspended;
    BOOL multitouchReady;
    BOOL nativeDraggingEnabled;
    BOOL automaticLoggingEnabled;
    BOOL loggingActive;
    BOOL loggingFaulted;
    uint64_t diagnosticCount;
} TDGestureEngineStatus;

FOUNDATION_EXPORT NSString *const TDEnabledDefaultsKey;
FOUNDATION_EXPORT NSString *const TDAutomaticLoggingDefaultsKey;

void TDGestureEngineInitialize(void);
void TDGestureEngineShutdown(void);

TDGestureEngineStatus TDGestureEngineGetStatus(void);
void TDGestureEngineSetEnabled(BOOL enabled);
void TDGestureEngineSetAutomaticLoggingEnabled(BOOL enabled);
void TDGestureEngineSuspendInput(TDInputResetReason reason);
BOOL TDGestureEngineResumeInput(void);

BOOL TDGestureEngineInstallEventTaps(void);
BOOL TDGestureEngineEventTapsValid(void);
BOOL TDGestureEngineRefreshDraggingPreferences(void);

void TDGestureEngineConfigureMultitouch(
    TDMTDeviceIsBuiltInFunction deviceIsBuiltIn,
    TDMTDeviceGetSensorDimensionsFunction sensorDimensions);
BOOL TDGestureEngineShouldUseMultitouchDevice(TDMTDeviceRef device);
void TDGestureEngineSetMultitouchDevices(const TDMTDeviceRef *devices,
                                         size_t count);
int TDGestureEngineContactFrameCallback(TDMTDeviceRef device, void *contacts,
                                        int contactCount, double timestamp,
                                        int frame);

NSString *TDGestureEngineDiagnosticText(NSString *capture);
NSURL *TDGestureEngineDiagnosticDirectoryURL(void);
void TDGestureEngineClearDiagnostics(void);
