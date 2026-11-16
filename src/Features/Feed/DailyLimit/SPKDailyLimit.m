#import "SPKDailyLimit.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

#import "SPKDailyLimitBlockedView.h"
#import "SPKStrings.h"
#import "../../../Settings/SPKSetting.h"
#import "../../../Shared/Account/SPKAccountManager.h"
#import "../../../Utils.h"

NSString *const kSPKPrefDailyLimitHideFeed = @"feed_daily_limit_hide_feed";
NSString *const kSPKPrefDailyLimitDisableReels = @"feed_daily_limit_disable_reels";
NSString *const kSPKPrefDailyLimitMinutes = @"feed_daily_limit_minutes";
NSNotificationName const SPKDailyLimitStateDidChangeNotification = @"SPKDailyLimitStateDidChangeNotification";

// Today's usage is kept outside Sparkle's preference prefixes on purpose: export,
// import and Reset All Settings never touch it, so none of them hands back used time.
static NSString *const kSPKDailyLimitStateKey = @"spk_daily_limit_state";

static const double kSPKDailyLimitDefaultMinutes = 15.0;
static const NSTimeInterval kSPKDailyLimitTickInterval = 1.0;
// Upper bound on the time one tick can add, so a stalled run loop or a resume from
// the background never books a large jump.
static const NSTimeInterval kSPKDailyLimitMaxTickCredit = 2.0;
static const NSUInteger kSPKDailyLimitSaveEveryTicks = 5;

static const void *kSPKDailyLimitAppliedGenerationKey = &kSPKDailyLimitAppliedGenerationKey;
static const void *kSPKDailyLimitOverlayKey = &kSPKDailyLimitOverlayKey;
static const void *kSPKDailyLimitHidExploreKey = &kSPKDailyLimitHidExploreKey;

#pragma mark - Preferences

static double SPKDailyLimitPreferenceMinutes(void) {
    double minutes = [SPKUtils getDoublePref:kSPKPrefDailyLimitMinutes];
    if (!(minutes > 0.0))
        minutes = kSPKDailyLimitDefaultMinutes;
    return MIN(minutes, 24.0 * 60.0);
}

BOOL SPKDailyLimitFeatureEnabled(void) {
    return [SPKUtils getBoolPref:kSPKPrefDailyLimitHideFeed] || [SPKUtils getBoolPref:kSPKPrefDailyLimitDisableReels];
}

#pragma mark - Screen classification

static NSString *SPKDailyLimitClassName(id object) {
    return object ? NSStringFromClass([object class]) : @"";
}

static BOOL SPKDailyLimitNameContains(id object, NSString *fragment) {
    return object && [SPKDailyLimitClassName(object) rangeOfString:fragment].location != NSNotFound;
}

// Tab containers answer for their selected tab, never for themselves.
static BOOL SPKDailyLimitIsTabContainer(UIViewController *viewController) {
    return [viewController respondsToSelector:@selector(selectedViewController)];
}

// Instagram's chat screens, ObjC or Swift (the mangled name carries the module).
static BOOL SPKDailyLimitIsDirectController(UIViewController *viewController) {
    return !SPKDailyLimitIsTabContainer(viewController) && SPKDailyLimitNameContains(viewController, @"IGDirect");
}

static BOOL SPKDailyLimitIsReelsController(UIViewController *viewController) {
    return SPKDailyLimitNameContains(viewController, @"SundialFeedViewController");
}

static BOOL SPKDailyLimitIsMainFeedController(UIViewController *viewController) {
    // Covers 410's IGMainFeedViewController and the 445+ ObjC/Swift twins.
    return SPKDailyLimitNameContains(viewController, @"MainFeedViewController");
}

static BOOL SPKDailyLimitIsExploreGridController(UIViewController *viewController) {
    return SPKDailyLimitNameContains(viewController, @"ExploreGridViewController");
}

static BOOL SPKDailyLimitIsExploreController(UIViewController *viewController) {
    return SPKDailyLimitNameContains(viewController, @"ExploreViewController");
}

// The child of `navigationController` that contains `viewController`.
static UIViewController *SPKDailyLimitNavigationHost(UIViewController *viewController, UINavigationController *navigationController) {
    UIViewController *host = viewController;
    while (host.parentViewController && host.parentViewController != navigationController)
        host = host.parentViewController;
    return host.parentViewController == navigationController ? host : nil;
}

