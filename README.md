# Mull

Mull gives you a moment to change your mind. Tap Send in Messages and the button counts down before the message goes out; tap it to cancel. Phone and FaceTime calls get the same pause, with a full-screen countdown and buttons to cancel or call right away. Works on iOS 15 to 18.

## Features

### Messages

- **Countdown on Send**: the button turns into a countdown in a color of your choice, with a ring that drains and a haptic each second. Tap it to cancel; the message stays in the field.
- **Keeps going in the background**: leave the app and the message still goes out when the countdown ends.
- **Delays**: one for regular messages, one for the first message in a conversation, one for messages with attachments. Adding an attachment during the countdown lengthens it to the attachment delay, counted from the tap.
- **Short messages**: messages shorter than a set number of characters send right away.
- **Skip a conversation**: swipe a conversation to the left in Messages to turn its countdown off or on. A bolt beside its date marks it. Reset Skipped Conversations in settings clears them all.
- Emptying the message during the countdown stops it.
- Changing conversations during the countdown sends the pending message first.

### Calls

- **Phone and FaceTime**: a call counts down on a blurred full screen showing the contact's photo and name (or the number), and the kind of call: Phone Call, FaceTime Audio or FaceTime Video. Cancel stops the call; Call Now skips the wait.
- **Wherever the call starts**: recents, Contacts, contact cards, the keypad, Messages, missed-call notifications and more. The hold happens in the call service, so one place covers every route.
- **Emergency calls are never delayed.** Only a plain outgoing call to a number longer than three digits is held, and nothing is held when the tweak can't tell for sure.
- Off by default; switch on Call Countdown in settings.

### Settings

- Enabled, delays, minimum length, countdown color, haptics, progress ring, Call Countdown and its delay.
- **Control Center toggle** (needs CCSupport) to turn the tweak on and off.
- **Translations**: German, Spanish, French, Italian, Japanese, Korean, Dutch, Portuguese (Brazil), Russian, Chinese (Simplified and Traditional), Turkish and Polish. Machine-written and not reviewed by native speakers; corrections are welcome.

## Requirements

- iOS 15 to 18, jailbroken: rootless, roothide or rootful.
- PreferenceLoader. CCSupport for the Control Center toggle.

## Tested

| | Messages | Calls |
| --- | --- | --- |
| iOS 15.4.1 (rootless, device) | yes | yes |
| iOS 16.4 (simulator) | yes | not testable |
| iOS 17.0 (rootless, device) | yes | yes |
| iOS 18.6 (simulator) | yes | not testable |

The roothide and rootful packages build but have not been run on a device. The names of the private methods the call code uses were checked on iOS 16.4, 18.0 and 18.6 and match iOS 17; whether calls behave identically there has not been seen.

## Building

Needs [Theos](https://theos.dev). `./build.sh` builds all three packages into `packages/`:

- `*_iphoneos-arm64.deb`: rootless
- `*_iphoneos-arm64e.deb`: roothide (needs [roothide's Theos](https://github.com/roothide/theos), at `~/theos-roothide` or `$THEOS_ROOTHIDE`)
- `*_iphoneos-arm.deb`: rootful

Or one at a time: `make package` (rootless), `make package THEOS=<roothide Theos> THEOS_PACKAGE_SCHEME=roothide` (roothide) or `make package THEOS_PACKAGE_SCHEME=` (rootful).

### Testing Messages in the simulator

`make SIM=1` builds the tweak alone for the iOS Simulator (x86_64, hooks through the ObjC runtime, no Substrate). It reads its settings from `/tmp/mull-sim/`, in the same format the settings page writes. Load it into a simulator the way simject does, then open Messages:

```
xcrun simctl spawn <device> launchctl setenv DYLD_INSERT_LIBRARIES <path>/Mull.dylib
xcrun simctl launch <device> com.apple.MobileSMS
```

Calls need the call service and can't be tested this way.

## Publishing

Released through the [GoldenAppleGuy repo](https://goldenappleguy.github.io/repo/) ([GoldenAppleGuy/repo](https://github.com/GoldenAppleGuy/repo)). To publish a new version:

1. Raise `Version` in `control` and add it to the changelog in `tools/depiction.json`; commit.
2. `./build.sh` (all three packages into `packages/`).
3. `python3 tools/update_repo.py <checkout of GoldenAppleGuy/repo>`, then commit and push that checkout. The package icon goes in `icons/` there, named after the package.
4. Tag and release here with the packages attached.

## Layout

| Path | What |
| --- | --- |
| `Tweak.x` | The tweak: Messages, the call hold in the call service, the countdown screen in SpringBoard |
| `prefs/` | Settings page (PreferenceLoader bundle) |
| `prefs/Localization/generate.py` | Translations: writes each language's `Root.strings` (settings page) and `Tweak.strings` (countdown screen, swipe action); run after changing any text |
| `ccmodule/` | Control Center toggle (CCSupport bundle) |
| `layout/` | PreferenceLoader entry |
| `tools/update_repo.py`, `tools/depiction.json` | Publishing to the package repo, and its Sileo package page |

## How it works

**Messages.** The hook is on `-[CKChatController messageEntryViewSendButtonHit:]` (and the new-message and notification-reply controllers that override it). The first tap starts the countdown and returns without sending; when it ends, the original method runs. The countdown circle is drawn on the Send button, which is `sendButton` on iOS 15 to 17 and `arrowButton` on iOS 18.

**Calls.** `callservicesd` sees every call request before a call exists. The tweak holds the request in `-[CSDCallStateController dialWithRequest:displayContext:]` (and the FaceTime join step) while SpringBoard shows the countdown; the answer comes back through system notifications whose state carries the request. When the daemon hook is active, the per-app hooks (Phone, Contacts, FaceTime, in-call app) stand down, except for holding the app's request to open its call screen so nothing of it shows during the countdown.

**Settings.** The settings page writes every change to its own files, since iOS saves preferences late and Messages is sandboxed away from the preferences service.

## Settings

Stored in the `com.goldenappleguy.mull` domain, and mirrored to files in the Preferences folder.

## License

MIT. See [LICENSE](LICENSE).
