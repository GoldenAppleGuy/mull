#import <UIKit/UIKit.h>
#import <Contacts/Contacts.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <notify.h>
#include <sys/stat.h>

#define SC_OVERLAY_TAG 0x5C0D
#define SC_SETTINGS_FILE @"com.goldenappleguy.mull.settings.plist"
#define SC_RESET_FILE @"com.goldenappleguy.mull.reset"
#define SC_MARKER_TAG 0x5C0F
#define SC_EXEMPT_KEY @"SCExempt"
#define SC_RESET_APPLIED_KEY @"SCResetApplied"

@interface CKComposition : NSObject
@property (nonatomic, readonly) NSAttributedString *text;
- (BOOL)hasContent;
@property (nonatomic, readonly) id shelfMediaObject;
@property (nonatomic, readonly) id shelfPluginPayload;
@end

@interface CKMessageEntryView : UIView
@property (nonatomic, readonly) UIButton *sendButton;
@property (nonatomic, readonly) UIButton *arrowButton;
@property (nonatomic, readonly) CKComposition *composition;
@end

@interface CKConversationListCell : UITableViewCell
@property (nonatomic, readonly) id conversation;
@property (nonatomic, readonly) UILabel *dateLabel;
@end

@interface CKChatController : UIViewController
@property (nonatomic, retain) id conversation;
- (void)messageEntryViewSendButtonHit:(id)entryView;
@end

@interface CKComposeChatController : CKChatController
@end
@interface CKNotificationChatController : CKChatController
@end

// Held strongly while counting, so leaving the conversation does not drop the message
static CKChatController *gController;
static CKMessageEntryView *gEntryView;
static id gConversation;
static NSTimer *gTimer;
static NSInteger gRemaining;
static CFAbsoluteTime gDeadline, gStart;
static NSInteger gAttachmentSeconds;
static BOOL gBypass;
static BOOL gRing;
static BOOL gHaptics;
static UIBackgroundTaskIdentifier gBackgroundTask;

#pragma mark - Settings

// Where the jailbreak lives ("" rootful, "/var/jb" rootless, a .jbroot path on roothide), from where this
// dylib was loaded: the settings page's files are under it
static NSString *SCJailbreakRoot(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        NSString *path = dladdr((const void *)&SCJailbreakRoot, &info) && info.dli_fname ? @(info.dli_fname) : @"";
        root = @"/var/jb";
        for (NSString *marker in @[@"/Library/MobileSubstrate/DynamicLibraries/", @"/usr/lib/TweakInject/"]) {
            NSRange range = [path rangeOfString:marker];
            if (range.location != NSNotFound) {
                root = [path substringToIndex:range.location];
                break;
            }
        }
    });
    return root;
}

// Text the tweak shows (the countdown screen, the swipe action), translated: the tweak has no bundle of its own,
// so its strings live in the settings bundle (Tweak.strings in each language folder)
static NSString *SCLocalized(NSString *key) {
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bundle = [NSBundle bundleWithPath:[SCJailbreakRoot() stringByAppendingPathComponent:@"Library/PreferenceBundles/MullPrefs.bundle"]];
    });
    return bundle ? [bundle localizedStringForKey:key value:key table:@"Tweak"] : key;
}

// Where the settings page leaves its files; the simulator test build reads a folder of its own
static NSArray<NSString *> *SCPrefDirs(void) {
#ifdef SC_SIM
    return @[@"/tmp/mull-sim"];
#else
    return @[[SCJailbreakRoot() stringByAppendingString:@"/var/mobile/Library/Preferences"]];
#endif
}

// The settings as stored, with a pause still in effect left in place
static NSDictionary *SCStoredSettings(void) {
    for (NSString *dir in SCPrefDirs()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:SC_SETTINGS_FILE]];
        if (d) return d;
    }
    return @{};
}

// Until this time (seconds since 1970), Mull counts as switched off. Set by RemoteCompanion's Pause action.
#define SC_PAUSED_UNTIL_KEY @"PausedUntil"
static BOOL SCIsPaused(NSDictionary *stored) {
    id until = stored[SC_PAUSED_UNTIL_KEY];
    return [until respondsToSelector:@selector(doubleValue)] && [until doubleValue] > NSDate.date.timeIntervalSince1970;
}

// The settings in effect: while paused, Enabled reads as off
static NSDictionary *SCSettings(void) {
    NSDictionary *stored = SCStoredSettings();
    if (!SCIsPaused(stored)) return stored;
    NSMutableDictionary *settings = [stored mutableCopy];
    settings[@"Enabled"] = @NO;
    return settings;
}

// Signals for RemoteCompanion's add-on (layout/Library/RemoteCompanion/AddOns/mull.json): what happened,
// carried in a notification's state, which also stays readable afterwards for its conditions
#define SC_EVENT_CALL "com.goldenappleguy.mull.call"         // 1 countdown started, 2 cancelled, 3 went ahead
#define SC_EVENT_MESSAGE "com.goldenappleguy.mull.message"   // 1 countdown started, 2 cancelled, 3 sent
#define SC_STATE_RUNNING "com.goldenappleguy.mull.running"   // flags: 1 a call's countdown, 2 a message's (3 both)
#define SC_STATE_ENABLED "com.goldenappleguy.mull.enabled"   // 0 off, 1 on, 2 paused
#define SC_STATE_CALLS "com.goldenappleguy.mull.calls"       // Call Countdown: 0 off, 1 on

// Sets a notification's state and posts it
static void SCPostState(const char *name, uint64_t state) {
    int token;
    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) return;
    notify_set_state(token, state);
    notify_post(name);
    notify_cancel(token);
}

// A notification's current state, by its token or by its name (0 when it can't be read)
static uint64_t SCNoteState(int token) {
    uint64_t state = 0;
    notify_get_state(token, &state);
    return state;
}

static uint64_t SCReadState(const char *name) {
    int token;
    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) return 0;
    uint64_t state = SCNoteState(token);
    notify_cancel(token);
    return state;
}

// A call's countdown (in SpringBoard or a phone app) and a message's (in Messages) can overlap: each sets or
// clears only its own flag in the running state
#define SC_RUNNING_CALL 1
#define SC_RUNNING_MESSAGE 2
static void SCSetRunning(uint64_t flag, BOOL running) {
    int token;
    if (notify_register_check(SC_STATE_RUNNING, &token) != NOTIFY_STATUS_OK) return;
    uint64_t old = SCNoteState(token), state = running ? (old | flag) : (old & ~flag);
    if (state != old) {
        notify_set_state(token, state);
        notify_post(SC_STATE_RUNNING);
    }
    notify_cancel(token);
}

static NSInteger SCInteger(NSDictionary *s, NSString *key, NSInteger fallback) {
    id v = s[key];
    return [v respondsToSelector:@selector(doubleValue)] ? (NSInteger)lround([v doubleValue]) : fallback;
}

static BOOL SCBoolean(NSDictionary *s, NSString *key, BOOL fallback) {
    id v = s[key];
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : fallback;
}

// The countdown colors, by the names the settings store (Root.plist and mull.json list the same names). The
// car's screen receives a color as its place in this list, so new colors go at the end.
static NSArray<NSString *> *SCColorNames(void) {
    return @[@"red", @"orange", @"pink", @"purple", @"blue", @"green", @"gray"];
}

static UIColor *SCColorAt(NSUInteger index) {
    NSArray<UIColor *> *colors = @[UIColor.systemRedColor, UIColor.systemOrangeColor, UIColor.systemPinkColor, UIColor.systemPurpleColor,
                                   UIColor.systemBlueColor, UIColor.systemGreenColor, UIColor.systemGrayColor];
    return index < colors.count ? colors[index] : colors[0];
}

// The place of a color name in the list; red for anything unknown
static NSUInteger SCColorIndex(NSString *name) {
    NSUInteger index = name ? [SCColorNames() indexOfObject:name] : NSNotFound;
    return index == NSNotFound ? 0 : index;
}

static UIColor *SCColor(NSString *name) {
    return SCColorAt(SCColorIndex(name));
}

#pragma mark - Conversation exceptions

static NSString *SCConversationID(id conversation) {
    for (NSString *name in @[@"uniqueIdentifier", @"groupID"]) {
        SEL sel = NSSelectorFromString(name);
        if ([conversation respondsToSelector:sel]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(conversation, sel);
            if ([v isKindOfClass:[NSString class]] && [v length]) return v;
        }
    }
    return nil;
}

// Where the skipped conversations are kept: Messages' own preferences, which the notification view (a separate
// process, allowed to use them) shares
static NSUserDefaults *SCDefaults(void) {
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BOOL app = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.MobileSMS"];
        defaults = app ? NSUserDefaults.standardUserDefaults : [[NSUserDefaults alloc] initWithSuiteName:@"com.apple.MobileSMS"];
        if (!defaults) defaults = NSUserDefaults.standardUserDefaults;
    });
    return defaults;
}

// The settings page asks for a reset by writing a newer stamp than the one applied last. Checked whenever a
// conversation's state is looked at, but only reads the file again when it has changed.
static void SCApplyReset(void) {
    static time_t lastSeen;
    NSUserDefaults *defaults = SCDefaults();
    for (NSString *dir in SCPrefDirs()) {
        NSString *path = [dir stringByAppendingPathComponent:SC_RESET_FILE];
        struct stat info;
        if (stat(path.fileSystemRepresentation, &info) != 0) continue;
        if (info.st_mtime == lastSeen) continue;
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        lastSeen = info.st_mtime;
        if (text.doubleValue > [defaults doubleForKey:SC_RESET_APPLIED_KEY]) {
            [defaults removeObjectForKey:SC_EXEMPT_KEY];
            [defaults setDouble:text.doubleValue forKey:SC_RESET_APPLIED_KEY];
        }
    }
}

static BOOL SCIsExempt(id conversation) {
    SCApplyReset();
    NSString *ident = SCConversationID(conversation);
    return ident && [[SCDefaults() arrayForKey:SC_EXEMPT_KEY] containsObject:ident];
}

static void SCToggleExempt(id conversation) {
    NSString *ident = SCConversationID(conversation);
    if (!ident) return;
    NSMutableArray *list = [[SCDefaults() arrayForKey:SC_EXEMPT_KEY] mutableCopy] ?: [NSMutableArray array];
    if ([list containsObject:ident]) [list removeObject:ident];
    else [list addObject:ident];
    [SCDefaults() setObject:list forKey:SC_EXEMPT_KEY];
}

#pragma mark - Exemption markers

// A small bolt, shown where a conversation has its countdown off
static void SCSetBolt(UIView *parent, NSInteger tag, BOOL show, CGRect frame) {
    UIImageView *bolt = (UIImageView *)[parent viewWithTag:tag];
    if (!show) {
        [bolt removeFromSuperview];
        return;
    }
    if (!bolt) {
        bolt = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"bolt.fill"]];
        bolt.tag = tag;
        bolt.tintColor = UIColor.systemOrangeColor;
        bolt.contentMode = UIViewContentModeScaleAspectFit;
        bolt.userInteractionEnabled = NO;
        [parent addSubview:bolt];
    }
    bolt.frame = frame;
}

static void SCWalk(UIView *view, void (^visit)(UIView *)) {
    visit(view);
    for (UIView *sub in view.subviews) SCWalk(sub, visit);
}