// The outermost container of `viewController`: the window root, or the root of the
// presentation it sits in.
static UIViewController *SPKDailyLimitContainmentRoot(UIViewController *viewController) {
    UIViewController *root = viewController;
    while (root.parentViewController)
        root = root.parentViewController;
    return root;
}

// What the presenter was showing when it presented: the selected tab, the top of a
// navigation stack. Presenters of full-screen modals are off-window, so this walks
// containment rather than visibility.
static BOOL SPKDailyLimitPresenterShowsDirect(UIViewController *presenter, NSUInteger depth) {
    if (!presenter || depth > 8)
        return NO;

    if ([presenter isKindOfClass:[UINavigationController class]])
        return SPKDailyLimitPresenterShowsDirect(((UINavigationController *)presenter).topViewController, depth + 1);

    if (SPKDailyLimitIsTabContainer(presenter)) {
        id selected = ((id (*)(id, SEL))objc_msgSend)(presenter, @selector(selectedViewController));
        return [selected isKindOfClass:[UIViewController class]] && SPKDailyLimitPresenterShowsDirect(selected, depth + 1);
    }

    if (SPKDailyLimitIsDirectController(presenter))
        return YES;

    for (UIViewController *child in presenter.childViewControllers) {
        if (SPKDailyLimitPresenterShowsDirect(child, depth + 1))
            return YES;
    }
    return NO;
}

BOOL SPKDailyLimitIsDirectContext(UIViewController *viewController) {
    if (!viewController)
        return NO;

    for (UIViewController *controller = viewController; controller; controller = controller.parentViewController) {
        if (SPKDailyLimitIsDirectController(controller))
            return YES;
    }

    // Pushed: only the screen right below counts, so a reel reached from a chat
    // through a profile is not treated as a chat reel.
    UINavigationController *navigationController = viewController.navigationController;
    UIViewController *host = navigationController ? SPKDailyLimitNavigationHost(viewController, navigationController) : nil;
    if (host) {
        NSUInteger index = [navigationController.viewControllers indexOfObjectIdenticalTo:host];
        if (index != NSNotFound && index > 0)
            return SPKDailyLimitIsDirectController(navigationController.viewControllers[index - 1]);
    }

    // Presented (or the root of a presented stack): look at what it was presented over.
    UIViewController *presenter = SPKDailyLimitContainmentRoot(viewController).presentingViewController;
    return SPKDailyLimitPresenterShowsDirect(presenter, 0);
}

// Counted toward the limit: Home, Reels (outside chats) and Explore, including a
// post opened from the Explore grid.
static BOOL SPKDailyLimitIsCountedController(UIViewController *viewController) {
    if (SPKDailyLimitIsMainFeedController(viewController))
        return YES;
    if (SPKDailyLimitIsReelsController(viewController))
        return !SPKDailyLimitIsDirectContext(viewController);
    if (SPKDailyLimitIsExploreGridController(viewController) || SPKDailyLimitIsExploreController(viewController))
        return YES;
    if (SPKDailyLimitNameContains(viewController, @"ContextualFeedViewController") ||
        SPKDailyLimitNameContains(viewController, @"ChainingFeedViewController")) {
        UIViewController *stackRoot = viewController.navigationController.viewControllers.firstObject;
        return SPKDailyLimitNameContains(stackRoot, @"Explore");
    }
    return NO;
}

#pragma mark - Visible hierarchy

// A child counts as on screen when it covers a real share of the window. Tab and
// swipe containers can keep neighbouring screens in the window, off to the side.
static BOOL SPKDailyLimitViewIsOnScreen(UIView *view) {
    UIWindow *window = view.window;
    if (!window || view.hidden || view.alpha < 0.01)
        return NO;
    CGRect frame = [view convertRect:view.bounds toView:nil];
    CGRect visible = CGRectIntersection(frame, window.bounds);
    if (CGRectIsNull(visible) || CGRectIsEmpty(visible))
        return NO;
    CGFloat windowArea = CGRectGetWidth(window.bounds) * CGRectGetHeight(window.bounds);
    return windowArea > 0.0 && CGRectGetWidth(visible) * CGRectGetHeight(visible) >= windowArea * 0.25;
}

