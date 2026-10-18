// Settings page for Mull. A bundle (not a plist-only entry) so every change can also be written
// straight to a file Messages reads: iOS itself saves preferences to disk late.

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSliderTableCell.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define SC_SETTINGS_FILE @"com.goldenappleguy.mull.settings.plist"
#define SC_RESET_FILE @"com.goldenappleguy.mull.reset"

// Where Messages looks for the files (rootless first)
static NSArray<NSString *> *SCDirs(void);

// Text set in code, translated from the same table (Root.strings) that translates Root.plist
static NSString *SCLocalized(NSString *key) {
    return [[NSBundle bundleForClass:NSClassFromString(@"SCRootListController")] localizedStringForKey:key value:key table:@"Root"];
}

@interface SCRootListController : PSListController
@end

// Where the jailbreak lives ("" rootful, "/var/jb" rootless, a .jbroot path on roothide), from where this
// settings bundle was loaded
static NSString *SCJailbreakRoot(void) {
    NSString *path = [NSBundle bundleForClass:[SCRootListController class]].bundlePath ?: @"";
    NSRange range = [path rangeOfString:@"/Library/PreferenceBundles/"];
    return range.location != NSNotFound ? [path substringToIndex:range.location] : @"/var/jb";
}

static NSArray<NSString *> *SCDirs(void) {
    return @[[SCJailbreakRoot() stringByAppendingString:@"/var/mobile/Library/Preferences"]];
}

@implementation SCRootListController

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

static void SCWriteFile(NSString *name, NSData *data) {
    for (NSString *dir in SCDirs()) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:dir]) [data writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES];
    }
}

// Every setting goes to Messages' file right away
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    NSMutableDictionary *all = [NSMutableDictionary dictionary];
    for (PSSpecifier *s in self.specifiers) {
        NSString *key = [s propertyForKey:@"key"];
        id v = key ? [self readPreferenceValue:s] : nil;
        if (key && v) all[key] = v;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:all format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (data) SCWriteFile(SC_SETTINGS_FILE, data);
}