// Lays out the list rows again, after an exemption changed
static void SCRefreshMarkers(UIView *root) {
    Class cell = NSClassFromString(@"CKConversationListCell");
    SCWalk(root, ^(UIView *v) {
        if (cell && [v isKindOfClass:cell]) [v setNeedsLayout];
    });
}

#pragma mark - Countdown

// The visible Send control: sendButton, or on newer iOS (where that one is not the visible one) arrowButton
// (iOS 18) or glassSendButton (iOS 26)
static UIView *SCSendButton(CKMessageEntryView *entryView) {
    UIView *button = entryView.sendButton;
    for (NSString *name in @[@"sendButton", @"arrowButton", @"glassSendButton"]) {
        SEL sel = NSSelectorFromString(name);
        if (![entryView respondsToSelector:sel]) continue;
        UIView *candidate = ((id (*)(id, SEL))objc_msgSend)(entryView, sel);
        if ([candidate isKindOfClass:[UIView class]] && candidate.window && !candidate.hidden && candidate.bounds.size.width > 1) return candidate;
    }
    return button;
}

// The glass Send button (iOS 26) filters whatever is drawn inside it, which tints the countdown's red; there the
// countdown sits above the button, in its superview, instead
static BOOL SCIsGlass(UIView *button) {
    return button.superview && [NSStringFromClass([button class]) rangeOfString:@"Glass"].location != NSNotFound;
}

// The glass button is made (nearly) invisible during the countdown, and put back after
static __weak UIView *gGlassButton;
static CGFloat gGlassAlpha;

static UIView *SCOverlayHost(UIView *button) {
    return SCIsGlass(button) ? button.superview : button;
}

static UILabel *SCOverlay(void) {
    return (UILabel *)[SCOverlayHost(SCSendButton(gEntryView)) viewWithTag:SC_OVERLAY_TAG];
}

static void SCStop(void) {
    if (gTimer) SCSetRunning(SC_RUNNING_MESSAGE, NO);
    [gTimer invalidate];
    gTimer = nil;
    [SCOverlay() removeFromSuperview];
    if (gGlassButton) {
        gGlassButton.alpha = gGlassAlpha;
        gGlassButton = nil;
    }
    gEntryView = nil;
    gController = nil;
    gConversation = nil;
    if (gBackgroundTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:gBackgroundTask];
        gBackgroundTask = UIBackgroundTaskInvalid;
    }
}

static void SCSendNow(void) {
    CKChatController *controller = gController;
    CKMessageEntryView *entryView = gEntryView;
    SCStop();
    if (!controller || !entryView) return;
    SCPostState(SC_EVENT_MESSAGE, 3);
    gBypass = YES;
    [controller messageEntryViewSendButtonHit:entryView];
    gBypass = NO;
}

static void SCHaptic(UIImpactFeedbackStyle style) {
    if (!gHaptics) return;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:style] impactOccurred];
}

static void SCShowOverlay(UIColor *color) {
    UIView *button = SCSendButton(gEntryView);
    if (!button) return;
    UILabel *label = SCOverlay();
    BOOL glass = SCIsGlass(button);
    CGRect area = glass ? button.frame : button.bounds;
    if (!label) {
        label = [[UILabel alloc] initWithFrame:area];
        label.tag = SC_OVERLAY_TAG;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.whiteColor;
        label.clipsToBounds = YES;
        if (!glass) label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [SCOverlayHost(button) addSubview:label];
        if (glass) {
            // Its glass is drawn on top of anything above it, tinting the countdown and showing the arrow through;
            // an alpha just over the cutoff hides it but still lets a tap through to cancel
            gGlassButton = button;
            gGlassAlpha = button.alpha;
            button.alpha = 0.011;
        }
        // A ring that drains over the whole countdown, centered (the glass button is a pill, not a circle)
        if (gRing) {
        CGFloat ringSide = MIN(area.size.width, area.size.height);
        CAShapeLayer *ring = [CAShapeLayer layer];
        ring.name = @"ring";
        if (glass) {
            // The glass button is a pill: the ring follows its outline, starting at the top and going clockwise
            CGFloat w = area.size.width, h = area.size.height, inset = 2.5, r = (h - 2 * inset) / 2;
            UIBezierPath *pill = [UIBezierPath bezierPath];
            [pill moveToPoint:CGPointMake(w / 2, inset)];
            [pill addLineToPoint:CGPointMake(w - inset - r, inset)];
            [pill addArcWithCenter:CGPointMake(w - inset - r, h / 2) radius:r startAngle:-M_PI_2 endAngle:M_PI_2 clockwise:YES];
            [pill addLineToPoint:CGPointMake(inset + r, h - inset)];
            [pill addArcWithCenter:CGPointMake(inset + r, h / 2) radius:r startAngle:M_PI_2 endAngle:M_PI * 1.5 clockwise:YES];
            [pill closePath];
            ring.frame = CGRectMake(0, 0, w, h);
            ring.path = pill.CGPath;
        } else {
            ring.frame = CGRectMake((area.size.width - ringSide) / 2, (area.size.height - ringSide) / 2, ringSide, ringSide);
            ring.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(ringSide / 2, ringSide / 2) radius:ringSide / 2 - 2.5
                startAngle:-M_PI_2 endAngle:M_PI * 1.5 clockwise:YES].CGPath;
        }
        ring.fillColor = UIColor.clearColor.CGColor;
        ring.strokeColor = [UIColor colorWithWhite:1 alpha:0.85].CGColor;
        ring.lineWidth = 2;
        ring.lineCap = kCALineCapRound;
        CABasicAnimation *drain = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
        drain.fromValue = @1;
        drain.toValue = @0;
        drain.duration = gRemaining;
        drain.fillMode = kCAFillModeForwards;
        drain.removedOnCompletion = NO;
        [ring addAnimation:drain forKey:@"drain"];
        [label.layer addSublayer:ring];
        }
    }
    CGFloat side = MIN(area.size.width, area.size.height);
    label.backgroundColor = color;
    label.layer.cornerRadius = side / 2;
    label.font = [UIFont monospacedDigitSystemFontOfSize:MAX(side * 0.5, 12) weight:UIFontWeightBold];
    label.text = [NSString stringWithFormat:@"%ld", (long)gRemaining];
}

static UIColor *gColor;

// Photos and files sit in the composition's text as attachment characters; apps and stickers in the shelf
static BOOL SCHasAttachment(CKComposition *composition) {
    if (!composition) return NO;
    // Older versions of iOS have different parts: ask before using each one
    if ([composition respondsToSelector:@selector(shelfMediaObject)] && composition.shelfMediaObject) return YES;
    if ([composition respondsToSelector:@selector(shelfPluginPayload)] && composition.shelfPluginPayload) return YES;
    SEL mediaObjects = NSSelectorFromString(@"mediaObjects");
    if ([composition respondsToSelector:mediaObjects]) {
        id objects = ((id (*)(id, SEL))objc_msgSend)(composition, mediaObjects);
        if ([objects respondsToSelector:@selector(count)] && [objects count] > 0) return YES;
    }
    return [composition.text.string containsString:@"\uFFFC"];
}

// Runs a few times a second: stops if the message was emptied meanwhile, shows each new second, sends at the end
static void SCTick(void) {
    if (!gController || !gEntryView) {
        SCStop();
        return;
    }
    CKComposition *composition = gEntryView.composition;
    if (composition && [composition respondsToSelector:@selector(hasContent)] && ![composition hasContent]) {
        SCPostState(SC_EVENT_MESSAGE, 2);
        SCStop();
        return;
    }
    // An attachment added meanwhile extends the wait to the attachment delay, counted from the tap
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gAttachmentSeconds > 0 && gStart + gAttachmentSeconds > gDeadline && SCHasAttachment(composition)) {
        gDeadline = gStart + gAttachmentSeconds;
        for (CALayer *layer in SCOverlay().layer.sublayers) {
            if (![layer.name isEqualToString:@"ring"]) continue;
            [layer removeAnimationForKey:@"drain"];
            CABasicAnimation *drain = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
            drain.fromValue = @((gDeadline - now) / gAttachmentSeconds);
            drain.toValue = @0;
            drain.duration = gDeadline - now;
            drain.fillMode = kCAFillModeForwards;
            drain.removedOnCompletion = NO;
            [layer addAnimation:drain forKey:@"drain"];
        }
    }
    NSInteger left = (NSInteger)ceil(gDeadline - now);
    if (left <= 0) {
        SCSendNow();
        return;
    }
    if (left != gRemaining) {
        gRemaining = left;
        SCShowOverlay(gColor);
        SCHaptic(UIImpactFeedbackStyleLight);
    }
}

// The first message sent in a conversation (a new thread, or one with nothing sent yet) can have its own
// delay; 0 means the regular one.
static NSInteger SCDelayForThread(id conversation, NSDictionary *settings, NSInteger regular) {
    BOOL first = YES;
    id chat = [conversation respondsToSelector:@selector(chat)] ? ((id (*)(id, SEL))objc_msgSend)(conversation, @selector(chat)) : nil;
    if (chat) {
        SEL sentDate = NSSelectorFromString(@"lastSentMessageDate"), finished = NSSelectorFromString(@"lastFinishedMessage");
        if ([chat respondsToSelector:sentDate]) first = ((id (*)(id, SEL))objc_msgSend)(chat, sentDate) == nil;
        else if ([chat respondsToSelector:finished]) first = ((id (*)(id, SEL))objc_msgSend)(chat, finished) == nil;
    }
    NSInteger value = first ? SCInteger(settings, @"NewSeconds", 0) : 0;
    return value > 0 ? value : regular;
}

// Whether this send gets a countdown: switched on, not an exempt conversation, and long enough
static BOOL SCShouldCount(CKChatController *controller, CKMessageEntryView *entryView, NSDictionary *settings) {
    if (!SCBoolean(settings, @"Enabled", YES)) return NO;
    SCApplyReset();
    if (SCIsExempt(controller.conversation)) return NO;
    NSInteger minimum = SCInteger(settings, @"MinLength", 0);
    CKComposition *composition = entryView.composition;
    if (minimum > 0 && composition && !SCHasAttachment(composition) && (NSInteger)composition.text.length < minimum) return NO;
    return YES;
}

// Handles a tap on Send: starts the countdown, or cancels one running. NO means the message goes out as usual.
static BOOL SCHandleSend(CKChatController *controller, CKMessageEntryView *entryView) {
    if (gBypass) return NO;
    NSDictionary *settings = SCSettings();
    if (gTimer) {
        SCHaptic(UIImpactFeedbackStyleRigid);
        SCPostState(SC_EVENT_MESSAGE, 2);
        SCStop();
        return YES;
    }
    if (!SCShouldCount(controller, entryView, settings)) return NO;
    gController = controller;
    gEntryView = entryView;
    gConversation = controller.conversation;
    gHaptics = SCBoolean(settings, @"Haptics", YES);
    gRing = SCBoolean(settings, @"Ring", YES);
    gColor = SCColor(settings[@"Color"]);
    NSInteger seconds = SCInteger(settings, @"seconds", 3), attachmentSeconds = SCInteger(settings, @"AttachmentSeconds", 0);
    seconds = SCDelayForThread(controller.conversation, settings, seconds);
    if (attachmentSeconds > 0 && SCHasAttachment(entryView.composition)) seconds = MAX(seconds, attachmentSeconds);
    gRemaining = MAX(1, MIN(60, seconds));
    gStart = CFAbsoluteTimeGetCurrent();
    gDeadline = gStart + gRemaining;
    gAttachmentSeconds = attachmentSeconds;
    // Keeps counting, and sends, if the app is left meanwhile
    gBackgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
        SCSendNow();
    }];
    SCShowOverlay(gColor);
    SCHaptic(UIImpactFeedbackStyleLight);
    SCPostState(SC_EVENT_MESSAGE, 1);
    SCSetRunning(SC_RUNNING_MESSAGE, YES);
    gTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        SCTick();
    }];
    [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
    return YES;
}