// frontmostOnly: a presentation hides what it covers, so only the frontmost screen
// is collected (what the user is looking at). Otherwise every screen in the window,
// covered or not, is collected (what has to be kept in line with the state).
static void SPKDailyLimitCollectControllers(UIViewController *viewController, BOOL frontmostOnly, NSMutableArray<UIViewController *> *collected, NSUInteger depth, NSUInteger *budget) {
    if (!viewController || depth > 24 || *budget == 0)
        return;
    (*budget)--;

    // -presentedViewController resolves through ancestors; only follow a
    // presentation this controller made itself.
    UIViewController *presented = viewController.presentedViewController;
    BOOL ownsPresentation = presented && !presented.isBeingDismissed && presented.presentingViewController == viewController;
    if (ownsPresentation && frontmostOnly) {
        SPKDailyLimitCollectControllers(presented, YES, collected, depth + 1, budget);
        return;
    }

    [collected addObject:viewController];
    if (ownsPresentation)
        SPKDailyLimitCollectControllers(presented, NO, collected, depth + 1, budget);

    for (UIViewController *child in viewController.childViewControllers) {
        if (child.isViewLoaded && SPKDailyLimitViewIsOnScreen(child.view))
            SPKDailyLimitCollectControllers(child, frontmostOnly, collected, depth + 1, budget);
    }
}

static NSArray<UIWindow *> *SPKDailyLimitForegroundWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;
        if (scene.activationState != UISceneActivationStateForegroundActive &&
            scene.activationState != UISceneActivationStateForegroundInactive)
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden && window.rootViewController)
                [windows addObject:window];
        }
    }
    return windows;
}

static UIWindow *SPKDailyLimitKeyWindow(void) {
    NSArray<UIWindow *> *windows = SPKDailyLimitForegroundWindows();
    for (UIWindow *window in windows) {
        if (window.isKeyWindow)
            return window;
    }
    return windows.firstObject;
}

static NSArray<UIViewController *> *SPKDailyLimitFrontmostControllers(void) {
    NSMutableArray<UIViewController *> *collected = [NSMutableArray array];
    NSUInteger budget = 300;
    SPKDailyLimitCollectControllers(SPKDailyLimitKeyWindow().rootViewController, YES, collected, 0, &budget);
    return collected;
}

static NSArray<UIViewController *> *SPKDailyLimitAllWindowControllers(void) {
    NSMutableArray<UIViewController *> *collected = [NSMutableArray array];
    for (UIWindow *window in SPKDailyLimitForegroundWindows()) {
        NSUInteger budget = 300;
        SPKDailyLimitCollectControllers(window.rootViewController, NO, collected, 0, &budget);
    }
    return collected;
}

#pragma mark - Lists

static void SPKDailyLimitPerformUpdates(id adapter) {
    SEL selector = @selector(performUpdatesAnimated:completion:);
    if ([adapter respondsToSelector:selector])
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(adapter, selector, NO, nil);
}

// Reloads the list adapters a screen holds, so a list that loaded before the hooks
// existed (or before the state changed) is filtered at once. Only ivars named like
// an adapter are read, which keeps unrelated (possibly unretained) ivars untouched.
static void SPKDailyLimitRefreshListAdapters(UIViewController *viewController) {
    static Class adapterClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        adapterClass = NSClassFromString(@"IGListAdapter");
    });
    if (!viewController || !adapterClass)
        return;

    for (Class cls = object_getClass(viewController); cls && cls != [UIViewController class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            const char *name = ivar_getName(ivars[i]);
            if (!type || type[0] != '@' || !name)
                continue;
            if (!strcasestr(name, "adapter"))
                continue;
            id value = object_getIvar(viewController, ivars[i]);
            if ([value isKindOfClass:adapterClass])
                SPKDailyLimitPerformUpdates(value);
        }
        free(ivars);
    }
}

static UIViewController *SPKDailyLimitAdapterViewController(id adapter) {
    SEL selector = @selector(viewController);
    if (![adapter respondsToSelector:selector])
        return nil;
    id viewController = ((id (*)(id, SEL))objc_msgSend)(adapter, selector);
    return [viewController isKindOfClass:[UIViewController class]] ? viewController : nil;
}

#pragma mark - Reels block view

static UIViewController *SPKDailyLimitPoppableHost(UIViewController *viewController) {
    UINavigationController *navigationController = viewController.navigationController;
    UIViewController *host = navigationController ? SPKDailyLimitNavigationHost(viewController, navigationController) : nil;
    if (!host)
        return nil;
    NSUInteger index = [navigationController.viewControllers indexOfObjectIdenticalTo:host];
    return (index != NSNotFound && index > 0) ? host : nil;
}

