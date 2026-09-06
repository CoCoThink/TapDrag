#import <Foundation/Foundation.h>

@class TDMultitouchManager;

// The delegate only coordinates application lifecycle. Raw frame delivery and
// device filtering go directly to TapDragEngine.
@protocol TDMultitouchManagerDelegate <NSObject>
- (void)multitouchManagerTopologyDidChange:(TDMultitouchManager *)manager;
@end

@interface TDMultitouchManager : NSObject

@property(nonatomic, weak) id<TDMultitouchManagerDelegate> delegate;

- (instancetype)initWithDelegate:(id<TDMultitouchManagerDelegate>)delegate;
- (void)start;
- (BOOL)rebuildDevices;
- (void)stopDevices;
- (void)invalidate;

@end
