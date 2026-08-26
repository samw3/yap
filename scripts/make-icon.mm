// Generates bundle/Yap.icns. Original artwork drawn with Core Graphics -- the
// menu-bar glyph is an SF Symbol, and Apple's SF Symbols license does not permit
// using those in an app icon, so the shape here is hand-built to echo it rather
// than reuse it.
//
// Every size is drawn natively rather than downsampled from one raster: at 16 and
// 32 px a scaled-down 1024 px drawing turns to mush, and the small sizes are what
// Finder, Login Items and the Privacy panes actually show.
#import <AppKit/AppKit.h>
#include <cmath>

// macOS icon geometry, from Apple's 1024 px template: the rounded square is
// 824 px on a side, centered, with a corner radius of 185.4 px.
static const CGFloat kContentRatio = 824.0 / 1024.0;

// Apple's icon corners are a continuous curve, not a circular arc. A superellipse
// at n = 5 gives an effective corner radius of ~0.21 of the width, within a hair
// of the template's 185.4/824 = 0.225, and avoids the flat-then-kink transition a
// plain rounded rect shows at 512 px and up.
static NSBezierPath * squircle(NSRect r) {
    const CGFloat n  = 5.0;
    const CGFloat a  = r.size.width  / 2.0;
    const CGFloat b  = r.size.height / 2.0;
    const CGFloat cx = NSMidX(r), cy = NSMidY(r);

    NSBezierPath * p = [NSBezierPath bezierPath];
    const int steps = 1440;
    for (int i = 0; i <= steps; ++i) {
        const CGFloat t  = (CGFloat) i / steps * 2.0 * M_PI;
        const CGFloat ct = std::cos(t), st = std::sin(t);
        // Signed superellipse: |x/a|^n + |y/b|^n = 1
        const CGFloat x = cx + a * std::copysign(std::pow(std::fabs(ct), 2.0 / n), ct);
        const CGFloat y = cy + b * std::copysign(std::pow(std::fabs(st), 2.0 / n), st);
        if (i == 0) [p moveToPoint:NSMakePoint(x, y)];
        else        [p lineToPoint:NSMakePoint(x, y)];
    }
    [p closePath];
    return p;
}

// A head-and-shoulders silhouette with speech arcs leaving the mouth. Drawn in a
// unit square and transformed into place, so every number below reads as a
// fraction of the tile and the layout can be tuned without touching the geometry.
//
// The speech arcs are chosen per size rather than scaled, because the small sizes
// are not merely smaller -- they have a pixel budget:
//
//   >= 48 px  two fine arcs, the full mark
//      32 px  one arc, thin and pushed out so it reads as a wave, not a bracket
//      16 px  no arc at all. Head, shoulders and a wave inside 13 usable pixels
//             is mush; a clean silhouette is not, and every place macOS shows a
//             16 px icon prints the app's name beside it.
//
// With no arc the figure no longer needs room on its right, so it also recenters.
static void draw_glyph(NSRect content, int px) {
    const int     arcs     = (px >= 48) ? 2 : (px >= 24 ? 1 : 0);
    const CGFloat figScale = arcs == 0 ? 1.38 : (arcs == 1 ? 1.06 : 1.12);
    const CGFloat lw       = arcs == 2 ? 0.056 : 0.050;
    const CGFloat r0       = arcs == 2 ? 0.155 : 0.240;
    const CGFloat span     = arcs == 2 ? 42.0 : 38.0;     // half-angle, degrees
    const CGFloat cx       = arcs == 0 ? 0.500 : 0.430;   // the figure's axis
    // The figure's mass sits below the tile's center, so scaling it up drags it
    // downward. Lift it back when there is no arc holding the eye up and right.
    const CGFloat dy       = arcs == 0 ? 0.035 : 0.0;

    [NSGraphicsContext saveGraphicsState];

    NSAffineTransform * t = [NSAffineTransform transform];
    [t translateXBy:content.origin.x yBy:content.origin.y];
    [t scaleBy:content.size.width];
    // Grow the figure about the tile's center. Line widths scale with the CTM, so
    // they stay proportional.
    [t translateXBy:0.5 yBy:0.5 + dy];
    [t scaleBy:figScale];
    [t translateXBy:-0.5 yBy:-0.5];
    [t concat];

    [[NSColor whiteColor] setFill];
    [[NSColor whiteColor] setStroke];

    const CGFloat headR = 0.105, headY = 0.575;
    const CGFloat domeR = 0.175, domeY = 0.275, bodyBottom = 0.235;

    [[NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(cx - headR, headY - headR, headR * 2, headR * 2)] fill];

    // Shoulders: flat bottom, semicircular top. clockwise:YES matters -- going
    // counterclockwise from 180 degrees travels under the center instead of over
    // it, which turns the silhouette into a bowl and reads as a grin.
    NSBezierPath * body = [NSBezierPath bezierPath];
    [body moveToPoint:NSMakePoint(cx - domeR, bodyBottom)];
    [body lineToPoint:NSMakePoint(cx - domeR, domeY)];
    [body appendBezierPathWithArcWithCenter:NSMakePoint(cx, domeY) radius:domeR
                                 startAngle:180 endAngle:0 clockwise:YES];
    [body lineToPoint:NSMakePoint(cx + domeR, bodyBottom)];
    [body closePath];
    [body fill];

    // Speech: concentric arcs opening to the right of the mouth, round-capped.
    const NSPoint mouth = NSMakePoint(cx + headR * 0.55, headY);
    for (int i = 0; i < arcs; ++i) {
        NSBezierPath * a = [NSBezierPath bezierPath];
        [a appendBezierPathWithArcWithCenter:mouth radius:r0 + 0.088 * i
                                 startAngle:-span endAngle:span clockwise:NO];
        a.lineWidth    = lw;
        a.lineCapStyle = NSLineCapStyleRound;
        [a stroke];
    }

    [NSGraphicsContext restoreGraphicsState];
}

