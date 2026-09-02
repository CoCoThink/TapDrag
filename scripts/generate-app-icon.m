#import <AppKit/AppKit.h>

static NSColor *rgb(CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha) {
    return [NSColor colorWithCalibratedRed:red green:green blue:blue alpha:alpha];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        const NSInteger pixels = 1024;
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:pixels pixelsHigh:pixels
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:context];

        NSRect canvas = NSMakeRect(0, 0, pixels, pixels);
        [NSColor.clearColor setFill];
        NSRectFill(canvas);

        NSBezierPath *outer = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(52, 52, 920, 920)
                                                              xRadius:214 yRadius:214];
        NSShadow *outerShadow = [NSShadow new];
        outerShadow.shadowColor = [NSColor colorWithCalibratedWhite:0.02 alpha:0.42];
        outerShadow.shadowBlurRadius = 44;
        outerShadow.shadowOffset = NSMakeSize(0, -24);
        [outerShadow set];
        [[[NSGradient alloc] initWithColors:@[
            rgb(0.10, 0.08, 0.42, 1), rgb(0.10, 0.35, 0.94, 1), rgb(0.06, 0.75, 0.94, 1)
        ]] drawInBezierPath:outer angle:-48];

        [context saveGraphicsState];
        [outer addClip];
        NSBezierPath *glow = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(178, 514, 690, 570)];
        [rgb(0.35, 0.90, 1.0, 0.20) setFill];
        [glow fill];
        [context restoreGraphicsState];

        NSBezierPath *plate = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(186, 206, 652, 612)
                                                               xRadius:112 yRadius:112];
        NSShadow *plateShadow = [NSShadow new];
        plateShadow.shadowColor = [NSColor colorWithCalibratedWhite:0.02 alpha:0.34];
        plateShadow.shadowBlurRadius = 32;
        plateShadow.shadowOffset = NSMakeSize(0, -18);
        [plateShadow set];
        [[[NSGradient alloc] initWithColors:@[
            [NSColor colorWithCalibratedWhite:1 alpha:0.82], rgb(0.76, 0.88, 1.0, 0.58)
        ]] drawInBezierPath:plate angle:-70];
        [[NSColor colorWithCalibratedWhite:1 alpha:0.50] setStroke];
        plate.lineWidth = 8;
        [plate stroke];

        NSPoint tap = NSMakePoint(387, 645);
        const CGFloat diameters[] = {176, 116};
        const CGFloat alphas[] = {0.20, 0.42};
        const CGFloat widths[] = {14, 16};
        for (NSInteger i = 0; i < 2; i++) {
            CGFloat d = diameters[i];
            NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(tap.x - d / 2, tap.y - d / 2, d, d)];
            [rgb(0.05, 0.48, 0.98, alphas[i]) setStroke];
            ring.lineWidth = widths[i];
            [ring stroke];
        }
        [rgb(0.03, 0.42, 0.96, 0.92) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(tap.x - 29, tap.y - 29, 58, 58)] fill];

        NSShadow *arrowShadow = [NSShadow new];
        arrowShadow.shadowColor = rgb(0.02, 0.12, 0.40, 0.36);
        arrowShadow.shadowBlurRadius = 20;
        arrowShadow.shadowOffset = NSMakeSize(0, -10);
        [arrowShadow set];
        NSBezierPath *arrow = [NSBezierPath bezierPath];
        [arrow moveToPoint:NSMakePoint(462, 565)];
        [arrow curveToPoint:NSMakePoint(690, 360)
              controlPoint1:NSMakePoint(520, 520) controlPoint2:NSMakePoint(635, 420)];
        arrow.lineCapStyle = NSLineCapStyleRound;
        arrow.lineJoinStyle = NSLineJoinStyleRound;
        arrow.lineWidth = 62;
        [[NSColor colorWithCalibratedWhite:1 alpha:0.96] setStroke];
        [arrow stroke];
        NSBezierPath *head = [NSBezierPath bezierPath];
        [head moveToPoint:NSMakePoint(704, 335)];
        [head lineToPoint:NSMakePoint(578, 367)];
        [head lineToPoint:NSMakePoint(671, 459)];
        [head closePath];
        [[NSColor colorWithCalibratedWhite:1 alpha:0.96] setFill];
        [head fill];

        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSString *path = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"TapDrag/Resources/AppIcon.png";
        if (![png writeToFile:path atomically:YES]) return 1;
    }
    return 0;
}