static BOOL SPKDailyLimitCanLeave(UIViewController *viewController) {
    if (SPKDailyLimitPoppableHost(viewController))
        return YES;
    return SPKDailyLimitContainmentRoot(viewController).presentingViewController != nil;
}

static void SPKDailyLimitLeave(UIViewController *viewController) {
    UIViewController *host = SPKDailyLimitPoppableHost(viewController);
    if (host) {
        UINavigationController *navigationController = host.navigationController;
        if (navigationController.topViewController == host) {
            [navigationController popViewControllerAnimated:YES];
        } else {
            [navigationController popToViewController:navigationController.viewControllers[[navigationController.viewControllers indexOfObjectIdenticalTo:host] - 1] animated:YES];
        }
        return;
    }
    UIViewController *root = SPKDailyLimitContainmentRoot(viewController);
    if (root.presentingViewController)
        [root dismissViewControllerAnimated:YES completion:nil];
}

static void SPKDailyLimitApplyReels(UIViewController *viewController) {
    if (!viewController.isViewLoaded)
        return;

    BOOL block = [SPKDailyLimitManager sharedManager].reelsBlocked && !SPKDailyLimitIsDirectContext(viewController);
    SPKDailyLimitBlockedView *overlay = objc_getAssociatedObject(viewController, kSPKDailyLimitOverlayKey);

    if (block) {
        if (!overlay) {
            overlay = [[SPKDailyLimitBlockedView alloc] initWithFrame:viewController.view.bounds];
            __weak UIViewController *weakController = viewController;
            overlay.closeHandler = ^{
                UIViewController *strongController = weakController;
                if (strongController)
                    SPKDailyLimitLeave(strongController);
            };
            objc_setAssociatedObject(viewController, kSPKDailyLimitOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        overlay.showsCloseButton = SPKDailyLimitCanLeave(viewController);
        overlay.frame = viewController.view.bounds;
        if (overlay.superview != viewController.view)
            [viewController.view addSubview:overlay];
        [viewController.view bringSubviewToFront:overlay];
    } else if (overlay) {
        [overlay removeFromSuperview];
        objc_setAssociatedObject(viewController, kSPKDailyLimitOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

void SPKDailyLimitKeepOverlayInFront(UIViewController *viewController) {
    if (!viewController || !viewController.isViewLoaded)
        return;
    SPKDailyLimitBlockedView *overlay = objc_getAssociatedObject(viewController, kSPKDailyLimitOverlayKey);
    if (!overlay || overlay.superview != viewController.view)
        return;
    if (!CGRectEqualToRect(overlay.frame, viewController.view.bounds))
        overlay.frame = viewController.view.bounds;
    if (viewController.view.subviews.lastObject != overlay)
        [viewController.view bringSubviewToFront:overlay];
}

#pragma mark - Explore

static UIView *SPKDailyLimitExploreShimmerView(UIViewController *viewController) {
    Ivar ivar = class_getInstanceVariable(object_getClass(viewController), "_shimmeringGridView");
    if (!ivar)
        return nil;
    id view = object_getIvar(viewController, ivar);
    return [view isKindOfClass:[UIView class]] ? view : nil;
}

// Restoring hands the view back to Sparkle's own Hide Explore Grid logic, so that
// setting keeps working exactly as before once the limit lifts.
static void SPKDailyLimitApplyExploreGrid(UIViewController *viewController) {
    if (!viewController.isViewLoaded)
        return;
    BOOL hidByLimit = [objc_getAssociatedObject(viewController, kSPKDailyLimitHidExploreKey) boolValue];
    if ([SPKDailyLimitManager sharedManager].feedBlocked) {
        viewController.view.hidden = YES;
        objc_setAssociatedObject(viewController, kSPKDailyLimitHidExploreKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (hidByLimit) {
        objc_setAssociatedObject(viewController, kSPKDailyLimitHidExploreKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SEL sparkleUpdate = @selector(spk_updateExploreGridVisibility);
        if ([viewController respondsToSelector:sparkleUpdate])
            ((void (*)(id, SEL))objc_msgSend)(viewController, sparkleUpdate);
        else
            viewController.view.hidden = [SPKUtils getBoolPref:@"interface_hide_explore_grid"];
    }
}

static void SPKDailyLimitApplyExploreShimmer(UIViewController *viewController) {
    UIView *shimmer = SPKDailyLimitExploreShimmerView(viewController);
    if (!shimmer)
        return;
    BOOL hidByLimit = [objc_getAssociatedObject(viewController, kSPKDailyLimitHidExploreKey) boolValue];
    if ([SPKDailyLimitManager sharedManager].feedBlocked) {
        shimmer.hidden = YES;
        objc_setAssociatedObject(viewController, kSPKDailyLimitHidExploreKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (hidByLimit) {
        objc_setAssociatedObject(viewController, kSPKDailyLimitHidExploreKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SEL sparkleUpdate = @selector(spk_updateExploreShimmerVisibility);
        if ([viewController respondsToSelector:sparkleUpdate])
            ((void (*)(id, SEL))objc_msgSend)(viewController, sparkleUpdate);
        else
            shimmer.hidden = [SPKUtils getBoolPref:@"interface_hide_explore_grid"];
    }
}

#pragma mark - Manager

@interface SPKDailyLimitManager ()
@property (nonatomic) NSTimeInterval nextMidnight;
@property (nonatomic, readwrite) NSTimeInterval usedSeconds;
@property (nonatomic) BOOL reached;
@property (nonatomic) BOOL snapshotHideFeed;
@property (nonatomic) BOOL snapshotDisableReels;
@property (nonatomic) double snapshotMinutes;
@property (nonatomic, readwrite) NSUInteger stateGeneration;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) CFTimeInterval lastTick;
@property (nonatomic) NSUInteger ticksSinceSave;
@property (nonatomic) BOOL dirty;
@property (nonatomic, strong) NSHashTable *adapters;
@property (nonatomic, strong) NSHashTable<UIViewController *> *touchedControllers;
@end

@implementation SPKDailyLimitManager

+ (instancetype)sharedManager {
    static SPKDailyLimitManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [SPKDailyLimitManager new];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (!self)
        return nil;
    _adapters = [NSHashTable weakObjectsHashTable];
    _touchedControllers = [NSHashTable weakObjectsHashTable];
    [self loadState];
    [self rollOverIfNeeded];
    return self;
}

#pragma mark State

- (void)loadState {
    NSDictionary *state = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSPKDailyLimitStateKey];
    if (![state isKindOfClass:[NSDictionary class]])
        return;
    _nextMidnight = [state[@"next_midnight"] respondsToSelector:@selector(doubleValue)] ? [state[@"next_midnight"] doubleValue] : 0.0;
    _usedSeconds = [state[@"used"] respondsToSelector:@selector(doubleValue)] ? MAX(0.0, [state[@"used"] doubleValue]) : 0.0;
    _reached = [state[@"reached"] respondsToSelector:@selector(boolValue)] && [state[@"reached"] boolValue];
    _snapshotHideFeed = [state[@"hide_feed"] respondsToSelector:@selector(boolValue)] && [state[@"hide_feed"] boolValue];
    _snapshotDisableReels = [state[@"disable_reels"] respondsToSelector:@selector(boolValue)] && [state[@"disable_reels"] boolValue];
    _snapshotMinutes = [state[@"minutes"] respondsToSelector:@selector(doubleValue)] ? [state[@"minutes"] doubleValue] : 0.0;
}

- (void)saveState {
    [[NSUserDefaults standardUserDefaults] setObject:@{
        @"next_midnight" : @(self.nextMidnight),
        @"used" : @(self.usedSeconds),
        @"reached" : @(self.reached),
        @"hide_feed" : @(self.snapshotHideFeed),
        @"disable_reels" : @(self.snapshotDisableReels),
        @"minutes" : @(self.snapshotMinutes)
    }
                                              forKey:kSPKDailyLimitStateKey];
    self.dirty = NO;
    self.ticksSinceSave = 0;
}

// Starts a new day once local midnight has passed. Returns YES when a block lifted.
// A clock set backwards never rolls the day over, so it cannot clear the lock.
- (BOOL)rollOverIfNeeded {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (self.nextMidnight > 0.0 && now < self.nextMidnight)
        return NO;

    BOOL wasLocked = self.reached && (self.snapshotHideFeed || self.snapshotDisableReels);
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *startOfDay = [calendar startOfDayForDate:[NSDate dateWithTimeIntervalSinceReferenceDate:now]];
    NSDate *midnight = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:startOfDay options:0];
    self.nextMidnight = midnight ? midnight.timeIntervalSinceReferenceDate : startOfDay.timeIntervalSinceReferenceDate + 24.0 * 60.0 * 60.0;
    self.usedSeconds = 0.0;
    self.reached = NO;
    self.snapshotHideFeed = NO;
    self.snapshotDisableReels = NO;
    self.snapshotMinutes = 0.0;
    [self saveState];
    return wasLocked;
}

- (BOOL)isBeforeMidnight {
    return [NSDate timeIntervalSinceReferenceDate] < self.nextMidnight;
}

- (BOOL)isLocked {
    return self.reached && (self.snapshotHideFeed || self.snapshotDisableReels) && [self isBeforeMidnight];
}

- (BOOL)feedBlocked {
    return self.reached && self.snapshotHideFeed && [self isBeforeMidnight];
}

- (BOOL)reelsBlocked {
    return self.reached && self.snapshotDisableReels && [self isBeforeMidnight];
}

- (double)limitMinutes {
    if (self.isLocked && self.snapshotMinutes > 0.0)
        return self.snapshotMinutes;
    return SPKDailyLimitPreferenceMinutes();
}

- (NSString *)usageSummaryText {
    if (self.isLocked)
        return SPKL(@"FEED_DAILY_LIMIT_REACHED_VALUE");
    NSInteger usedMinutes = (NSInteger)floor(self.usedSeconds / 60.0);
    NSInteger limitMinutes = (NSInteger)llround(self.limitMinutes);
    return [NSString stringWithFormat:SPKL(@"FEED_DAILY_LIMIT_USED_TODAY_VALUE_FORMAT"), @(MIN(usedMinutes, limitMinutes)).stringValue, @(limitMinutes).stringValue];
}

#pragma mark Timer

- (void)start {
    if (self.timer)
        return;

    __weak SPKDailyLimitManager *weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:kSPKDailyLimitTickInterval
                                        repeats:YES
                                          block:^(NSTimer *timer) {
                                              [weakSelf tickCountingTime:YES];
                                          }];
    self.timer.tolerance = 0.2;
    // Common modes: the default mode pauses while a list is being scrolled.
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(applicationDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(applicationWillResignActive) name:UIApplicationWillResignActiveNotification object:nil];
    // Sparkle's Hide Explore Grid re-applies its own value on these; put the limit
    // back on top afterwards.
    [center addObserver:self selector:@selector(exploreVisibilityMayHaveReset) name:SPKHideExploreGridPreferenceDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(exploreVisibilityMayHaveReset) name:SPKAccountDidChangeNotification object:nil];

    self.lastTick = CACurrentMediaTime();
    [self stateDidChange];
}

- (void)applicationDidBecomeActive {
    self.lastTick = CACurrentMediaTime();
    [self tickCountingTime:NO];
}

- (void)applicationWillResignActive {
    [self tickCountingTime:YES];
    [self saveState];
}

- (void)exploreVisibilityMayHaveReset {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.feedBlocked)
            return;
        for (UIViewController *viewController in self.touchedControllers.allObjects) {
            if (SPKDailyLimitIsExploreGridController(viewController) || SPKDailyLimitIsExploreController(viewController))
                SPKDailyLimitApplyToViewController(viewController, YES);
        }
    });
}

- (void)evaluateNow {
    [self tickCountingTime:NO];
}

- (void)tickCountingTime:(BOOL)countTime {
    BOOL changed = [self rollOverIfNeeded];

    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval elapsed = self.lastTick > 0.0 ? now - self.lastTick : 0.0;
    self.lastTick = now;
    elapsed = MAX(0.0, MIN(elapsed, kSPKDailyLimitMaxTickCredit));

    BOOL enabled = SPKDailyLimitFeatureEnabled();
    BOOL active = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;

    if (countTime && enabled && !self.reached && active && elapsed > 0.0) {
        for (UIViewController *viewController in SPKDailyLimitFrontmostControllers()) {
            if (SPKDailyLimitIsCountedController(viewController)) {
                self.usedSeconds += elapsed;
                self.dirty = YES;
                break;
            }
        }
    }

    if (enabled && !self.reached && self.usedSeconds >= SPKDailyLimitPreferenceMinutes() * 60.0) {
        self.reached = YES;
        self.snapshotHideFeed = [SPKUtils getBoolPref:kSPKPrefDailyLimitHideFeed];
        self.snapshotDisableReels = [SPKUtils getBoolPref:kSPKPrefDailyLimitDisableReels];
        self.snapshotMinutes = SPKDailyLimitPreferenceMinutes();
        SPKLog(@"General", @"[Sparkle] Daily limit reached (feed: %d, reels: %d)", self.snapshotHideFeed, self.snapshotDisableReels);
        changed = YES;
    }

    if (changed) {
        [self stateDidChange];
        return;
    }

    // Screens that appear while blocked (a tab opened for the first time, a list
    // built before the hooks were installed) are brought in line here.
    if (active && (self.feedBlocked || self.reelsBlocked)) {
        for (UIViewController *viewController in SPKDailyLimitAllWindowControllers())
            SPKDailyLimitApplyToViewController(viewController, NO);
    }

    if (self.dirty && ++self.ticksSinceSave >= kSPKDailyLimitSaveEveryTicks)
        [self saveState];
}

- (void)stateDidChange {
    self.stateGeneration++;
    [self saveState];

    for (id adapter in self.adapters.allObjects)
        SPKDailyLimitPerformUpdates(adapter);
    for (UIViewController *viewController in self.touchedControllers.allObjects)
        SPKDailyLimitApplyToViewController(viewController, YES);
    for (UIViewController *viewController in SPKDailyLimitAllWindowControllers())
        SPKDailyLimitApplyToViewController(viewController, NO);

    [[NSNotificationCenter defaultCenter] postNotificationName:SPKDailyLimitStateDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:SPKSettingAccessoryTextDidChangeNotification object:nil];
}

- (void)noteAdapter:(id)adapter {
    if (adapter)
        [self.adapters addObject:adapter];
}

- (void)noteTouchedController:(UIViewController *)viewController {
    if (viewController)
        [self.touchedControllers addObject:viewController];
}

@end

#pragma mark - Hook entry points

BOOL SPKDailyLimitShouldInstall(void) {
    return SPKDailyLimitFeatureEnabled() || [SPKDailyLimitManager sharedManager].isLocked;
}

// Everything Home shows as content: the classes Sparkle's Hide Entire Feed and
// Hide Stories Tray remove, plus the suggestion, promotion and ad units its other
// feed filters know. Anything else (the feed's own chrome) is left in place.
static NSArray<Class> *SPKDailyLimitFeedContentClasses(void) {
    static NSArray<Class> *classes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<Class> *resolved = [NSMutableArray array];
        for (NSString *name in @[
                 @"IGPostCreationManager",
                 @"IGMedia",
                 @"IGFeedItem",
                 @"IGEndOfFeedDemarcatorModel",
                 @"IGSpinnerLabelViewModel",
                 @"IGStoryDataController",
                 @"IGFeedGroupHeaderViewModel",
                 @"IGFeedScrollableClipsModel",
                 @"IGHScrollAYMFModel",
                 @"IGBloksFeedUnitModel",
                 @"IGAdItem"
             ]) {
            Class cls = NSClassFromString(name);
            if (cls)
                [resolved addObject:cls];
        }
        Class inFeedStories = SPKResolveIGClass(@"IGInFeedStories.IGInFeedStoriesTrayModel", @"IGInFeedStoriesTrayModel");
        if (inFeedStories)
            [resolved addObject:inFeedStories];
        Class threadsInFeed = SPKResolveIGClass(@"IGThreadsInFeedModels.IGThreadsInFeedModel", nil);
        if (threadsInFeed)
            [resolved addObject:threadsInFeed];
        classes = [resolved copy];
    });
    return classes;
}

static BOOL SPKDailyLimitIsFeedContent(id object) {
    for (Class cls in SPKDailyLimitFeedContentClasses()) {
        if ([object isKindOfClass:cls])
            return YES;
    }
    return NO;
}

NSArray *SPKDailyLimitFilteredFeedObjects(NSArray *objects, id adapter) {
    SPKDailyLimitManager *manager = [SPKDailyLimitManager sharedManager];
    [manager noteAdapter:adapter];
    if (![objects isKindOfClass:[NSArray class]])
        return objects;

    BOOL hideFeed = manager.feedBlocked;
    BOOL hideReels = manager.reelsBlocked;
    if (!hideFeed && !hideReels)
        return objects;

    static Class mediaClass;
    static Class clipsCarouselClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mediaClass = NSClassFromString(@"IGMedia");
        clipsCarouselClass = NSClassFromString(@"IGFeedScrollableClipsModel");
    });

    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:objects.count];
    for (id object in objects) {
        if (hideFeed && SPKDailyLimitIsFeedContent(object))
            continue;
        // Feed left on, Reels blocked: drop the reels that play inline in Home.
        if (hideReels) {
            if (clipsCarouselClass && [object isKindOfClass:clipsCarouselClass])
                continue;
            if (mediaClass && [object isKindOfClass:mediaClass] && [object respondsToSelector:@selector(isClipsMedia)] && [(IGMedia *)object isClipsMedia])
                continue;
        }
        [kept addObject:object];
    }
    return [kept copy];
}