%hook CKChatController

- (void)messageEntryViewSendButtonHit:(CKMessageEntryView *)entryView {
    if (SCHandleSend(self, entryView)) return;
    %orig;
}

- (void)setConversation:(id)conversation {
    if (gTimer && gController == self && conversation != gConversation) {
        NSString *a = SCConversationID(conversation), *b = SCConversationID(gConversation);
        if (!a || !b || ![a isEqualToString:b]) SCSendNow();
    }
    %orig;
}

%end

#pragma mark - Conversation list swipe action

// Adds a "skip countdown" action to a conversation row's swipe actions
static UISwipeActionsConfiguration *SCAddAction(UISwipeActionsConfiguration *original, id list, NSIndexPath *indexPath) {
    if (!original || !indexPath) return original;
    id conversation = nil;
    for (NSString *name in @[@"conversationAtIndexPath:", @"conversationForIndexPath:"]) {
        SEL sel = NSSelectorFromString(name);
        if ([list respondsToSelector:sel]) {
            conversation = ((id (*)(id, SEL, id))objc_msgSend)(list, sel, indexPath);
            break;
        }
    }
    if (!SCConversationID(conversation)) return original;
    BOOL exempt = SCIsExempt(conversation);
    // Icon only (a title would be drawn beside it on iOS 26), sized to match the system actions' icons
    UIContextualAction *action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:nil
        handler:^(UIContextualAction *a, UIView *view, void (^completion)(BOOL)) {
            SCToggleExempt(conversation);
            dispatch_async(dispatch_get_main_queue(), ^{
                for (UIWindow *window in UIApplication.sharedApplication.windows) SCRefreshMarkers(window);
            });
            completion(YES);
        }];
    action.backgroundColor = exempt ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
    UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium scale:UIImageSymbolScaleLarge];
    action.image = [UIImage systemImageNamed:(exempt ? @"timer" : @"bolt.fill") withConfiguration:symbol];
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:[original.actions arrayByAddingObject:action]];
    config.performsFirstActionWithFullSwipe = original.performsFirstActionWithFullSwipe;
    return config;
}

// Messages 16 and later list its conversations in a collection view; 15 uses a table view


// New messages and replies from a notification have their own controllers, which override the send handler
%group SCSendSubclasses
%hook CKComposeChatController
- (void)messageEntryViewSendButtonHit:(CKMessageEntryView *)entryView {
    if (SCHandleSend(self, entryView)) return;
    %orig;
}
%end

%hook CKNotificationChatController
- (void)messageEntryViewSendButtonHit:(CKMessageEntryView *)entryView {
    if (SCHandleSend(self, entryView)) return;
    %orig;
}

// A reply from a notification lives only as long as the notification's view: closing it during the countdown
// sends the message at once, as changing conversations does, so it isn't lost with the view
- (void)viewWillDisappear:(BOOL)animated {
    if (gTimer && gController == self) SCSendNow();
    %orig;
}
%end
%end

// Bolt beside the date of a conversation with the countdown off
%hook CKConversationListCell
- (void)layoutSubviews {
    %orig;
    UILabel *date = self.dateLabel;
    if (!date.superview) return;
    CGFloat size = 13;
    SCSetBolt(date.superview, SC_MARKER_TAG, SCIsExempt(self.conversation),
              CGRectMake(CGRectGetMinX(date.frame) - size - 4, CGRectGetMidY(date.frame) - size / 2, size, size));
}
%end

%group SCCollectionList
%hook CKConversationListCollectionViewController
- (UISwipeActionsConfiguration *)trailingSwipeActionsConfigurationForIndexPath:(NSIndexPath *)indexPath {
    UISwipeActionsConfiguration *original = %orig;
    return SCAddAction(original, self, indexPath);
}
%end
%end

%group SCTableList
%hook CKConversationListController
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    UISwipeActionsConfiguration *original = %orig;
    return SCAddAction(original, self, indexPath);
}
%end
%end


#pragma mark - Call guard

@interface CNFuture : NSObject
- (void)addSuccessBlock:(void (^)(id))block;
- (void)addFailureBlock:(void (^)(NSError *))block;
- (void)finishWithResult:(id)result;
- (void)finishWithError:(NSError *)error;
@end

@interface TUCallCenter : NSObject
- (BOOL)launchAppForJoinRequest:(id)request;
+ (instancetype)sharedInstance;
- (void)launchAppForDialRequest:(id)request completion:(id)completion;
- (id)dialWithRequest:(id)request;
- (void)dialWithRequest:(id)request completion:(id)completion;
- (NSUInteger)currentCallCount;
- (BOOL)_isEmergencyDialRequest:(id)request;
@end

static BOOL gCallBypass;
static BOOL SCInSpringBoard(void);
static NSString *SCJoinRequestNumber(id request, BOOL *hold);
static UIWindow *gCallWindow;
static NSTimer *gCallTimer;
static uint64_t gCarRequest; // the request also shown on the car's screen

static NSString *SCRequestNumber(id request) {
    id handle = [request respondsToSelector:@selector(handle)] ? ((id (*)(id, SEL))objc_msgSend)(request, @selector(handle)) : nil;
    id value = [handle respondsToSelector:@selector(value)] ? ((id (*)(id, SEL))objc_msgSend)(handle, @selector(value)) : nil;
    if (![value isKindOfClass:[NSString class]] && [request respondsToSelector:@selector(destinationID)]) value = ((id (*)(id, SEL))objc_msgSend)(request, @selector(destinationID));
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

// Emergency calls are never delayed. When that cannot be told for sure, the call goes straight through.
static BOOL SCCallIsExempt(TUCallCenter *center, id request) {
    if (![center respondsToSelector:@selector(_isEmergencyDialRequest:)]) return YES;
    if ([center _isEmergencyDialRequest:request]) return YES;
    NSString *number = SCRequestNumber(request);
    if (!number) return NO; // Apple's own emergency check above already said no
    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger i = 0; i < number.length; i++) {
        unichar c = [number characterAtIndex:i];
        if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
    }
    return digits.length > 0 && digits.length <= 3; // short codes, including every emergency number
}

static void SCDismissCallWindow(void) {
    [gCallTimer invalidate];
    gCallTimer = nil;
    gCarRequest = 0;
    UIWindow *window = gCallWindow;
    window.hidden = YES;
    gCallWindow = nil;
    // The Cancel button's own action is still running when this is called; free the window afterwards
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ (void)window; });
}

// The saved contact for a number, if any: a name and photo to show on the countdown screen
static NSString *SCNameForNumber(NSString *number, UIImage **photo) {
    if (number.length == 0) return nil;
    NSPredicate *match = [number containsString:@"@"] ? [CNContact predicateForContactsMatchingEmailAddress:number]
        : [CNContact predicateForContactsMatchingPhoneNumber:[CNPhoneNumber phoneNumberWithStringValue:number]];
    NSArray *keys = @[CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactThumbnailImageDataKey];
    CNContact *contact = [[CNContactStore new] unifiedContactsMatchingPredicate:match keysToFetch:keys error:nil].firstObject;
    if (!contact) return nil;
    if (photo && contact.thumbnailImageData) *photo = [UIImage imageWithData:contact.thumbnailImageData];
    NSString *name = [[@[contact.givenName ?: @"", contact.familyName ?: @""] componentsJoinedByString:@" "] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return name.length ? name : (contact.organizationName.length ? contact.organizationName : nil);
}

// A blurred full screen with who is being called, a countdown and Cancel; the call goes ahead at zero
@interface SCCallCancel : NSObject
+ (void)cancel;
+ (void)callNow;
@end

static void (^gCallCancelled)(void);
static void (^gCallGo)(void);

@implementation SCCallCancel
+ (void)cancel {
    if (!gCallWindow) return;
    if (gHaptics) [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleRigid] impactOccurred];
    void (^cancelled)(void) = gCallCancelled;
    gCallCancelled = nil;
    gCallGo = nil;
    BOOL callAppUp = NO;
    if (SCInSpringBoard()) {
        SEL frontSel = NSSelectorFromString(@"_accessibilityFrontMostApplication");
        id front = [UIApplication.sharedApplication respondsToSelector:frontSel] ? ((id (*)(id, SEL))objc_msgSend)(UIApplication.sharedApplication, frontSel) : nil;
        id bundle = [front respondsToSelector:@selector(bundleIdentifier)] ? ((id (*)(id, SEL))objc_msgSend)(front, @selector(bundleIdentifier)) : nil;
        callAppUp = [bundle isEqualToString:@"com.apple.InCallService"] || [bundle isEqualToString:@"com.apple.facetime"];
    }
    if (callAppUp) {
        // The call app that opened underneath is closed first, with this screen still covering it
        [gCallTimer invalidate];
        gCallTimer = nil;
        UIWindow *window = gCallWindow;
        if (cancelled) cancelled();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.7 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.2 animations:^{ window.alpha = 0; } completion:^(BOOL done) {
                if (gCallWindow == window) SCDismissCallWindow();
            }];
        });
        return;
    }
    SCDismissCallWindow();
    if (cancelled) cancelled();
}

+ (void)callNow {
    void (^go)(void) = gCallGo; // held here, since the block clears its own global while it runs
    if (go) go();
}
@end

static BOOL SCInSpringBoard(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
}

static UIWindowScene *SCActiveScene(void) {
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:[UIWindowScene class]]) continue;
        if (SCInSpringBoard() || candidate.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)candidate;
    }
    return nil;
}

// An app with nothing on screen (the in-call app, opened from a notification) cannot show the countdown, so
// SpringBoard shows it. Requests and answers travel as system notifications whose state carries the data:
// a request id, the number in two parts, and the answer (1 to go ahead, 2 cancelled).
#define SC_NOTE_A "com.goldenappleguy.mull.call.a"
#define SC_NOTE_RESPONSE "com.goldenappleguy.mull.call.response"
#define SC_NOTE_ALIVE "com.goldenappleguy.mull.daemon.alive"

static BOOL gRemotePending;


// The daemon sets this once its hook is in place; the per-app guards then stand down
static BOOL SCDaemonAlive(void) {
    return SCReadState(SC_NOTE_ALIVE) == 1;
}
static NSString *gCallKind = @"phone";


static void SCShowCallGuard(NSString *number, NSInteger seconds, UIColor *color, void (^proceed)(void), void (^cancelled)(void));

// What is called (a number or a FaceTime address) travels as text packed 6 bits to a character into four
// notification states of 8 characters each, plus a request id and the call kind in the first notification.
// First notification state: bits 48-63 request id, bits 40-45 length, bit 39 FaceTime.
#define SC_ALPHABET @"abcdefghijklmnopqrstuvwxyz0123456789@.-_+ ()"
static const char *SCPayloadName(int part) {
    static const char *names[4] = {"com.goldenappleguy.mull.call.p0", "com.goldenappleguy.mull.call.p1",
                                   "com.goldenappleguy.mull.call.p2", "com.goldenappleguy.mull.call.p3"};
    return names[part];
}

