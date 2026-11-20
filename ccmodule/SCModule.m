// Control Center toggle for Mull (loaded by CCSupport): turns the countdown on and off.
// It runs inside SpringBoard, so it writes the Enabled setting to both the preferences and the file Messages reads.

#import <ControlCenterUIKit/CCUIToggleModule.h>
#include <notify.h>

#define SC_DOMAIN CFSTR("com.goldenappleguy.mull")
#define SC_SETTINGS_FILE @"com.goldenappleguy.mull.settings.plist"
#define SC_PAUSED_UNTIL_KEY @"PausedUntil" // set by RemoteCompanion's Pause: Mull is off until then

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

// Off while paused, since Mull does nothing then; turning it on ends the pause
- (BOOL)isSelected {
    for (NSString *dir in SCDirs()) {
        NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:SC_SETTINGS_FILE]];
        id until = settings[SC_PAUSED_UNTIL_KEY];
        if ([until respondsToSelector:@selector(doubleValue)] && [until doubleValue] > NSDate.date.timeIntervalSince1970) return NO;
        id value = settings[@"Enabled"];
        if ([value respondsToSelector:@selector(boolValue)]) return [value boolValue];
    }
    return YES;
}

- (void)setSelected:(BOOL)selected {
    CFPreferencesSetAppValue(CFSTR("Enabled"), selected ? kCFBooleanTrue : kCFBooleanFalse, SC_DOMAIN);
    CFPreferencesSetAppValue((__bridge CFStringRef)SC_PAUSED_UNTIL_KEY, NULL, SC_DOMAIN);
    CFPreferencesAppSynchronize(SC_DOMAIN);
    for (NSString *dir in SCDirs()) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) continue;
        NSString *path = [dir stringByAppendingPathComponent:SC_SETTINGS_FILE];
        NSMutableDictionary *all = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy] ?: [NSMutableDictionary dictionary];
        all[@"Enabled"] = @(selected);
        [all removeObjectForKey:SC_PAUSED_UNTIL_KEY];
        [all writeToFile:path atomically:YES];
    }
    notify_post("com.goldenappleguy.mull.changed"); // for RemoteCompanion's add-on
    [super setSelected:selected];
    [self refreshState];
}

@end
