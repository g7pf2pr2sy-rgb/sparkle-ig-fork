#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Daily Limit: one shared timer for Home, Reels and Explore. Once the day's minutes
// are used up, the enabled toggles hide the feed and/or block Reels until local
// midnight, and the settings stay locked until then.

/// Hide Home posts, the stories tray and the Explore grid once the limit is reached.
FOUNDATION_EXPORT NSString *const kSPKPrefDailyLimitHideFeed;
/// Block Reels everywhere except a reel opened from a chat once the limit is reached.
FOUNDATION_EXPORT NSString *const kSPKPrefDailyLimitDisableReels;
/// Minutes per day, counted across Home, Reels and Explore together.
FOUNDATION_EXPORT NSString *const kSPKPrefDailyLimitMinutes;

/// Posted on the main thread whenever the blocked state changes (limit reached,
/// midnight reset).
FOUNDATION_EXPORT NSNotificationName const SPKDailyLimitStateDidChangeNotification;

@interface SPKDailyLimitManager : NSObject

+ (instancetype)sharedManager;

/// Starts the once-a-second usage timer. Safe to call more than once.
- (void)start;

/// Re-reads the preferences and applies the result right away, without adding time.
- (void)evaluateNow;

/// The limit is reached for today and the feed toggle was on when it was.
@property (nonatomic, readonly) BOOL feedBlocked;
/// The limit is reached for today and the Reels toggle was on when it was.
@property (nonatomic, readonly) BOOL reelsBlocked;
/// The limit is reached and something is being blocked; settings stay locked until midnight.
@property (nonatomic, readonly, getter=isLocked) BOOL locked;
/// Seconds counted today.
@property (nonatomic, readonly) NSTimeInterval usedSeconds;
/// The limit in force: the value captured when the limit was reached while locked,
/// otherwise the current preference.
@property (nonatomic, readonly) double limitMinutes;
/// Bumped on every state change, so views can tell whether they are up to date.
@property (nonatomic, readonly) NSUInteger stateGeneration;

/// "7 of 15 min", or "Limit reached" while locked.
- (NSString *)usageSummaryText;

@end

#ifdef __cplusplus
extern "C" {
#endif

/// Either toggle is on.
BOOL SPKDailyLimitFeatureEnabled(void);
/// The hooks are needed: a toggle is on, or today's lock is still in force.
BOOL SPKDailyLimitShouldInstall(void);

/// YES when `viewController` belongs to a chat: a Direct screen itself, a screen
/// pushed straight from a chat, or a screen presented over one.
BOOL SPKDailyLimitIsDirectContext(UIViewController *_Nullable viewController);

/// Main feed list objects with today's block applied.
NSArray *SPKDailyLimitFilteredFeedObjects(NSArray *objects, id _Nullable adapter);
/// Reels list objects with today's block applied.
NSArray *SPKDailyLimitFilteredReelsObjects(NSArray *objects, id _Nullable adapter);

/// Brings a Reels, Home or Explore screen in line with the current state. `force`
/// re-asserts the visual state even when the screen is already up to date.
void SPKDailyLimitApplyToViewController(UIViewController *_Nullable viewController, BOOL force);
/// Keeps the Reels block view on top and sized to its screen after a layout pass.
void SPKDailyLimitKeepOverlayInFront(UIViewController *_Nullable viewController);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
