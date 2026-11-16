#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Full-screen notice laid over a Reels screen once the daily limit is reached.
@interface SPKDailyLimitBlockedView : UIView

/// Shows a Close button for Reels screens that were pushed or presented, which
/// have no tab bar to leave through.
@property (nonatomic) BOOL showsCloseButton;
@property (nonatomic, copy, nullable) void (^closeHandler)(void);

@end

NS_ASSUME_NONNULL_END