// Messages clears its per-conversation exceptions when it sees a newer stamp than the one it last applied
- (void)resetExceptions {
    NSString *stamp = [NSString stringWithFormat:@"%.0f", [NSDate date].timeIntervalSince1970];
    SCWriteFile(SC_RESET_FILE, [stamp dataUsingEncoding:NSUTF8StringEncoding]);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:SCLocalized(@"Conversations Reset")
        message:SCLocalized(@"Every conversation uses the countdown again.") preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:SCLocalized(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

static char kSCFormatKey;   // label: block formatting a value
static char kSCWidthKey;    // label: width reserved for the value (widest text, larger font)
static char kSCReserveKey;  // slider: space kept free of the track (and knob) at the trailing end
static char kSCLeadingKey;  // slider: space kept free at the leading end, for an inline label
#define SC_VALUE_FONT_SIZE 16.0

@interface SCValueLabel : UILabel // no ivars: installed on an existing label with object_setClass
@end

@implementation SCValueLabel
// Wherever the slider puts this label, it goes at the trailing end in the space kept free of the track,
// sized for the widest value and centered vertically
- (void)setFrame:(CGRect)frame {
    NSNumber *width = objc_getAssociatedObject(self, &kSCWidthKey);
    if (width && self.superview) {
        CGFloat w = width.doubleValue, h = ceil(self.font.lineHeight) + 2, H = self.superview.bounds.size.height;
        frame = CGRectMake(self.superview.bounds.size.width - w, round((H - h) / 2), w, h);
    }
    [super setFrame:frame];
}

- (void)setText:(NSString *)text {
    NSString *(^format)(double) = objc_getAssociatedObject(self, &kSCFormatKey);
    NSScanner *scanner = [NSScanner scannerWithString:text ?: @""];
    double value;
    if (format && [scanner scanDouble:&value]) text = format(value);
    [super setText:text];
}
@end

// A subclass of the slider's own class, made at runtime, whose track (and so the knob) stops short of the
// trailing end by the reserved amount, and starts after the leading reserve (if any)
static Class SCPaddedSliderClass(Class base) {
    NSString *name = [@"SCPadded_" stringByAppendingString:NSStringFromClass(base)];
    Class cls = NSClassFromString(name);
    if (cls) return cls;
    cls = objc_allocateClassPair(base, name.UTF8String, 0);
    if (!cls) return base;
    SEL sel = @selector(trackRectForBounds:);
    IMP imp = imp_implementationWithBlock(^CGRect(UISlider *slider, CGRect bounds) {
        struct objc_super sup = {slider, base};
        CGRect rect = ((CGRect (*)(struct objc_super *, SEL, CGRect))objc_msgSendSuper)(&sup, sel, bounds);
        NSNumber *reserve = objc_getAssociatedObject(slider, &kSCReserveKey);
        if (reserve) {
            CGFloat maxX = bounds.size.width - reserve.doubleValue;
            if (CGRectGetMaxX(rect) > maxX) rect.size.width = MAX(0, maxX - rect.origin.x);
        }
        NSNumber *leading = objc_getAssociatedObject(slider, &kSCLeadingKey);
        if (leading && rect.origin.x < leading.doubleValue) {
            CGFloat maxX = CGRectGetMaxX(rect);
            rect.origin.x = leading.doubleValue;
            rect.size.width = MAX(0, maxX - rect.origin.x);
        }
        return rect;
    });
    class_addMethod(cls, sel, imp, method_getTypeEncoding(class_getInstanceMethod(base, sel)));
    objc_registerClassPair(cls);
    return cls;
}

@interface SCIntegerSliderCell : PSSliderTableCell
@end

// An "inlineLabel" property puts a title at the leading end of the row (e.g. "Delay"), for a slider that
// sits in a group with other rows rather than under its own header.
@implementation SCIntegerSliderCell {
    UILabel *_inlineLabel;
}

- (UISlider *)slider {
    return [self.control isKindOfClass:[UISlider class]] ? (UISlider *)self.control : nil;
}

- (NSInteger)decimals {
    return MAX(0, MIN(3, [[self.specifier propertyForKey:@"decimals"] integerValue]));
}

// The value rounded to the row's decimal places
- (double)roundedValue:(double)value {
    double scale = pow(10, [self decimals]);
    return round(value * scale) / scale;
}

// The number alone, with the phone's decimal separator
- (NSString *)numberText:(double)value {
    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.usesGroupingSeparator = NO;
    formatter.minimumFractionDigits = formatter.maximumFractionDigits = [self decimals];
    return [formatter stringFromNumber:@([self roundedValue:value])];
}

- (NSString *)textForValue:(float)value {
    NSString *zeroText = [self.specifier propertyForKey:@"zeroText"]; // e.g. "Off" for a setting where 0 disables it
    if (zeroText && [self roundedValue:value] == 0) return SCLocalized(zeroText);
    NSString *suffix = SCLocalized([self.specifier propertyForKey:@"valueSuffix"] ?: @"");
    return [[self numberText:value] stringByAppendingString:suffix];
}

// The slider's value label: a label inside the slider showing a number
- (UILabel *)valueLabelIn:(UIView *)view {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            NSScanner *scanner = [NSScanner scannerWithString:((UILabel *)subview).text ?: @""];
            double number;
            if ([subview isKindOfClass:[SCValueLabel class]] || [scanner scanDouble:&number]) return (UILabel *)subview;
        }
        UILabel *found = [self valueLabelIn:subview];
        if (found) return found;
    }
    return nil;
}

