#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>   // CADisplayLink, for the front-guard below
#import "VVSFlipCardView.h"
#import "VVSVideoView.h"
#import "../common/VVSCommon.h"

// Concrete declarations so `self` inside each hook resolves UIViewController
// members (Logos only emits a bare @class forward decl otherwise). Any class
// SpringBoard drives through viewWillAppear:/viewDidAppear:/viewDidDisappear:
// is a UIViewController by definition -- those *are* UIViewController
// lifecycle callbacks -- so this is safe even where the exact private
// subclass hierarchy isn't independently confirmed.
@interface CSCoverSheetViewController : UIViewController
- (void)vvs_reload;
@end

@interface SBHomeScreenViewController : UIViewController
@end

// Defensive fallback: on some SpringBoard layouts the home screen's
// appearance is driven through SBIconController instead of (or alongside)
// SBHomeScreenViewController.
@interface SBIconController : UIViewController
@end

// Both wallpaper views live in the *fixed* wallpaper window (level -3) so they
// stay put while the cover sheet slides up on unlock.
static VVSFlipCardView *gFlip;
static VVSVideoView *gVideo;
static __weak UIView *gAnchor;

// --- SpringBoard-level visibility -----------------------------------------
// Motion/playback should run whenever *either* the lock screen or the home
// screen is what's actually on screen, and stop only once neither is. Just
// stopping on CSCoverSheetViewController's disappearance (the original
// approach) breaks the instant SpringBoard has more than one screen sharing
// the wallpaper window: unlocking makes the cover sheet disappear while the
// home screen is what's now showing underneath, so motion died right as it
// was needed -- that was bug #1 (the ~1-2s freeze on reaching home screen).
//
// Two independent booleans, OR'd together, are more robust here than a
// counter: they're idempotent, so if any single appear/disappear callback
// ever fires twice (or is missed) during the unlock transition's overlap,
// the state self-corrects on the next callback instead of drifting.
static BOOL gCoverSheetVisible = NO;
static BOOL gHomeScreenVisible = NO;

static BOOL VVSBool(NSString *key) {
    Boolean ok = false;
    Boolean v = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)key, kVVSPrefsAppID, &ok);
    return ok ? (BOOL)v : NO;
}
static BOOL VVSEnabled(void) {
    CFPreferencesAppSynchronize(kVVSPrefsAppID);
    return VVSBool(kVVSKeyEnabled);
}
static BOOL VVSVideoMode(void) {
    if (!VVSBool(kVVSKeyVideoEnabled)) return NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:VVSVideoPath()];
}

// The lock-screen wallpaper window — fixed during the unlock gesture.
static UIWindow *VVSWallpaperWindow(UIView *anyView) {
    UIWindowScene *scene = (UIWindowScene *)anyView.window.windowScene;
    if (!scene) return nil;
    UIWindow *fallback = nil;
    for (UIWindow *w in scene.windows) {
        NSString *cn = NSStringFromClass([w class]);
        if ([cn isEqualToString:@"_SBWallpaperSecureWindow"]) return w;
        if ([cn containsString:@"Wallpaper"] && w.windowLevel < 0) fallback = w;
    }
    return fallback;
}

static void VVSAddToWindow(UIView *v, UIWindow *wp) {
    if (v.superview != wp) { [v removeFromSuperview]; [wp addSubview:v]; }
    v.frame = wp.bounds;
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [wp bringSubviewToFront:v];
}

// --- Continuous front guard (bug #2) ---------------------------------------
// Dragging Notification Center / Control Center partway makes SpringBoard
// insert its own live-blur material above everything in the wallpaper
// window for the duration of the gesture -- that bumps our view down a slot
// and flashes the stock wallpaper underneath for a frame or two (the
// "shutter"/uncanny glitch). Rather than hard-code exactly which private
// class does that (fragile across iOS versions, and only confirmable with
// FLEX on-device), a CADisplayLink cheaply re-asserts our view as the
// frontmost subview every tick while it's running -- self-healing no matter
// what transiently jumps in front of it. NSRunLoopCommonModes keeps it
// ticking while the gesture's own tracking run loop mode is active, not
// just the default one, which is what a plain timer would miss.
@interface VVSFrontGuard : NSObject
+ (instancetype)shared;
- (void)start;
- (void)stop;
@end

static UIView *VVSActiveView(void) {
    if (gVideo && !gVideo.hidden && gVideo.hasVideo) return gVideo;
    if (gFlip  && !gFlip.hidden  && gFlip.hasContent) return gFlip;
    return nil;
}