// What kind of call: "phone", "audio" (FaceTime Audio) or "video" (FaceTime)
static NSString *SCKindForDialRequest(id request) {
    BOOL video = [request respondsToSelector:@selector(isVideo)] && ((BOOL (*)(id, SEL))objc_msgSend)(request, @selector(isVideo));
    id provider = [request respondsToSelector:@selector(provider)] ? ((id (*)(id, SEL))objc_msgSend)(request, @selector(provider)) : nil;
    SEL telephony = NSSelectorFromString(@"isTelephonyProvider");
    if ([provider respondsToSelector:telephony]) {
        if (((BOOL (*)(id, SEL))objc_msgSend)(provider, telephony)) return @"phone";
        return video ? @"video" : @"audio";
    }
    return video ? @"video" : @"phone";
}

static NSString *SCKindForJoinRequest(id request) {
    for (NSString *name in @[@"isVideo", @"isVideoEnabled"]) {
        SEL sel = NSSelectorFromString(name);
        if ([request respondsToSelector:sel]) return ((BOOL (*)(id, SEL))objc_msgSend)(request, sel) ? @"video" : @"audio";
    }
    return @"video";
}

static NSString *SCKindForURL(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"facetime-audio"]) return @"audio";
    if ([scheme isEqualToString:@"facetime"]) return @"video";
    return @"phone";
}

// The kind of call as it travels in a notification's state: 2 bits
static uint64_t SCCodeForKind(NSString *kind) {
    return [kind isEqualToString:@"video"] ? 2 : ([kind isEqualToString:@"audio"] ? 1 : 0);
}

static NSString *SCKindForCode(uint64_t code) {
    return code == 2 ? @"video" : (code == 1 ? @"audio" : @"phone");
}

static NSString *SCLabelForKind(NSString *kind) {
    if ([kind isEqualToString:@"video"]) return SCLocalized(@"FaceTime Video");
    if ([kind isEqualToString:@"audio"]) return SCLocalized(@"FaceTime Audio");
    return SCLocalized(@"Phone Call");
}

static void SCRemoteCallGuard(NSString *text, NSString *kind, BOOL fromApp, dispatch_queue_t queue, void (^proceed)(void), void (^cancelled)(void)) {
    text = [text lowercaseString] ?: @"";
    NSString *alphabet = SC_ALPHABET;
    uint64_t payload[4] = {0, 0, 0, 0};
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < text.length && count < 32; i++) {
        NSRange r = [alphabet rangeOfString:[text substringWithRange:NSMakeRange(i, 1)]];
        if (r.location == NSNotFound) continue;
        payload[count / 8] |= ((uint64_t)(r.location + 1)) << (6 * (count % 8));
        count++;
    }
    gRemotePending = YES;
    uint64_t identifier = arc4random_uniform(65534) + 1;
    __block int responseToken = 0;
    __block BOOL finished = NO;
    void (^finish)(BOOL) = ^(BOOL cancel) {
        if (finished) return;
        finished = YES;
        gRemotePending = NO;
        if (responseToken) notify_cancel(responseToken);
        if (cancel) { if (cancelled) cancelled(); } else proceed();
    };
    __block BOOL acknowledged = NO;
    notify_register_dispatch(SC_NOTE_RESPONSE, &responseToken, queue, ^(int t) {
        uint64_t state = SCNoteState(t);
        if ((state >> 8) != identifier) return;
        if ((state & 0xFF) == 3) { acknowledged = YES; return; } // SpringBoard has the request
        finish((state & 0xFF) == 2);
    });
    // No answer at all means SpringBoard is not listening: go ahead rather than leave the call waiting
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.5 * NSEC_PER_SEC), queue, ^{ if (!acknowledged) finish(NO); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), queue, ^{ finish(NO); });

    // The payload names are held open until SpringBoard has read them
    int t0 = 0, t1 = 0, t2 = 0, t3 = 0;
    int *slots[4] = {&t0, &t1, &t2, &t3};
    for (int part = 0; part < 4; part++) {
        if (notify_register_check(SCPayloadName(part), slots[part]) != NOTIFY_STATUS_OK) { finish(NO); return; }
        notify_set_state(*slots[part], (identifier << 48) | payload[part]);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 62 * NSEC_PER_SEC), queue, ^{ notify_cancel(t0); notify_cancel(t1); notify_cancel(t2); notify_cancel(t3); });
    SCPostState(SC_NOTE_A, (identifier << 48) | ((uint64_t)count << 40) | (SCCodeForKind(kind) << 36) | ((uint64_t)(fromApp ? 1 : 0) << 38));
}

// SpringBoard's side: shows the countdown for a request and sends back the answer

static NSMutableDictionary<NSString *, NSDate *> *gApproved;

// The text of a request (who is called), or nil when the payload belongs to another request
static NSString *SCReadPayload(uint64_t identifier, NSUInteger count) {
    NSString *alphabet = SC_ALPHABET;
    NSMutableString *text = [NSMutableString string];
    for (int part = 0; part < 4; part++) {
        uint64_t state = SCReadState(SCPayloadName(part));
        if ((state >> 48) != identifier) return nil;
        for (int i = 0; i < 8 && (NSUInteger)(part * 8 + i) < count; i++) {
            NSUInteger index = (NSUInteger)((state >> (6 * i)) & 0x3F);
            if (index >= 1 && index <= alphabet.length) [text appendString:[alphabet substringWithRange:NSMakeRange(index - 1, 1)]];
        }
    }
    return text;
}

static void SCCarShow(uint64_t identifier, NSUInteger count, NSUInteger kindCode, NSInteger seconds, NSString *colorName);

static void SCHandleRemoteRequest(void) {
    uint64_t meta = SCReadState(SC_NOTE_A);
    uint64_t identifier = meta >> 48;
    NSUInteger count = (NSUInteger)((meta >> 40) & 0x3F);
    NSUInteger kindCode = (NSUInteger)((meta >> 36) & 3);
    BOOL fromApp = (meta >> 38) & 1;
    if (identifier == 0) return;
    NSString *text = SCReadPayload(identifier, count);
    if (!text) return;
    gCallKind = SCKindForCode(kindCode);
    SCPostState(SC_NOTE_RESPONSE, (identifier << 8) | 3); // received
    // The app asked first (before it opened the call screen) and was let through; the call service asks again
    // a moment later for the same call, which needs no second countdown
    NSDate *approvedAt = gApproved[text];
    if (!fromApp && approvedAt && -[approvedAt timeIntervalSinceNow] < 30) {
        [gApproved removeObjectForKey:text];
        SCPostState(SC_NOTE_RESPONSE, (identifier << 8) | 1);
        return;
    }
    if (gCallWindow) {
        // Another countdown is still on screen (or fading out): never leave this call waiting
        SCPostState(SC_NOTE_RESPONSE, (identifier << 8) | 1);
        return;
    }
    NSDictionary *settings = SCSettings();
    if (!SCBoolean(settings, @"Enabled", YES) || !SCBoolean(settings, @"CallGuard", NO)) {
        SCPostState(SC_NOTE_RESPONSE, (identifier << 8) | 1);
        return;
    }
    gHaptics = SCBoolean(settings, @"Haptics", YES);
    NSInteger seconds = MAX(1, MIN(30, SCInteger(settings, @"CallSeconds", 3)));
    SCShowCallGuard(text, seconds, SCColor(settings[@"Color"]), ^{
        if (fromApp) {
            if (!gApproved) gApproved = [NSMutableDictionary dictionary];
            gApproved[text] = [NSDate date];
        }
        SCPostState(SC_NOTE_RESPONSE, (identifier << 8) | 1);
    }, ^{
        SCPostState(SC_NOTE_RESPONSE, (identifier << 8) | 2);
        // The call screen was already opened for a call that will not happen; close it
        void (^closeCallScreen)(void) = ^{
            typedef void (*Terminate)(NSString *, int, BOOL, NSString *);
            Terminate terminate = (Terminate)dlsym(RTLD_DEFAULT, "BKSTerminateApplicationForReasonAndReportWithDescription");
            if (terminate) terminate(@"com.apple.InCallService", 5, NO, @"Mull: call cancelled");
        };
        closeCallScreen();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.35 * NSEC_PER_SEC), dispatch_get_main_queue(), closeCallScreen);
    });
    // The same countdown on the car's screen, when CarPlay is connected
    if (gCallWindow) SCCarShow(identifier, count, kindCode, seconds, settings[@"Color"]);
}