- (void)installValueFormatting {
    UILabel *label = [self valueLabelIn:[self slider]];
    if (!label) return;
    __weak typeof(self) weakSelf = self;
    objc_setAssociatedObject(label, &kSCFormatKey, ^NSString *(double value) {
        return [weakSelf textForValue:value] ?: [NSString stringWithFormat:@"%.0f", value];
    }, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (![label isKindOfClass:[SCValueLabel class]]) {
        object_setClass(label, [SCValueLabel class]);
        label.userInteractionEnabled = YES;
        [label addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(valueLabelLongPressed:)]];
    }
    // Larger than the slider's own size; room for the widest value is taken from the end of the track
    UISlider *slider = [self slider];
    label.font = [label.font fontWithSize:SC_VALUE_FONT_SIZE];
    label.textAlignment = NSTextAlignmentRight;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.8;
    CGFloat width = 0;
    for (NSString *key in @[@"min", @"max"]) {
        NSString *text = [self textForValue:[[self.specifier propertyForKey:key] floatValue]];
        width = MAX(width, ceil([text sizeWithAttributes:@{NSFontAttributeName: label.font}].width) + 2);
    }
    objc_setAssociatedObject(label, &kSCWidthKey, @(width), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat knobOverhang = 8, gap = 8; // the knob reaches past the end of the track
    NSNumber *reserve = @(width + gap + knobOverhang);
    if (![objc_getAssociatedObject(slider, &kSCReserveKey) isEqual:reserve]) {
        objc_setAssociatedObject(slider, &kSCReserveKey, reserve, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (![NSStringFromClass([slider class]) hasPrefix:@"SCPadded_"]) object_setClass(slider, SCPaddedSliderClass([slider class]));
        [label.superview setNeedsLayout];
        [slider setNeedsLayout];
    }
    NSString *inlineText = [self.specifier propertyForKey:@"inlineLabel"];
    if (inlineText.length) inlineText = SCLocalized(inlineText);
    if (inlineText.length) {
        if (!_inlineLabel) {
            _inlineLabel = [UILabel new];
            _inlineLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
            _inlineLabel.textColor = [UIColor labelColor];
            _inlineLabel.userInteractionEnabled = NO;
            [slider addSubview:_inlineLabel];
        }
        _inlineLabel.text = inlineText;
        [_inlineLabel sizeToFit];
        CGFloat h = _inlineLabel.bounds.size.height;
        _inlineLabel.frame = CGRectMake(0, round((slider.bounds.size.height - h) / 2), _inlineLabel.bounds.size.width, h);
        NSNumber *leading = @(_inlineLabel.bounds.size.width + gap + knobOverhang);
        if (![objc_getAssociatedObject(slider, &kSCLeadingKey) isEqual:leading]) {
            objc_setAssociatedObject(slider, &kSCLeadingKey, leading, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [label.superview setNeedsLayout];
            [slider setNeedsLayout];
        }
    }
    label.frame = label.frame; // place it in the reserved space
    label.text = label.text;   // reformat what is showing now
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self installValueFormatting];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self installValueFormatting]; // the slider may create its label lazily
}

- (void)valueLabelLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UISlider *slider = [self slider];
    UIViewController *presenter = nil;
    for (UIResponder *r = self; r; r = r.nextResponder) {
        if ([r isKindOfClass:[UIViewController class]]) { presenter = (UIViewController *)r; break; }
    }
    if (!slider || !presenter) return;

    float min = [[self.specifier propertyForKey:@"min"] floatValue], max = [[self.specifier propertyForKey:@"max"] floatValue];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:SCLocalized(@"Enter Value")
        message:[NSString stringWithFormat:SCLocalized(@"From %1$@ to %2$@."), [self numberText:min], [self textForValue:max]]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = [self decimals] ? UIKeyboardTypeDecimalPad : UIKeyboardTypeNumberPad;
        field.text = [self numberText:slider.value];
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:SCLocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:SCLocalized(@"Set") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text;
        if (text.length == 0) return;
        NSNumberFormatter *formatter = [NSNumberFormatter new];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        NSNumber *number = [formatter numberFromString:text] ?: @(text.doubleValue);
        float value = MAX(min, MIN(max, (float)[weakSelf roundedValue:number.doubleValue]));
        [slider setValue:value animated:YES];
        [weakSelf controlChanged:slider]; // saves through the specifier, as dragging does
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

@end