static BOOL SPKDailyLimitFrontmostReelsAreInChat(void) {
    for (UIViewController *viewController in SPKDailyLimitFrontmostControllers()) {
        if (SPKDailyLimitIsReelsController(viewController))
            return SPKDailyLimitIsDirectContext(viewController);
    }
    return NO;
}

NSArray *SPKDailyLimitFilteredReelsObjects(NSArray *objects, id adapter) {
    SPKDailyLimitManager *manager = [SPKDailyLimitManager sharedManager];
    [manager noteAdapter:adapter];
    if (!manager.reelsBlocked || ![objects isKindOfClass:[NSArray class]])
        return objects;

    UIViewController *owner = SPKDailyLimitAdapterViewController(adapter);
    BOOL inChat = owner ? SPKDailyLimitIsDirectContext(owner) : SPKDailyLimitFrontmostReelsAreInChat();
    if (!inChat)
        return @[];

    // A reel sent in a chat still opens, but the viewer cannot scroll on into
    // suggested reels: keep everything up to and including the first reel. If the
    // list holds no recognisable reel, leave it alone rather than risk the chat one.
    static Class mediaClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mediaClass = NSClassFromString(@"IGMedia");
    });
    if (!mediaClass)
        return objects;
    NSUInteger firstReel = [objects indexOfObjectPassingTest:^BOOL(id object, NSUInteger index, BOOL *stop) {
        return [object isKindOfClass:mediaClass];
    }];
    if (firstReel == NSNotFound)
        return objects;
    return [objects subarrayWithRange:NSMakeRange(0, firstReel + 1)];
}