static void SCShowCallGuard(NSString *number, NSInteger seconds, UIColor *color, void (^proceed)(void), void (^cancelled)(void)) {
    UIWindowScene *scene = SCActiveScene();
    if (!scene) {
        // An app with nothing on screen (the in-call app, opened from a notification): SpringBoard shows it
        if (!SCInSpringBoard() && !gRemotePending) SCRemoteCallGuard(number, gCallKind, NO, dispatch_get_main_queue(), proceed, cancelled);
        else proceed();
        return;
    }
    // Tells RemoteCompanion's add-on how the countdown went
    SCPostState(SC_EVENT_CALL, 1);
    SCSetRunning(SC_RUNNING_CALL, YES);
    void (^goAhead)(void) = proceed, (^stopped)(void) = cancelled;
    proceed = ^{
        SCSetRunning(SC_RUNNING_CALL, NO);
        SCPostState(SC_EVENT_CALL, 3);
        goAhead();
    };
    cancelled = ^{
        SCSetRunning(SC_RUNNING_CALL, NO);
        SCPostState(SC_EVENT_CALL, 2);
        if (stopped) stopped();
    };
    UIImage *photo = nil;
    NSString *name = SCNameForNumber(number, &photo);
    gCallCancelled = [cancelled copy];

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelAlert + 1;
    window.backgroundColor = UIColor.clearColor;
    UIViewController *root = [UIViewController new];
    window.rootViewController = root;
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    blur.frame = window.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root.view addSubview:blur];
    UIView *content = blur.contentView;
    if (window.safeAreaInsets.top >= 50) {
        // The blur would turn the Dynamic Island's area grey; keep it black
        UIView *island = [[UIView alloc] initWithFrame:CGRectMake((window.bounds.size.width - 126) / 2, 11, 126, 37)];
        island.backgroundColor = UIColor.blackColor;
        island.layer.cornerRadius = 18.5;
        island.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
        [blur.contentView addSubview:island];
    }
    CGFloat width = window.bounds.size.width, height = window.bounds.size.height;
    CGFloat safeTop = window.safeAreaInsets.top, safeBottom = window.safeAreaInsets.bottom;

    UILabel *calling = [[UILabel alloc] initWithFrame:CGRectMake(24, safeTop + 48, width - 48, 20)];
    calling.text = SCLabelForKind(gCallKind);
    calling.textAlignment = NSTextAlignmentCenter;
    calling.font = [UIFont systemFontOfSize:16];
    calling.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    calling.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [content addSubview:calling];

    CGFloat avatar = 96;
    UIImageView *face = [[UIImageView alloc] initWithFrame:CGRectMake((width - avatar) / 2, safeTop + 84, avatar, avatar)];
    face.contentMode = UIViewContentModeScaleAspectFill;
    face.clipsToBounds = YES;
    face.layer.cornerRadius = avatar / 2;
    face.tintColor = [UIColor colorWithWhite:1 alpha:0.5];
    face.image = photo ?: [UIImage systemImageNamed:@"person.crop.circle.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:avatar weight:UIImageSymbolWeightThin]];
    face.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [content addSubview:face];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(24, CGRectGetMaxY(face.frame) + 14, width - 48, 38)];
    title.text = name ?: (number ?: @"");
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont systemFontOfSize:32 weight:UIFontWeightSemibold];
    title.textColor = UIColor.whiteColor;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.5;
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [content addSubview:title];
    if (name && number) {
        UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(24, CGRectGetMaxY(title.frame) + 2, width - 48, 22)];
        subtitle.text = number;
        subtitle.textAlignment = NSTextAlignmentCenter;
        subtitle.font = [UIFont systemFontOfSize:17];
        subtitle.textColor = [UIColor colorWithWhite:1 alpha:0.6];
        subtitle.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [content addSubview:subtitle];
    }

    CGFloat side = 170;
    UILabel *circle = [[UILabel alloc] initWithFrame:CGRectMake((width - side) / 2, (height - side) / 2 + 50, side, side)];
    circle.backgroundColor = color;
    circle.textColor = UIColor.whiteColor;
    circle.textAlignment = NSTextAlignmentCenter;
    circle.font = [UIFont monospacedDigitSystemFontOfSize:84 weight:UIFontWeightBold];
    circle.layer.cornerRadius = side / 2;
    circle.clipsToBounds = YES;
    circle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [content addSubview:circle];

    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.frame = CGRectMake(0, 0, side, side);
    ring.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(side / 2, side / 2) radius:side / 2 - 6 startAngle:-M_PI_2 endAngle:M_PI * 1.5 clockwise:YES].CGPath;
    ring.fillColor = UIColor.clearColor.CGColor;
    ring.strokeColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor;
    ring.lineWidth = 5;
    ring.lineCap = kCALineCapRound;
    CABasicAnimation *drain = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    drain.fromValue = @1;
    drain.toValue = @0;
    drain.duration = seconds;
    drain.fillMode = kCAFillModeForwards;
    drain.removedOnCompletion = NO;
    [ring addAnimation:drain forKey:@"drain"];
    [circle.layer addSublayer:ring];

    // Cancel is the bold, large choice; calling at once is a small grey link beneath it
    UIButton *callNow = [UIButton buttonWithType:UIButtonTypeSystem];
    callNow.frame = CGRectMake(40, height - safeBottom - 36 - 20, width - 80, 36);
    [callNow setTitle:SCLocalized(@"Call Now") forState:UIControlStateNormal];
    [callNow setTitleColor:[UIColor colorWithWhite:1 alpha:0.4] forState:UIControlStateNormal];
    callNow.titleLabel.font = [UIFont systemFontOfSize:14];
    callNow.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [callNow addTarget:SCCallCancel.class action:@selector(callNow) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:callNow];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.frame = CGRectMake(32, CGRectGetMinY(callNow.frame) - 12 - 72, width - 64, 72);
    cancel.backgroundColor = UIColor.whiteColor;
    cancel.layer.cornerRadius = 36;
    [cancel setTitle:SCLocalized(@"Cancel") forState:UIControlStateNormal];
    [cancel setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    cancel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [cancel addTarget:SCCallCancel.class action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:cancel];

    window.alpha = 0;
    window.hidden = NO;
    [UIView animateWithDuration:0.2 animations:^{ window.alpha = 1; }];
    gCallWindow = window;
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + seconds;
    __block NSInteger shown = 0;
    // Ends the countdown and places the call; the screen stays up until the call screen has opened over it
    __block BOOL started = NO;
    void (^go)(void) = ^{
        if (started) return;
        started = YES;
        [gCallTimer invalidate];
        gCallTimer = nil;
        gCallCancelled = nil;
        gCallGo = nil;
        circle.text = @"";
        cancel.hidden = YES;
        callNow.hidden = YES;
        proceed();
        __block id observer = nil;
        void (^finish)(void) = ^{
            if (observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
            observer = nil;
            if (gCallWindow != window) return;
            [UIView animateWithDuration:(SCInSpringBoard() ? 0.12 : 0.25) animations:^{ window.alpha = 0; } completion:^(BOOL done) {
                if (gCallWindow == window) SCDismissCallWindow();
            }];
        };
        observer = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *n) { finish(); }];
        // SpringBoard has no app of its own to wait for: the call app opens underneath, so leave at once
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (SCInSpringBoard() ? 0 : 3) * NSEC_PER_SEC), dispatch_get_main_queue(), finish);
    };
    gCallGo = [go copy];
    gCallTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        NSInteger left = (NSInteger)ceil(deadline - CFAbsoluteTimeGetCurrent());
        if (left <= 0) {
            go();
            return;
        }
        if (left != shown) {
            shown = left;
            circle.text = [NSString stringWithFormat:@"%ld", (long)left];
            if (gHaptics) [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:gCallTimer forMode:NSRunLoopCommonModes];
    [gCallTimer fire];
}

#pragma mark - CarPlay

// SpringBoard stays in charge of the countdown. While it shows one, it asks the CarPlay home screen process
// to show the same thing on the car's screen; a tap there comes back to SpringBoard as if made on the phone,
// and the car's copy closes when SpringBoard sends its answer to the call service.
// Show state: bits 48-63 request id, 40-45 text length, 36-37 kind, 8-15 seconds, 0-3 color.
// Answer state: request id << 8, then 1 call now or 2 cancel.
#define SC_NOTE_CAR_SHOW "com.goldenappleguy.mull.carplay.show"
#define SC_NOTE_CAR_ANSWER "com.goldenappleguy.mull.carplay.answer"

static void SCCarShow(uint64_t identifier, NSUInteger count, NSUInteger kindCode, NSInteger seconds, NSString *colorName) {
    NSUInteger color = SCColorIndex(colorName);
    gCarRequest = identifier;
    SCPostState(SC_NOTE_CAR_SHOW, (identifier << 48) | ((uint64_t)count << 40) | ((uint64_t)kindCode << 36) | ((uint64_t)seconds << 8) | color);
}

// SpringBoard's side: a tap on the car's screen
static void SCCarAnswered(uint64_t state) {
    if (!gCallWindow || gCarRequest == 0 || (state >> 8) != gCarRequest) return;
    if ((state & 0xFF) == 2) [SCCallCancel cancel];
    else if ((state & 0xFF) == 1) [SCCallCancel callNow];
}

// The car's side, in the CarPlay home screen process
static UIWindow *gCarWindow;
static NSTimer *gCarTimer;
static uint64_t gCarShown;

static void SCCarDismiss(void) {
    [gCarTimer invalidate];
    gCarTimer = nil;
    gCarShown = 0;
    UIWindow *window = gCarWindow;
    gCarWindow = nil;
    if (!window) return;
    [UIView animateWithDuration:0.2 animations:^{ window.alpha = 0; } completion:^(BOOL done) { window.hidden = YES; }];
}

@interface SCCarActions : NSObject
+ (void)cancel;
+ (void)callNow;
@end

@implementation SCCarActions
+ (void)answer:(uint64_t)code {
    if (!gCarShown) return;
    SCPostState(SC_NOTE_CAR_ANSWER, (gCarShown << 8) | code);
    SCCarDismiss();
}
+ (void)cancel { [self answer:2]; }
+ (void)callNow { [self answer:1]; }
@end

// The car's own display: the biggest scene the CarPlay process has on screen (it may also drive smaller
// ones, such as an instrument cluster)
static UIWindowScene *SCCarScene(void) {
    UIWindowScene *best = nil;
    CGFloat bestArea = 0;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *scene = (UIWindowScene *)candidate;
        CGRect bounds = scene.coordinateSpace.bounds;
        if (scene.activationState == UISceneActivationStateUnattached || scene.activationState == UISceneActivationStateBackground) continue;
        CGFloat area = bounds.size.width * bounds.size.height;
        if (area > bestArea) { best = scene; bestArea = area; }
    }
    return best;
}

static UILabel *SCCarLabel(NSString *text, UIFont *font, CGFloat alpha) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = font;
    label.textColor = [UIColor colorWithWhite:1 alpha:alpha];
    label.textAlignment = NSTextAlignmentCenter;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.5;
    return label;
}

