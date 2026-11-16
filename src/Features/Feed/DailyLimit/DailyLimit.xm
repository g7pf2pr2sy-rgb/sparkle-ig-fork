#import "../../../InstagramHeaders.h"
#import "../../../Utils.h"
#import "SPKDailyLimit.h"

// Daily Limit hooks. Every hook calls the original first and only changes the
// result while today's limit is reached, so with both toggles off (or before the
// limit) Instagram and Sparkle behave exactly as they do without this feature.

%group SPKDailyLimitHooks

// Home feed: the same data sources Sparkle's feed filtering hooks.
%hook IGMainFeedListAdapterDataSource
- (NSArray *)objectsForListAdapter:(id)arg1 {
    NSArray *objects = %orig;
    return SPKDailyLimitFilteredFeedObjects(objects, arg1);
}
%end

// Demangled name: IGMainFeedSwiftHelpers.IGMainFeedListAdapterDataSource_swift (IG 445+).
%hook _TtC22IGMainFeedSwiftHelpers37IGMainFeedListAdapterDataSource_swift
- (NSArray *)objectsForListAdapter:(id)arg1 {
    NSArray *objects = %orig;
    return SPKDailyLimitFilteredFeedObjects(objects, arg1);
}
%end

// Reels: every viewer (tab, Explore, profiles, feed, chats) is backed by these.
%hook IGSundialFeedDataSource
- (NSArray *)objectsForListAdapter:(id)arg1 {
    NSArray *objects = %orig;
    return SPKDailyLimitFilteredReelsObjects(objects, arg1);
}
%end

// Demangled name: IGSundialFeed.IGSundialFeedDataSource (IG <= 433)
%hook _TtC13IGSundialFeed23IGSundialFeedDataSource
- (NSArray *)objectsForListAdapter:(id)arg1 {
    NSArray *objects = %orig;
    return SPKDailyLimitFilteredReelsObjects(objects, arg1);
}
%end

// Demangled name: IGSundialFeedDataSource.IGSundialFeedDataSource (IG 434+)
%hook _TtC23IGSundialFeedDataSource23IGSundialFeedDataSource
- (NSArray *)objectsForListAdapter:(id)arg1 {
    NSArray *objects = %orig;
    return SPKDailyLimitFilteredReelsObjects(objects, arg1);
}
%end

%hook IGSundialFeedViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    SPKDailyLimitApplyToViewController(self, YES);
}

- (void)viewDidLayoutSubviews {
    %orig;
    SPKDailyLimitKeepOverlayInFront(self);
}
%end

// Explore: installed after Sparkle's Hide Explore Grid hooks, so these run after
// Sparkle has applied its own value and only override it while the limit holds.
%hook IGExploreGridViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    SPKDailyLimitApplyToViewController(self, YES);
}
%end

%hook IGExploreViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    SPKDailyLimitApplyToViewController(self, YES);
}
%end

%end

extern "C" void SPKInstallDailyLimitHooksIfEnabled(void) {
    if (!SPKDailyLimitShouldInstall())
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        %init(SPKDailyLimitHooks);
        [[SPKDailyLimitManager sharedManager] start];
    });
}
