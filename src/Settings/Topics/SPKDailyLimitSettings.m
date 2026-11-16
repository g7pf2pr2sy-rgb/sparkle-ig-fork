#import "SPKStrings.h"
#import "SPKDailyLimitSettings.h"

#import "../../Features/Feed/DailyLimit/SPKDailyLimit.h"
#import "../SPKTopicSettingsSupport.h"

NSDictionary *SPKDailyLimitSettingsSection(void) {
    SPKDailyLimitManager *manager = [SPKDailyLimitManager sharedManager];

    // Once the limit is reached the rows lock until midnight. The block itself runs
    // on the values captured at that moment, so a change made anyway (an import, a
    // reset) cannot lift it early.
    BOOL (^unlocked)(void) = ^BOOL {
        return ![SPKDailyLimitManager sharedManager].isLocked;
    };

    SPKSetting *hideFeed = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_DAILY_LIMIT_HIDE_FEED_TITLE")
                                                                         icon:SPKSettingsIcon(@"feed")
                                                                  defaultsKey:kSPKPrefDailyLimitHideFeed],
                                              SPKL(@"FEED_DAILY_LIMIT_HIDE_FEED_HELP"));
    hideFeed.enabledProvider = unlocked;
    hideFeed.reloadsTableOnSwitchChange = YES;
    hideFeed.action = ^{
        [[SPKDailyLimitManager sharedManager] evaluateNow];
    };

    SPKSetting *disableReels = SPKSettingWithHelp([SPKSetting switchCellWithTitle:SPKL(@"FEED_DAILY_LIMIT_DISABLE_REELS_TITLE")
                                                                             icon:SPKSettingsIcon(@"reels")
                                                                      defaultsKey:kSPKPrefDailyLimitDisableReels],
                                                  SPKL(@"FEED_DAILY_LIMIT_DISABLE_REELS_HELP"));
    disableReels.enabledProvider = unlocked;
    disableReels.reloadsTableOnSwitchChange = YES;
    disableReels.action = ^{
        [[SPKDailyLimitManager sharedManager] evaluateNow];
    };

    // The stepper cannot be greyed out, so while locked it is swapped for a
    // read-only row showing the limit in force.
    SPKSetting *timeLimit = SPKSettingWithHelp([SPKSetting stepperCellWithTitle:SPKL(@"FEED_DAILY_LIMIT_TIME_LIMIT_TITLE")
                                                                       subtitle:SPKL(@"FEED_DAILY_LIMIT_TIME_LIMIT_SUBTITLE")
                                                                           icon:SPKSettingsIcon(@"clock")
                                                                    defaultsKey:kSPKPrefDailyLimitMinutes
                                                                            min:5
                                                                            max:180
                                                                           step:5
                                                                          label:SPKL(@"FEED_DAILY_LIMIT_MINUTES_LABEL")
                                                                  singularLabel:SPKL(@"FEED_DAILY_LIMIT_MINUTE_LABEL")],
                                               SPKL(@"FEED_DAILY_LIMIT_TIME_LIMIT_HELP"));
    timeLimit.hiddenProvider = ^BOOL {
        return [SPKDailyLimitManager sharedManager].isLocked;
    };

    NSString *lockedValue = [NSString stringWithFormat:SPKL(@"FEED_DAILY_LIMIT_LOCKED_VALUE_FORMAT"), @((NSInteger)llround(manager.limitMinutes)).stringValue];
    SPKSetting *lockedTimeLimit = [SPKSetting valueCellWithTitle:SPKL(@"FEED_DAILY_LIMIT_TIME_LIMIT_TITLE")
                                                        subtitle:lockedValue
                                                            icon:SPKSettingsIcon(@"lock")];
    lockedTimeLimit.hiddenProvider = ^BOOL {
        return ![SPKDailyLimitManager sharedManager].isLocked;
    };

    SPKSetting *usedToday = [SPKSetting buttonCellWithTitle:SPKL(@"FEED_DAILY_LIMIT_USED_TODAY_TITLE")
                                                   subtitle:nil
                                                       icon:SPKSettingsIcon(@"clock")
                                                     action:^{
                                                     }];
    usedToday.accessoryTextProvider = ^NSString * {
        return [[SPKDailyLimitManager sharedManager] usageSummaryText];
    };
    usedToday.userInfo = @{@"hidesDisclosure" : @YES};
    usedToday.helpText = SPKL(@"FEED_DAILY_LIMIT_USED_TODAY_HELP");

    return SPKTopicSection(SPKL(@"FEED_DAILY_LIMIT_HEADER"), @[ hideFeed, disableReels, timeLimit, lockedTimeLimit, usedToday ], nil);
}