static void SCCarHandleShow(void) {
    uint64_t state = SCReadState(SC_NOTE_CAR_SHOW);
    uint64_t identifier = state >> 48;
    if (identifier == 0 || identifier == gCarShown) return;
    NSString *number = SCReadPayload(identifier, (NSUInteger)((state >> 40) & 0x3F));
    if (!number) return;
    NSUInteger kindCode = (NSUInteger)((state >> 36) & 3);
    NSInteger seconds = MAX(1, MIN(30, (NSInteger)((state >> 8) & 0xFF)));
    NSUInteger colorIndex = (NSUInteger)(state & 0xF);
    UIColor *color = SCColorAt(colorIndex);
    UIWindowScene *scene = SCCarScene();
    if (!scene) return;
    if (gCarWindow) SCCarDismiss();

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelAlert + 100;
    window.backgroundColor = UIColor.clearColor;
    UIViewController *root = [UIViewController new];
    window.rootViewController = root;
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    blur.frame = window.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root.view addSubview:blur];
    UIView *content = blur.contentView;
    window.alpha = 0;
    window.hidden = NO;
    [window layoutIfNeeded];

    // Car screens are wide: who is called on the left, the countdown and the buttons on the right. The
    // safe area keeps clear of the CarPlay dock and the screen's rounded corners.
    UIEdgeInsets safe = window.safeAreaInsets;
    CGRect area = UIEdgeInsetsInsetRect(window.bounds, safe);
    BOOL wide = area.size.width >= area.size.height * 1.2;
    CGRect left = area, right = area;
    if (wide) CGRectDivide(area, &left, &right, area.size.width / 2, CGRectMinXEdge);
    else CGRectDivide(area, &left, &right, area.size.height * 0.45, CGRectMinYEdge);

    CGFloat avatar = MIN(88, left.size.height * 0.32);
    // Room for the number under the name, which comes in once the contact is found
    CGFloat blockHeight = 22 + 8 + avatar + 10 + 34 + 22;
    CGFloat y = CGRectGetMidY(left) - blockHeight / 2;
    UILabel *kind = SCCarLabel(SCLabelForKind(SCKindForCode(kindCode)), [UIFont systemFontOfSize:17], 0.7);
    kind.frame = CGRectMake(CGRectGetMinX(left) + 12, y, left.size.width - 24, 22);
    [content addSubview:kind];
    UIImageView *face = [[UIImageView alloc] initWithFrame:CGRectMake(CGRectGetMidX(left) - avatar / 2, CGRectGetMaxY(kind.frame) + 8, avatar, avatar)];
    face.contentMode = UIViewContentModeScaleAspectFill;
    face.clipsToBounds = YES;
    face.layer.cornerRadius = avatar / 2;
    face.tintColor = [UIColor colorWithWhite:1 alpha:0.5];
    face.image = [UIImage systemImageNamed:@"person.crop.circle.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:avatar weight:UIImageSymbolWeightThin]];
    [content addSubview:face];
    UILabel *title = SCCarLabel(number, [UIFont systemFontOfSize:28 weight:UIFontWeightSemibold], 1);
    title.frame = CGRectMake(CGRectGetMinX(left) + 12, CGRectGetMaxY(face.frame) + 10, left.size.width - 24, 34);
    [content addSubview:title];
    UILabel *subtitle = SCCarLabel(number, [UIFont systemFontOfSize:17], 0.6);
    subtitle.frame = CGRectMake(CGRectGetMinX(left) + 12, CGRectGetMaxY(title.frame), left.size.width - 24, 22);
    subtitle.hidden = YES;
    [content addSubview:subtitle];
    // The contact is looked up away from the main thread, so the countdown shows at once
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *photo = nil;
        NSString *name = nil;
        @try { name = SCNameForNumber(number, &photo); } @catch (NSException *e) {}
        if (!name) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gCarWindow != window) return;
            title.text = name;
            subtitle.hidden = NO;
            if (photo) face.image = photo;
        });
    });

    // Two real buttons: a car's screen is tapped at arm's length, so Call Now is no small link here
    CGFloat buttonHeight = 56, secondHeight = 48, gap = 12;
    CGFloat side = MIN(130, right.size.height - buttonHeight - secondHeight - gap - 16 - 40);
    side = MAX(side, 60);
    CGFloat column = MIN(right.size.width - 32, 300);
    CGFloat top = CGRectGetMidY(right) - (side + 16 + buttonHeight + gap + secondHeight) / 2;
    UILabel *circle = [[UILabel alloc] initWithFrame:CGRectMake(CGRectGetMidX(right) - side / 2, top, side, side)];
    circle.backgroundColor = color;
    circle.textColor = UIColor.whiteColor;
    circle.textAlignment = NSTextAlignmentCenter;
    circle.font = [UIFont monospacedDigitSystemFontOfSize:side * 0.48 weight:UIFontWeightBold];
    circle.layer.cornerRadius = side / 2;
    circle.clipsToBounds = YES;
    [content addSubview:circle];
    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.frame = CGRectMake(0, 0, side, side);
    ring.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(side / 2, side / 2) radius:side / 2 - 5 startAngle:-M_PI_2 endAngle:M_PI * 1.5 clockwise:YES].CGPath;
    ring.fillColor = UIColor.clearColor.CGColor;
    ring.strokeColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor;
    ring.lineWidth = 4;
    ring.lineCap = kCALineCapRound;
    CABasicAnimation *drain = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    drain.fromValue = @1;
    drain.toValue = @0;
    drain.duration = seconds;
    drain.fillMode = kCAFillModeForwards;
    drain.removedOnCompletion = NO;
    [ring addAnimation:drain forKey:@"drain"];
    [circle.layer addSublayer:ring];

    // Custom buttons with fixed colors: CarPlay's own button styling turned a white Cancel grey
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeCustom];
    cancel.frame = CGRectMake(CGRectGetMidX(right) - column / 2, CGRectGetMaxY(circle.frame) + 16, column, buttonHeight);
    cancel.backgroundColor = color;
    cancel.layer.cornerRadius = buttonHeight / 2;
    [cancel setTitle:SCLocalized(@"Cancel") forState:UIControlStateNormal];
    [cancel setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [cancel setTitleColor:[UIColor colorWithWhite:1 alpha:0.6] forState:UIControlStateHighlighted];
    cancel.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    [cancel addTarget:SCCarActions.class action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:cancel];
    UIButton *callNow = [UIButton buttonWithType:UIButtonTypeCustom];
    callNow.frame = CGRectMake(CGRectGetMidX(right) - column / 2, CGRectGetMaxY(cancel.frame) + gap, column, secondHeight);
    callNow.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    callNow.layer.cornerRadius = secondHeight / 2;
    [callNow setTitle:SCLocalized(@"Call Now") forState:UIControlStateNormal];
    [callNow setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [callNow setTitleColor:[UIColor colorWithWhite:1 alpha:0.6] forState:UIControlStateHighlighted];
    callNow.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [callNow addTarget:SCCarActions.class action:@selector(callNow) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:callNow];

    [UIView animateWithDuration:0.2 animations:^{ window.alpha = 1; }];
    gCarWindow = window;
    gCarShown = identifier;

    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + seconds;
    __block NSInteger shown = 0;
    gCarTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        NSTimeInterval remaining = deadline - CFAbsoluteTimeGetCurrent();
        // SpringBoard's answer normally closes this; if it never comes, don't stay on the car's screen
        if (remaining < -3) { SCCarDismiss(); return; }
        NSInteger left = MAX(0, (NSInteger)ceil(remaining));
        if (left != shown) {
            shown = left;
            circle.text = left > 0 ? [NSString stringWithFormat:@"%ld", (long)left] : @"";
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:gCarTimer forMode:NSRunLoopCommonModes];
    [gCarTimer fire];
}

// SpringBoard answered the call service: the call went ahead or was cancelled, so the car's copy closes
static void SCCarHandleResponse(uint64_t state) {
    if (gCarShown == 0 || (state >> 8) != gCarShown) return;
    if ((state & 0xFF) == 1 || (state & 0xFF) == 2) {
        SCCarDismiss();
    }
}

// Whether the call was held back for a countdown (it goes ahead later through proceed)
static BOOL SCGuardCall(TUCallCenter *center, id request, void (^proceed)(void), void (^cancelled)(void)) {
    if (gCallBypass || SCDaemonAlive()) return NO;
    NSDictionary *settings = SCSettings();
    if (!SCBoolean(settings, @"Enabled", YES) || !SCBoolean(settings, @"CallGuard", NO)) { return NO; }
    if (SCCallIsExempt(center, request)) { return NO; }
    if (center.currentCallCount > 0) { return NO; }
    if (gCallWindow || gRemotePending) return YES;
    gHaptics = SCBoolean(settings, @"Haptics", YES);
    NSInteger seconds = MAX(1, MIN(30, SCInteger(settings, @"CallSeconds", 3)));
    UIColor *color = SCColor(settings[@"Color"]);
    NSString *number = SCRequestNumber(request);
    gCallKind = SCKindForDialRequest(request);
    dispatch_async(dispatch_get_main_queue(), ^{
        SCShowCallGuard(number, seconds, color, ^{
            gCallBypass = YES;
            proceed();
            gCallBypass = NO;
        }, cancelled);
    });
    return YES;
}

// Calls started by opening a tel: or FaceTime link (Contacts and others hand the call to the system this way)
static BOOL SCGuardURL(NSURL *url, void (^proceed)(void)) {
    if (gCallBypass || !url || SCDaemonAlive()) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    if (![@[@"tel", @"telprompt", @"facetime", @"facetime-audio"] containsObject:scheme]) return NO;
    NSDictionary *settings = SCSettings();
    if (!SCBoolean(settings, @"Enabled", YES) || !SCBoolean(settings, @"CallGuard", NO)) return NO;
    Class centerClass = NSClassFromString(@"TUCallCenter"), requestClass = NSClassFromString(@"TUDialRequest");
    if (!centerClass || !requestClass || ![centerClass respondsToSelector:@selector(sharedInstance)]) return NO;
    TUCallCenter *center = ((id (*)(id, SEL))objc_msgSend)(centerClass, @selector(sharedInstance));
    id request = [requestClass alloc];
    if (![request respondsToSelector:@selector(initWithURL:)]) return NO;
    request = ((id (*)(id, SEL, id))objc_msgSend)(request, @selector(initWithURL:), url);
    if (!request || SCCallIsExempt(center, request)) return NO;
    if (gCallWindow || gRemotePending) return YES;
    gHaptics = SCBoolean(settings, @"Haptics", YES);
    NSInteger seconds = MAX(1, MIN(30, SCInteger(settings, @"CallSeconds", 3)));
    UIColor *color = SCColor(settings[@"Color"]);
    gCallKind = SCKindForURL(url);
    NSString *number = SCRequestNumber(request) ?: url.resourceSpecifier;
    dispatch_async(dispatch_get_main_queue(), ^{
        SCShowCallGuard(number, seconds, color, ^{
            gCallBypass = YES;
            proceed();
            gCallBypass = NO;
        }, nil);
    });
    return YES;
}


// Contacts (and other apps showing contact cards) place calls through this opener; it returns a future
@interface _CNUIUserActionDialRequestOpener : NSObject
- (id)openDialRequest:(id)request withScheduler:(id)scheduler;
@end

// System apps (Contacts among them) hand a call to the system as a tel: link through the app workspace
@interface LSApplicationWorkspace : NSObject
- (BOOL)openURL:(NSURL *)url withOptions:(NSDictionary *)options error:(NSError **)error;
- (BOOL)openSensitiveURL:(NSURL *)url withOptions:(NSDictionary *)options error:(NSError **)error;
@end

%group SCWorkspaceCalls
%hook LSApplicationWorkspace
- (BOOL)openSensitiveURL:(NSURL *)url withOptions:(NSDictionary *)options error:(NSError **)error {
    if (SCGuardURL(url, ^{ [self openSensitiveURL:url withOptions:options error:NULL]; })) return YES;
    return %orig;
}

- (BOOL)openURL:(NSURL *)url withOptions:(NSDictionary *)options error:(NSError **)error {
    if (SCGuardURL(url, ^{ [self openURL:url withOptions:options error:NULL]; })) return YES;
    return %orig;
}
%end
%end

// The buttons along the top of a contact card (Mobile, FaceTime and the rest) run an action item through
// this controller, whatever opens the link afterwards
@interface CNContactInlineActionsViewController : UIViewController
- (void)performAction:(id)action;
@end

static NSURL *SCURLForAction(id action) {
    id url = [action respondsToSelector:@selector(url)] ? ((id (*)(id, SEL))objc_msgSend)(action, @selector(url)) : nil;
    if ([url isKindOfClass:[NSURL class]]) return url;
    id request = [action respondsToSelector:NSSelectorFromString(@"dialRequest")] ? ((id (*)(id, SEL))objc_msgSend)(action, NSSelectorFromString(@"dialRequest")) : nil;
    id requestURL = [request respondsToSelector:@selector(URL)] ? ((id (*)(id, SEL))objc_msgSend)(request, @selector(URL)) : nil;
    if ([requestURL isKindOfClass:[NSURL class]]) return requestURL;
    // The item's link is a future that has not finished, so build it from the action type and number
    id type = [action respondsToSelector:NSSelectorFromString(@"type")] ? ((id (*)(id, SEL))objc_msgSend)(action, NSSelectorFromString(@"type")) : nil;
    id handle = [action respondsToSelector:NSSelectorFromString(@"targetHandle")] ? ((id (*)(id, SEL))objc_msgSend)(action, NSSelectorFromString(@"targetHandle")) : nil;
    NSString *kind = [type isKindOfClass:[NSString class]] ? type : nil;
    if (![handle isKindOfClass:[NSString class]] || ![kind hasSuffix:@"CallActionType"]) return nil;
    NSMutableString *number = [NSMutableString string];
    for (NSUInteger i = 0; i < [handle length]; i++) {
        unichar c = [handle characterAtIndex:i];
        if ((c >= '0' && c <= '9') || (c == '+' && number.length == 0)) [number appendFormat:@"%C", c];
    }
    if (number.length == 0) return nil;
    NSString *scheme = [kind isEqualToString:@"VideoCallActionType"] ? @"facetime" : ([kind isEqualToString:@"AudioCallActionType"] ? @"tel" : nil);
    return scheme ? [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@", scheme, number]] : nil;
}

%group SCInlineActions
%hook CNContactInlineActionsViewController
- (void)performAction:(id)action {
    NSURL *url = SCURLForAction(action);
    if (url && SCGuardURL(url, ^{ [self performAction:action]; })) return;
    %orig;
}
%end
%end

%group SCContactsCalls
%hook _CNUIUserActionDialRequestOpener
- (id)openDialRequest:(id)request withScheduler:(id)scheduler {
    Class futureClass = NSClassFromString(@"CNFuture");
    Class centerClass = NSClassFromString(@"TUCallCenter");
    if (!futureClass || ![futureClass respondsToSelector:@selector(promiseFuture)] || ![centerClass respondsToSelector:@selector(sharedInstance)]) return %orig;
    id promise = ((id (*)(id, SEL))objc_msgSend)(futureClass, @selector(promiseFuture));
    TUCallCenter *center = ((id (*)(id, SEL))objc_msgSend)(centerClass, @selector(sharedInstance));
    BOOL held = SCGuardCall(center, request, ^{
        id real = [self openDialRequest:request withScheduler:scheduler];
        [real addSuccessBlock:^(id result) { [promise finishWithResult:result]; }];
        [real addFailureBlock:^(NSError *error) { [promise finishWithError:error]; }];
    }, ^{
        [promise finishWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
    });
    return held ? promise : %orig;
}
%end
%end

%group SCCalls
%hook UIApplication
- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL))completion {
    void (^kept)(BOOL) = [completion copy];
    if (SCGuardURL(url, ^{ [self openURL:url options:options completionHandler:kept]; })) return;
    %orig;
}

- (BOOL)openURL:(NSURL *)url {
    if (SCGuardURL(url, ^{ [self openURL:url]; })) return YES;
    return %orig;
}
%end

%hook TUCallCenter
- (id)dialWithRequest:(id)request {
    if (SCGuardCall(self, request, ^{ [self dialWithRequest:request]; }, nil)) return nil;
    return %orig;
}

- (void)dialWithRequest:(id)request completion:(id)completion {
    id kept = [completion copy]; // the caller's block may live on the stack
    if (SCGuardCall(self, request, ^{ [self dialWithRequest:request completion:kept]; }, nil)) return;
    %orig;
}

- (BOOL)launchAppForJoinRequest:(id)request {
    if (!gCallBypass && !gRemotePending && SCDaemonAlive()) {
        NSDictionary *settings = SCSettings();
        BOOL hold = NO;
        NSString *who = SCJoinRequestNumber(request, &hold);
        if (hold && SCBoolean(settings, @"Enabled", YES) && SCBoolean(settings, @"CallGuard", NO) && self.currentCallCount == 0) {
            SCRemoteCallGuard(who, SCKindForJoinRequest(request), YES, dispatch_get_main_queue(), ^{
                gCallBypass = YES;
                [self launchAppForJoinRequest:request];
                gCallBypass = NO;
            }, nil);
            return YES;
        }
    }
    return %orig;
}

- (void)launchAppForDialRequest:(id)request completion:(id)completion {
    if (!gCallBypass && !gRemotePending && SCDaemonAlive()) {
        NSDictionary *settings = SCSettings();
        if (SCBoolean(settings, @"Enabled", YES) && SCBoolean(settings, @"CallGuard", NO) && !SCCallIsExempt(self, request) && self.currentCallCount == 0) {
            // Asks before the call screen opens, so nothing of it shows during the countdown
            id kept = [completion copy];
            SCRemoteCallGuard(SCRequestNumber(request), SCKindForDialRequest(request), YES, dispatch_get_main_queue(), ^{
                gCallBypass = YES;
                [self launchAppForDialRequest:request completion:kept];
                gCallBypass = NO;
            }, nil);
            return;
        }
    }
    id kept = [completion copy];
    if (SCGuardCall(self, request, ^{ [self launchAppForDialRequest:request completion:kept]; }, nil)) return;
    %orig;
}
%end
%end

#pragma mark - Call service daemon

// callservicesd sees every call request before a call exists, whichever app or route it came from. The hook
// holds an ordinary call, asks SpringBoard to show the countdown, and carries on (or drops it) from the answer.
@interface CSDCallStateController : NSObject
- (void)dialWithRequest:(id)request reply:(id)reply;
- (void)dialWithRequest:(id)request displayContext:(id)context;
- (id)performDialCall:(id)call displayContext:(id)context;
- (id)outgoingCallFromDialRequest:(id)request;
- (void)_dial:(id)call displayContext:(id)context completion:(id)completion;
- (void)joinConversationWithRequest:(id)request;
@end

@interface CSDCallProviderManagerXPCServer : NSObject
- (void)launchAppForDialRequest:(id)request reply:(id)reply;
@end



static BOOL gDaemonBypass;

// Only a plain outgoing call is held: not emergency, SOS, voicemail or redial, and nothing short enough to be
// an emergency number
static BOOL SCDaemonShouldHold(id request) {
    Class requestClass = [request class];
    if (![request respondsToSelector:NSSelectorFromString(@"dialType")]) return NO;
    NSInteger type = ((NSInteger (*)(id, SEL))objc_msgSend)(request, NSSelectorFromString(@"dialType"));
    SEL describe = NSSelectorFromString(@"stringForDialType:");
    if (![requestClass respondsToSelector:describe]) return NO;
    NSString *name = ((id (*)(id, SEL, NSInteger))objc_msgSend)(requestClass, describe, type);
    if (![name isKindOfClass:[NSString class]] || [name rangeOfString:@"Normal" options:NSCaseInsensitiveSearch].location == NSNotFound) return NO;
    if ([request respondsToSelector:NSSelectorFromString(@"isSOS")] && ((BOOL (*)(id, SEL))objc_msgSend)(request, NSSelectorFromString(@"isSOS"))) return NO;
    if ([request respondsToSelector:NSSelectorFromString(@"isRedial")] && ((BOOL (*)(id, SEL))objc_msgSend)(request, NSSelectorFromString(@"isRedial"))) return NO;
    NSString *number = SCRequestNumber(request);
    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger i = 0; i < number.length; i++) {
        unichar c = [number characterAtIndex:i];
        if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
    }
    return digits.length > 3;
}

