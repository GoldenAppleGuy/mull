// Control Center toggle for Mull (loaded by CCSupport): turns the countdown on and off.
// It runs inside SpringBoard, so it writes the Enabled setting to both the preferences and the file Messages reads.

#import <ControlCenterUIKit/CCUIToggleModule.h>

#define SC_DOMAIN CFSTR("com.goldenappleguy.mull")
#define SC_SETTINGS_FILE @"com.goldenappleguy.mull.settings.plist"

@interface SCModule : CCUIToggleModule
@end

@implementation SCModule

// Where the jailbreak lives ("" rootful, "/var/jb" rootless, a .jbroot path on roothide), from where this
// module was loaded
static NSArray<NSString *> *SCDirs(void) {
    NSString *path = [NSBundle bundleForClass:[SCModule class]].bundlePath ?: @"";
    NSRange range = [path rangeOfString:@"/Library/ControlCenter/Bundles/"];
    NSString *root = range.location != NSNotFound ? [path substringToIndex:range.location] : @"/var/jb";
    return @[[root stringByAppendingString:@"/var/mobile/Library/Preferences"]];
}

- (UIImage *)iconGlyph {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
    return [UIImage systemImageNamed:@"timer" withConfiguration:config];
}

- (UIColor *)selectedColor {
    return [UIColor systemRedColor];
}

- (BOOL)isSelected {
    for (NSString *dir in SCDirs()) {
        id value = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:SC_SETTINGS_FILE]][@"Enabled"];
        if ([value respondsToSelector:@selector(boolValue)]) return [value boolValue];
    }
    return YES;
}

- (void)setSelected:(BOOL)selected {
    CFPreferencesSetAppValue(CFSTR("Enabled"), selected ? kCFBooleanTrue : kCFBooleanFalse, SC_DOMAIN);
    CFPreferencesAppSynchronize(SC_DOMAIN);
    for (NSString *dir in SCDirs()) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) continue;
        NSString *path = [dir stringByAppendingPathComponent:SC_SETTINGS_FILE];
        NSMutableDictionary *all = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy] ?: [NSMutableDictionary dictionary];
        all[@"Enabled"] = @(selected);
        [all writeToFile:path atomically:YES];
    }
    [super setSelected:selected];
    [self refreshState];
}

@end
