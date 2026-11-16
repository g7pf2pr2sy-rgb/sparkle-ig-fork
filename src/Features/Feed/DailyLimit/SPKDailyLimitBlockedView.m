#import "SPKDailyLimitBlockedView.h"

#import "SPKStrings.h"
#import "../../../Utils.h"

@interface SPKDailyLimitBlockedView ()
@property (nonatomic, strong) UIButton *closeButton;
@end

@implementation SPKDailyLimitBlockedView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;

    self.backgroundColor = [SPKUtils SPKColor_InstagramBackground];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:44.0 weight:UIImageSymbolWeightRegular];
    UIImageView *imageView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"hourglass" withConfiguration:symbolConfig]];
    imageView.tintColor = [SPKUtils SPKColor_InstagramSecondaryText];
    imageView.contentMode = UIViewContentModeScaleAspectFit;

    UILabel *titleLabel = [UILabel new];
    titleLabel.text = SPKL(@"FEED_DAILY_LIMIT_REELS_BLOCKED_TITLE");
    titleLabel.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleTitle3].pointSize weight:UIFontWeightBold];
    titleLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.numberOfLines = 0;

    UILabel *messageLabel = [UILabel new];
    messageLabel.text = SPKL(@"FEED_DAILY_LIMIT_REELS_BLOCKED_MESSAGE");
    messageLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    messageLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    messageLabel.textAlignment = NSTextAlignmentCenter;
    messageLabel.numberOfLines = 0;

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeButton setTitle:SPKL(@"COMMON_ACTION_CLOSE") forState:UIControlStateNormal];
    closeButton.titleLabel.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize weight:UIFontWeightSemibold];
    closeButton.tintColor = [SPKUtils SPKColor_InstagramBlue];
    closeButton.hidden = YES;
    [closeButton addTarget:self action:@selector(spk_closeTapped) forControlEvents:UIControlEventTouchUpInside];
    self.closeButton = closeButton;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ imageView, titleLabel, messageLabel, closeButton ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12.0;
    [stack setCustomSpacing:20.0 afterView:messageLabel];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.leadingAnchor constant:32.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.trailingAnchor constant:-32.0]
    ]];

    self.isAccessibilityElement = NO;
    return self;
}

- (void)setShowsCloseButton:(BOOL)showsCloseButton {
    _showsCloseButton = showsCloseButton;
    self.closeButton.hidden = !showsCloseButton;
}

- (void)spk_closeTapped {
    if (self.closeHandler)
        self.closeHandler();
}

@end