// Waits here, on the daemon's own thread, so the original then runs exactly as it would have, in the same
// place. The countdown itself lives in SpringBoard; its answer comes back on a separate queue. YES if cancelled.
static BOOL SCDaemonWaitForAnswer(NSString *number, NSString *kind) {
    static dispatch_queue_t guardQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ guardQueue = dispatch_queue_create("mull.guard", DISPATCH_QUEUE_SERIAL); });
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL cancelled = NO;
    dispatch_async(guardQueue, ^{
        SCRemoteCallGuard(number, kind, NO, guardQueue, ^{
            dispatch_semaphore_signal(done);
        }, ^{
            cancelled = YES;
            dispatch_semaphore_signal(done);
        });
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 75 * NSEC_PER_SEC));
    return cancelled;
}

// A FaceTime call started from here (audio or video), not a join through a link; returns who is called
static NSString *SCHandleText(id object) {
    if (!object) return nil;
    id value = [object respondsToSelector:@selector(value)] ? ((id (*)(id, SEL))objc_msgSend)(object, @selector(value)) : nil;
    if ([value isKindOfClass:[NSString class]] && [value length]) return value;
    id handle = [object respondsToSelector:@selector(handle)] ? ((id (*)(id, SEL))objc_msgSend)(object, @selector(handle)) : nil;
    if (handle && handle != object) return SCHandleText(handle);
    return nil;
}

static NSString *SCJoinRequestNumber(id request, BOOL *hold) {
    *hold = NO;
    SEL linkSel = NSSelectorFromString(@"isJoiningConversationWithLink");
    if ([request respondsToSelector:linkSel] && ((BOOL (*)(id, SEL))objc_msgSend)(request, linkSel)) return nil;
    NSString *text = nil;
    for (NSString *name in @[@"handles", @"remoteMembers", @"otherInvitedHandles"]) {
        SEL sel = NSSelectorFromString(name);
        id group = [request respondsToSelector:sel] ? ((id (*)(id, SEL))objc_msgSend)(request, sel) : nil;
        id first = [group isKindOfClass:[NSSet class]] ? [group anyObject] : ([group isKindOfClass:[NSArray class]] ? [group firstObject] : nil);
        text = SCHandleText(first);
        if (text) break;
    }
    *hold = YES;
    return text ?: @"";
}

%group SCDaemon
%hook CSDCallStateController
- (void)dialWithRequest:(id)request displayContext:(id)context {
    if (gDaemonBypass || !SCDaemonShouldHold(request)) {
        %orig;
        return;
    }
    BOOL cancelled = SCDaemonWaitForAnswer(SCRequestNumber(request), SCKindForDialRequest(request));
    if (cancelled) return;
    %orig;
}

- (id)outgoingCallFromDialRequest:(id)request {
    id call = %orig;
    return call;
}

- (void)_dial:(id)call displayContext:(id)context completion:(id)completion {
    %orig;
}

- (id)performDialCall:(id)call displayContext:(id)context {
    return %orig;
}

- (void)joinConversationWithRequest:(id)request {
    BOOL hold;
    NSString *number = SCJoinRequestNumber(request, &hold);
    if (!hold) {
        %orig;
        return;
    }
    BOOL cancelled = SCDaemonWaitForAnswer(number, SCKindForJoinRequest(request));
    if (cancelled) return;
    %orig;
}

- (void)dialWithRequest:(id)request reply:(id)reply {
    %orig;
}
%end

%hook CSDCallProviderManagerXPCServer
- (void)launchAppForDialRequest:(id)request reply:(id)reply {
    %orig;
}
%end
%end

#pragma mark - RemoteCompanion

// RemoteCompanion's add-on asks for these by notification. Settings it changes go through the preferences
// system only, so SpringBoard copies them into the settings file that every part of Mull reads.
#define SC_DOMAIN CFSTR("com.goldenappleguy.mull")
#define SC_NOTE_CHANGED "com.goldenappleguy.mull.changed"          // settings changed somewhere
#define SC_NOTE_SET_ENABLED "com.goldenappleguy.mull.set.enabled"  // state 0 off, 1 on, 2 toggle
#define SC_NOTE_SET_CALLS "com.goldenappleguy.mull.set.calls"      // state 0 off, 1 on, 2 toggle
#define SC_NOTE_PAUSE "com.goldenappleguy.mull.pause"              // minutes in the PauseMinutes preference
#define SC_NOTE_RESUME "com.goldenappleguy.mull.resume"
#define SC_NOTE_CANCEL "com.goldenappleguy.mull.cancel"            // the running countdown, call or message
#define SC_NOTE_NOW "com.goldenappleguy.mull.now"                  // ends the running countdown early

static NSString *SCSettingsPath(void) {
    return [SCPrefDirs().firstObject stringByAppendingPathComponent:SC_SETTINGS_FILE];
}

// Writes these values to both the preferences system and the settings file (a nil value removes the key)
static void SCStoreSettings(NSDictionary *values) {
    NSMutableDictionary *file = [SCStoredSettings() mutableCopy];
    for (NSString *key in values) {
        id value = values[key] == NSNull.null ? nil : values[key];
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, SC_DOMAIN);
        file[key] = value;
    }
    CFPreferencesAppSynchronize(SC_DOMAIN);
    [file writeToFile:SCSettingsPath() atomically:YES];
}