static NSData * render(int px) {
    const CGFloat S = px;
    NSBitmapImageRep * rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:px pixelsHigh:px
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:
        [NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];

    const CGFloat C  = S * kContentRatio;
    const CGFloat x0 = (S - C) / 2.0;
    // Nudged up so the baked-in shadow has somewhere to fall.
    const CGFloat y0 = (S - C) / 2.0 + S * 0.012;
    NSRect content = NSMakeRect(x0, y0, C, C);
    NSBezierPath * shape = squircle(content);

    // Shadow under the tile, the way macOS app icons carry one. Skipped below
    // 64 px, where the blur lands inside a pixel and only fuzzes the edge.
    if (px >= 64) {
    [NSGraphicsContext saveGraphicsState];
    NSShadow * sh = [[NSShadow alloc] init];
    sh.shadowColor  = [NSColor colorWithWhite:0 alpha:0.30];
    sh.shadowOffset = NSMakeSize(0, -S * 0.014);
    sh.shadowBlurRadius = S * 0.028;
    [sh set];
    [[NSColor blackColor] setFill];
    [shape fill];
    [NSGraphicsContext restoreGraphicsState];
    }

    // Body gradient: lighter at the top, as if lit from above.
    NSGradient * g = [[NSGradient alloc] initWithColorsAndLocations:
        [NSColor colorWithSRGBRed:0.494 green:0.427 blue:1.000 alpha:1.0], 0.0,
        [NSColor colorWithSRGBRed:0.396 green:0.294 blue:0.929 alpha:1.0], 0.55,
        [NSColor colorWithSRGBRed:0.310 green:0.180 blue:0.796 alpha:1.0], 1.0, nil];
    [g drawInBezierPath:shape angle:-90];

    // Faint top highlight for a little depth. Skipped when tiny: at 16 px it just
    // lightens the whole tile and costs contrast against the glyph.
    if (px >= 64) {
        [NSGraphicsContext saveGraphicsState];
        [shape addClip];
        NSGradient * hl = [[NSGradient alloc] initWithStartingColor:
            [NSColor colorWithWhite:1.0 alpha:0.20] endingColor:
            [NSColor colorWithWhite:1.0 alpha:0.0]];
        [hl drawInRect:NSMakeRect(x0, y0 + C * 0.55, C, C * 0.45) angle:-90];
        [NSGraphicsContext restoreGraphicsState];
    }

    draw_glyph(content, px);

    [NSGraphicsContext restoreGraphicsState];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

int main(int argc, char ** argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: %s <out.iconset-dir>\n", argv[0]); return 2; }
        NSString * dir = @(argv[1]);
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                 withIntermediateDirectories:YES attributes:nil error:nil];
        // Exactly the set iconutil expects for a complete .icns.
        const struct { int pt; int scale; } want[] = {
            {16,1},{16,2},{32,1},{32,2},{128,1},{128,2},{256,1},{256,2},{512,1},{512,2},
        };
        for (const auto & w : want) {
            const int px = w.pt * w.scale;
            NSString * name = w.scale == 1
                ? [NSString stringWithFormat:@"icon_%dx%d.png", w.pt, w.pt]
                : [NSString stringWithFormat:@"icon_%dx%d@2x.png", w.pt, w.pt];
            NSData * png = render(px);
            [png writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES];
            fprintf(stderr, "  %-22s %4d px\n", name.UTF8String, px);
        }
    }
    return 0;
}
