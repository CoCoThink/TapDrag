#import "AppDelegate.h"

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        // A strong local keeps the delegate alive for the entire AppKit loop.
        NSApplication *app = NSApplication.sharedApplication;
        TDAppDelegate *delegate = [[TDAppDelegate alloc] init];
        app.delegate = delegate; [app run];
    }
    return 0;
}