void SPKDailyLimitApplyToViewController(UIViewController *viewController, BOOL force) {
    if (!viewController)
        return;

    BOOL isReels = SPKDailyLimitIsReelsController(viewController);
    BOOL isFeed = !isReels && SPKDailyLimitIsMainFeedController(viewController);
    BOOL isExploreGrid = !isReels && !isFeed && SPKDailyLimitIsExploreGridController(viewController);
    BOOL isExplore = !isReels && !isFeed && !isExploreGrid && SPKDailyLimitIsExploreController(viewController);
    if (!isReels && !isFeed && !isExploreGrid && !isExplore)
        return;

    SPKDailyLimitManager *manager = [SPKDailyLimitManager sharedManager];
    NSUInteger generation = manager.stateGeneration;
    NSNumber *applied = objc_getAssociatedObject(viewController, kSPKDailyLimitAppliedGenerationKey);
    BOOL upToDate = applied && applied.unsignedIntegerValue == generation;
    BOOL anyBlock = manager.feedBlocked || manager.reelsBlocked;

    // Never touched and nothing to block: leave the screen exactly as Instagram built it.
    if (!applied && !anyBlock)
        return;
    if (upToDate && !force)
        return;

    [manager noteTouchedController:viewController];

    if (isReels)
        SPKDailyLimitApplyReels(viewController);
    else if (isExploreGrid)
        SPKDailyLimitApplyExploreGrid(viewController);
    else if (isExplore)
        SPKDailyLimitApplyExploreShimmer(viewController);

    // Lists only need reloading when the state they were last filtered for changed.
    if (!upToDate && (isReels || isFeed))
        SPKDailyLimitRefreshListAdapters(viewController);

    objc_setAssociatedObject(viewController, kSPKDailyLimitAppliedGenerationKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