@implementation VVSFrontGuard {
    CADisplayLink *_link;
}
+ (instancetype)shared {
    static VVSFrontGuard *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [VVSFrontGuard new]; });
    return s;
}
- (void)start {
    if (_link) return;   // already running
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(vvs_tick)];
    _link.preferredFramesPerSecond = 30;   // cheap poll -- doesn't need display refresh rate
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}
- (void)stop {
    [_link invalidate];
    _link = nil;
}
- (void)vvs_tick {
    UIView *active = VVSActiveView();
    UIWindow *wp = active.window;
    if (active && wp && wp.subviews.lastObject != active) {
        [wp bringSubviewToFront:active];
    }
}
@end

// Reactively starts/stops the guard based on whether anything is actually
// meant to be showing right now. Cheap and idempotent -- safe to call after
// every VVSApply branch instead of hand-tracking start/stop at each site.
static void VVSUpdateFrontGuardState(void) {
    if (VVSActiveView()) [[VVSFrontGuard shared] start];
    else                 [[VVSFrontGuard shared] stop];
}

static void VVSApply(UIView *anchorView) {
    if (anchorView) gAnchor = anchorView;

    if (!VVSEnabled()) {
        [gFlip stopMotion];  gFlip.hidden = YES;
        [gVideo pause];      gVideo.hidden = YES;
        VVSUpdateFrontGuardState();
        return;
    }

    UIWindow *wp = VVSWallpaperWindow(anchorView ?: gAnchor);
    if (!wp) { VVSUpdateFrontGuardState(); return; }

    if (VVSVideoMode()) {
        // --- video wallpaper wins ---
        [gFlip stopMotion]; gFlip.hidden = YES;
        if (!gVideo) gVideo = [[VVSVideoView alloc] initWithFrame:wp.bounds];
        else [gVideo reloadFromPreferences];
        if (!gVideo.hasVideo) { gVideo.hidden = YES; VVSUpdateFrontGuardState(); return; }
        gVideo.hidden = NO;
        VVSAddToWindow(gVideo, wp);
        [gVideo play];
        VVSUpdateFrontGuardState();
        return;
    }

    // --- photo flip-card mode ---
    [gVideo pause]; gVideo.hidden = YES;
    if (!gFlip) gFlip = [[VVSFlipCardView alloc] initWithFrame:wp.bounds];
    else [gFlip reloadFromPreferences];
    if (!gFlip.hasContent) { gFlip.hidden = YES; VVSUpdateFrontGuardState(); return; }
    gFlip.hidden = NO;
    VVSAddToWindow(gFlip, wp);
    [gFlip startMotion];
    VVSUpdateFrontGuardState();
}

static void VVSReloadCallback(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ VVSApply(nil); });
}

// Recomputes whether *any* SpringBoard screen we track is currently showing
// the wallpaper window, and starts/stops us accordingly. Called from both
// hook groups below so a lock-screen <-> home-screen handoff never has a gap
// where both flags read NO for even one runloop turn.
static void VVSRecomputeVisibility(UIView *anchorView) {
    BOOL anyVisible = gCoverSheetVisible || gHomeScreenVisible;
    if (anyVisible) {
        VVSApply(anchorView);
    } else {
        [gFlip stopMotion];
        [gVideo pause];
        [[VVSFrontGuard shared] stop];   // nothing on screen -- no point reordering
    }
}

%hook CSCoverSheetViewController

%new
- (void)vvs_reload { VVSApply(self.view); }

- (void)viewDidLoad {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, VVSReloadCallback, CFSTR(kVVSReloadNotification),
            NULL, CFNotificationSuspensionBehaviorCoalesce);
    });
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    gCoverSheetVisible = YES;
    VVSRecomputeVisibility(self.view);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    VVSApply(self.view);   // reassert z-order once the unlock transition settles
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    gCoverSheetVisible = NO;
    VVSRecomputeVisibility(self.view);
}

%end

%hook SBHomeScreenViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    gHomeScreenVisible = YES;
    VVSRecomputeVisibility(self.view);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    VVSApply(self.view);
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    gHomeScreenVisible = NO;
    VVSRecomputeVisibility(self.view);
}

%end

// Same three callbacks, different class -- see the SBIconController forward
// declaration up top for why this exists alongside SBHomeScreenViewController.
// Sets the *same* flag, so it's harmless if both classes exist and both fire.
%hook SBIconController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    gHomeScreenVisible = YES;
    VVSRecomputeVisibility(self.view);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    VVSApply(self.view);
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    gHomeScreenVisible = NO;
    VVSRecomputeVisibility(self.view);
}

%end