// The range each number setting allows, read from the settings page's own Root.plist (its sliders' min and
// max), so the limits live in one place; tools/check_addon.py checks that mull.json uses the same ones
static NSDictionary<NSString *, NSArray<NSNumber *> *> *SCSettingRanges(void) {
    static NSDictionary *ranges;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *found = [NSMutableDictionary dictionary];
        NSString *path = [SCJailbreakRoot() stringByAppendingPathComponent:@"Library/PreferenceBundles/MullPrefs.bundle/Root.plist"];
        for (NSDictionary *item in [NSDictionary dictionaryWithContentsOfFile:path][@"items"]) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            id key = item[@"key"], min = item[@"min"], max = item[@"max"];
            if ([key isKindOfClass:[NSString class]] && [min isKindOfClass:[NSNumber class]] && [max isKindOfClass:[NSNumber class]]) found[key] = @[min, max];
        }
        ranges = found;
    });
    return ranges;
}

// The preferences system has the newest values (from RemoteCompanion, the settings page or the Control Center
// toggle); bring the file up to date, keeping each number in the range the settings page allows
static void SCSyncSettings(void) {
    CFPreferencesAppSynchronize(SC_DOMAIN);
    CFArrayRef keys = CFPreferencesCopyKeyList(SC_DOMAIN, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (!keys) return;
    NSDictionary *latest = CFBridgingRelease(CFPreferencesCopyMultiple(keys, SC_DOMAIN, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    CFRelease(keys);
    NSDictionary *ranges = SCSettingRanges();
    NSMutableDictionary *file = [SCStoredSettings() mutableCopy];
    BOOL changed = NO;
    for (NSString *key in latest) {
        id value = latest[key];
        NSArray *range = ranges[key];
        if (range && [value respondsToSelector:@selector(integerValue)]) {
            NSNumber *clamped = @(MAX([range[0] integerValue], MIN([range[1] integerValue], [value integerValue])));
            if (![clamped isEqual:value]) CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)clamped, SC_DOMAIN);
            value = clamped;
        }
        if (![file[key] isEqual:value]) {
            file[key] = value;
            changed = YES;
        }
    }
    CFPreferencesAppSynchronize(SC_DOMAIN);
    if (changed) [file writeToFile:SCSettingsPath() atomically:YES];
}

// Keeps the states RemoteCompanion's conditions read up to date. A state is announced (posted, which fires
// the add-on's triggers) when it changes, or always when an action about it asked, so its banner shows.
typedef NS_OPTIONS(NSUInteger, SCAnnounce) { SCAnnounceNone = 0, SCAnnounceEnabled = 1, SCAnnounceCalls = 2 };
static int gEnabledToken, gCallsToken, gRunningToken;

static void SCPublishStates(SCAnnounce announce) {
    NSDictionary *stored = SCStoredSettings();
    uint64_t enabled = !SCBoolean(stored, @"Enabled", YES) ? 0 : (SCIsPaused(stored) ? 2 : 1);
    uint64_t calls = SCBoolean(stored, @"CallGuard", NO) ? 1 : 0;
    // The first time after SpringBoard starts only sets the states: nothing changed for the person
    static BOOL started;
    BOOL quiet = !started;
    started = YES;
    uint64_t old = 0;
    notify_get_state(gEnabledToken, &old);
    notify_set_state(gEnabledToken, enabled);
    if (!quiet && ((announce & SCAnnounceEnabled) || old != enabled)) notify_post(SC_STATE_ENABLED);
    notify_get_state(gCallsToken, &old);
    notify_set_state(gCallsToken, calls);
    if (!quiet && ((announce & SCAnnounceCalls) || old != calls)) notify_post(SC_STATE_CALLS);

    // When a pause ends, say so. The time is on the wall clock, which keeps going while the phone sleeps.
    static dispatch_source_t resumeTimer;
    if (resumeTimer) dispatch_source_cancel(resumeTimer);
    resumeTimer = nil;
    if (enabled == 2) {
        double until = [stored[SC_PAUSED_UNTIL_KEY] doubleValue] + 0.5;
        struct timespec when = { .tv_sec = (time_t)until, .tv_nsec = (long)((until - floor(until)) * NSEC_PER_SEC) };
        resumeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(resumeTimer, dispatch_walltime(&when, 0), DISPATCH_TIME_FOREVER, NSEC_PER_SEC);
        dispatch_source_set_event_handler(resumeTimer, ^{
            SCStoreSettings(@{SC_PAUSED_UNTIL_KEY: NSNull.null});
            SCPublishStates(SCAnnounceNone);
        });
        dispatch_resume(resumeTimer);
    }
}

static void SCListen(const char *name, void (^handler)(int token)) {
    int token;
    notify_register_dispatch(name, &token, dispatch_get_main_queue(), handler);
}

static void SCStartRemoteCompanionSpringBoard(void) {
    notify_register_check(SC_STATE_ENABLED, &gEnabledToken);
    notify_register_check(SC_STATE_CALLS, &gCallsToken);
    notify_register_check(SC_STATE_RUNNING, &gRunningToken); // held so the state outlives each post
    SCSetRunning(SC_RUNNING_CALL, NO); // a call countdown doesn't outlive SpringBoard; a message's may still run
    SCSyncSettings();
    SCPublishStates(SCAnnounceNone);

    SCListen(SC_NOTE_CHANGED, ^(int t) {
        SCSyncSettings();
        SCPublishStates(SCAnnounceNone);
    });
    SCListen(SC_NOTE_SET_ENABLED, ^(int t) {
        uint64_t mode = SCNoteState(t);
        NSDictionary *stored = SCStoredSettings();
        BOOL on = mode == 2 ? !(SCBoolean(stored, @"Enabled", YES) && !SCIsPaused(stored)) : mode == 1;
        // Turning on or off also ends a pause
        SCStoreSettings(@{@"Enabled": @(on), SC_PAUSED_UNTIL_KEY: NSNull.null});
        SCPublishStates(SCAnnounceEnabled);
    });
    SCListen(SC_NOTE_SET_CALLS, ^(int t) {
        uint64_t mode = SCNoteState(t);
        BOOL on = mode == 2 ? !SCBoolean(SCStoredSettings(), @"CallGuard", NO) : mode == 1;
        SCStoreSettings(@{@"CallGuard": @(on)});
        SCPublishStates(SCAnnounceCalls);
    });
    SCListen(SC_NOTE_PAUSE, ^(int t) {
        // Nothing to pause while switched off; the banner then says Off
        if (!SCBoolean(SCStoredSettings(), @"Enabled", YES)) {
            SCPublishStates(SCAnnounceEnabled);
            return;
        }
        CFPreferencesAppSynchronize(SC_DOMAIN);
        id value = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("PauseMinutes"), SC_DOMAIN));
        NSInteger minutes = [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 30;
        minutes = MAX(1, MIN(24 * 60, minutes));
        SCStoreSettings(@{SC_PAUSED_UNTIL_KEY: @(NSDate.date.timeIntervalSince1970 + minutes * 60)});
        SCPublishStates(SCAnnounceEnabled);
    });
    SCListen(SC_NOTE_RESUME, ^(int t) {
        SCStoreSettings(@{SC_PAUSED_UNTIL_KEY: NSNull.null});
        SCPublishStates(SCAnnounceEnabled);
    });
    // A call's countdown is SpringBoard's; a message's is the Messages app's, which listens too
    SCListen(SC_NOTE_CANCEL, ^(int t) { if (gCallWindow) [SCCallCancel cancel]; });
    SCListen(SC_NOTE_NOW, ^(int t) { if (gCallWindow) [SCCallCancel callNow]; });
}

static void SCStartRemoteCompanionMessages(void) {
    SCListen(SC_NOTE_CANCEL, ^(int t) {
        if (!gTimer) return;
        SCHaptic(UIImpactFeedbackStyleRigid);
        SCPostState(SC_EVENT_MESSAGE, 2);
        SCStop();
    });
    SCListen(SC_NOTE_NOW, ^(int t) { if (gTimer) SCSendNow(); });
}

%ctor {
    if (strcmp(getprogname(), "callservicesd") == 0) {
        // The daemon's classes may not be registered yet; install a moment after launch, and only then
        // tell the apps to stand down
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            Class controller = NSClassFromString(@"CSDCallStateController");
            if (controller && class_getInstanceMethod(controller, @selector(dialWithRequest:reply:))) {
                %init(SCDaemon);
                static int aliveToken;
                if (notify_register_check(SC_NOTE_ALIVE, &aliveToken) == NOTIFY_STATUS_OK) notify_set_state(aliveToken, 1);
            }
        });
        return;
    }
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
    BOOL messagesApp = [bundle isEqualToString:@"com.apple.MobileSMS"];
    // Replying from a notification (pressing on it) happens in Messages' notification view, a process of its own
    BOOL messages = messagesApp || [bundle isEqualToString:@"com.apple.MobileSMS.MessagesNotificationExtension"];
    if (messages) {
        SCStartRemoteCompanionMessages();
        // A countdown cut off when Messages last quit can't still be running (the notification view starts
        // while Messages may be counting, so only Messages itself clears this)
        if (messagesApp) SCSetRunning(SC_RUNNING_MESSAGE, NO);
        // Coming back from the settings page: a reset made there shows in the list straight away
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            SCApplyReset();
            for (UIWindow *window in UIApplication.sharedApplication.windows) SCRefreshMarkers(window);
        }];
        %init;
        if (NSClassFromString(@"CKComposeChatController") && NSClassFromString(@"CKNotificationChatController")) %init(SCSendSubclasses);
        if (NSClassFromString(@"CKConversationListCollectionViewController")) %init(SCCollectionList);
        if (NSClassFromString(@"CKConversationListController")) %init(SCTableList);
    }
    if ([bundle isEqualToString:@"com.apple.springboard"]) {
        // Listens for countdown requests from apps that have no screen to show one on
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            static int token;
            notify_register_dispatch(SC_NOTE_A, &token, dispatch_get_main_queue(), ^(int t) { SCHandleRemoteRequest(); });
            SCStartRemoteCompanionSpringBoard();
            static int carToken;
            notify_register_dispatch(SC_NOTE_CAR_ANSWER, &carToken, dispatch_get_main_queue(), ^(int t) { SCCarAnswered(SCNoteState(t)); });
        });
    }
    if ([bundle isEqualToString:@"com.apple.CarPlayApp"]) {
        // Shows SpringBoard's countdown on the car's screen
        static int showToken, responseToken;
        notify_register_dispatch(SC_NOTE_CAR_SHOW, &showToken, dispatch_get_main_queue(), ^(int t) { SCCarHandleShow(); });
        notify_register_dispatch(SC_NOTE_RESPONSE, &responseToken, dispatch_get_main_queue(), ^(int t) { SCCarHandleResponse(SCNoteState(t)); });
    }
    if (messagesApp || [@[@"com.apple.mobilephone", @"com.apple.facetime", @"com.apple.MobileAddressBook", @"com.apple.InCallService"] containsObject:bundle]) {
        dlopen("/System/Library/PrivateFrameworks/TelephonyUtilities.framework/TelephonyUtilities", RTLD_LAZY);
        if (NSClassFromString(@"TUCallCenter")) %init(SCCalls);
        // Contact cards live in a framework that may load only when first opened
        dlopen("/System/Library/PrivateFrameworks/ContactsUICore.framework/ContactsUICore", RTLD_LAZY);
        if (NSClassFromString(@"_CNUIUserActionDialRequestOpener")) %init(SCContactsCalls);
        if (NSClassFromString(@"LSApplicationWorkspace")) %init(SCWorkspaceCalls);
        dlopen("/System/Library/Frameworks/ContactsUI.framework/ContactsUI", RTLD_LAZY);
        if (NSClassFromString(@"CNContactInlineActionsViewController")) %init(SCInlineActions);
    }
}
