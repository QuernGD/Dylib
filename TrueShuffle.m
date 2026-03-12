/*
 * TrueShuffle.m
 *
 * Standalone dylib for sideloaded Spotify (9.1.x, arm64e, iOS 15+).
 * Injects via dylib injection into the IPA before signing.
 *
 * Features:
 *   - Blocks Spotify's weighted recommendation shuffle pipeline
 *   - Adds a "True Shuffle" toggle into Spotify's existing Shuffle settings section
 *   - Persists toggle state in NSUserDefaults
 *
 * Hook strategy:
 *   Uses ObjC runtime method swizzling (+load / method_exchangeImplementations).
 *   No Substrate, no Orion, no Theos required at runtime.
 *
 * Pipeline blocked when enabled:
 *   SPTFreeShuffleRecommendationsService  → fetch methods → no-op
 *   SPTSmartShuffleHandler                → state flags   → false
 *
 * Settings injection:
 *   Hooks ShuffleSettingsUISection to append a native SettingsSwitchTableViewCell
 *   row into Spotify's existing Shuffle section in Settings.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---------------------------------------------------------------------------
// MARK: - Constants
// ---------------------------------------------------------------------------

static NSString *const kTrueShuffleKey    = @"com.trueshuffle.enabled";
static NSString *const kTrueShuffleLabel  = @"True Shuffle";
static NSString *const kTrueShuffleDesc   = @"Disable Spotify's weighted recommendation shuffle and play tracks in a purely random order.";
static NSString *const kTrueShuffleLog    = @"[TrueShuffle]";

// ---------------------------------------------------------------------------
// MARK: - State helpers
// ---------------------------------------------------------------------------

static BOOL TrueShuffle_isEnabled(void) {
    // Default ON — user has to opt out rather than opt in
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud objectForKey:kTrueShuffleKey] == nil) {
        [ud setBool:YES forKey:kTrueShuffleKey];
    }
    return [ud boolForKey:kTrueShuffleKey];
}

// ---------------------------------------------------------------------------
// MARK: - Hook 1: SPTFreeShuffleRecommendationsService
//
// Replaces recommendation fetch/load methods with no-ops so no recommended
// tracks are injected into the shuffle queue.
// ---------------------------------------------------------------------------

// Original IMPs stored for passthrough when TrueShuffle is disabled
static IMP orig_fetchRecommendTracks_noURL   = NULL;
static IMP orig_fetchRecommendTracks_withURL = NULL;
static IMP orig_shuffledRecommendations      = NULL;
static IMP orig_recommendedTracks            = NULL;
static IMP orig_loadRecommendations          = NULL;
static IMP orig_fetchRecommendations         = NULL;

static void hook_fetchRecommendTracks_noURL(
    id self, SEL _cmd,
    id name, id currentTracks, id skipTracks,
    NSInteger minResults, id decorationPolicy, id completion
) {
    if (!TrueShuffle_isEnabled()) {
        ((void(*)(id,SEL,id,id,id,NSInteger,id,id))orig_fetchRecommendTracks_noURL)
            (self, _cmd, name, currentTracks, skipTracks, minResults, decorationPolicy, completion);
    }
    // else: drop — no recommendations injected
}

static void hook_fetchRecommendTracks_withURL(
    id self, SEL _cmd,
    id name, id playlistURL, id currentTracks, id skipTracks,
    NSInteger minResults, id decorationPolicy, id completion
) {
    if (!TrueShuffle_isEnabled()) {
        ((void(*)(id,SEL,id,id,id,id,NSInteger,id,id))orig_fetchRecommendTracks_withURL)
            (self, _cmd, name, playlistURL, currentTracks, skipTracks, minResults, decorationPolicy, completion);
    }
}

static id hook_shuffledRecommendations(id self, SEL _cmd) {
    if (TrueShuffle_isEnabled()) return nil;
    return ((id(*)(id,SEL))orig_shuffledRecommendations)(self, _cmd);
}

static id hook_recommendedTracks(id self, SEL _cmd) {
    if (TrueShuffle_isEnabled()) return nil;
    return ((id(*)(id,SEL))orig_recommendedTracks)(self, _cmd);
}

static void hook_loadRecommendations(id self, SEL _cmd) {
    if (!TrueShuffle_isEnabled()) {
        ((void(*)(id,SEL))orig_loadRecommendations)(self, _cmd);
    }
}

static void hook_fetchRecommendations(id self, SEL _cmd) {
    if (!TrueShuffle_isEnabled()) {
        ((void(*)(id,SEL))orig_fetchRecommendations)(self, _cmd);
    }
}

// ---------------------------------------------------------------------------
// MARK: - Hook 2: SPTSmartShuffleHandler
//
// Forces all smart shuffle state flags to return NO/false, preventing the
// player from ever entering smart shuffle mode.
// ---------------------------------------------------------------------------

static IMP orig_isSmartShuffleAllowed      = NULL;
static IMP orig_isSmartShuffleSupported    = NULL;
static IMP orig_isSmartShuffled            = NULL;
static IMP orig_isSmartShuffleExpEnabled   = NULL;
static IMP orig_canToggleSmartShuffle      = NULL;
static IMP orig_enableSmartShuffle         = NULL;

static BOOL hook_isSmartShuffleAllowed(id self, SEL _cmd) {
    if (TrueShuffle_isEnabled()) return NO;
    return ((BOOL(*)(id,SEL))orig_isSmartShuffleAllowed)(self, _cmd);
}

static BOOL hook_isSmartShuffleSupported(id self, SEL _cmd) {
    if (TrueShuffle_isEnabled()) return NO;
    return ((BOOL(*)(id,SEL))orig_isSmartShuffleSupported)(self, _cmd);
}

static BOOL hook_isSmartShuffled(id self, SEL _cmd) {
    if (TrueShuffle_isEnabled()) return NO;
    return ((BOOL(*)(id,SEL))orig_isSmartShuffled)(self, _cmd);
}

static BOOL hook_isSmartShuffleExperimentEnabled(id self, SEL _cmd) {
    if (TrueShuffle_isEnabled()) return NO;
    return ((BOOL(*)(id,SEL))orig_isSmartShuffleExpEnabled)(self, _cmd);
}

static BOOL hook_canToggleSmartShuffle(id self, SEL _cmd) {
    if (TrueShuffle_isEnabled()) return NO;
    return ((BOOL(*)(id,SEL))orig_canToggleSmartShuffle)(self, _cmd);
}

static void hook_enableSmartShuffle(id self, SEL _cmd) {
    if (!TrueShuffle_isEnabled()) {
        ((void(*)(id,SEL))orig_enableSmartShuffle)(self, _cmd);
    }
}

// ---------------------------------------------------------------------------
// MARK: - Hook 3: ShuffleSettingsUISection
//
// Appends a True Shuffle toggle row into Spotify's existing Shuffle settings
// section using Spotify's own SettingsSwitchTableViewCell infrastructure.
// ---------------------------------------------------------------------------

static IMP orig_setupSettingsPageWithItem = NULL;

static void hook_setupSettingsPageWithItem(id self, SEL _cmd, id item) {
    // Call original first so Spotify's own rows are built
    ((void(*)(id,SEL,id))orig_setupSettingsPageWithItem)(self, _cmd, item);

    // Now append our toggle using Spotify's switchItem factory
    // switchItemWithLabel:description:initialState:userDefaultsKey:falseValue:trueValue:
    Class settingsClass = NSClassFromString(@"ShuffleSettingsUISection");
    if (!settingsClass) return;

    SEL switchSel = NSSelectorFromString(
        @"switchItemWithLabel:description:initialState:userDefaultsKey:falseValue:trueValue:"
    );

    if (![self respondsToSelector:switchSel]) return;

    BOOL current = TrueShuffle_isEnabled();

    id switchItem = ((id(*)(id,SEL,NSString*,NSString*,BOOL,NSString*,id,id))objc_msgSend)
        (self, switchSel,
         kTrueShuffleLabel,
         kTrueShuffleDesc,
         current,
         kTrueShuffleKey,
         @NO,   // falseValue
         @YES   // trueValue
        );

    if (!switchItem) return;

    SEL addItemSel = NSSelectorFromString(@"setupSettingsPageWithSwitchItem:");
    if ([self respondsToSelector:addItemSel]) {
        ((void(*)(id,SEL,id))objc_msgSend)(self, addItemSel, switchItem);
    }

    NSLog(@"%@ Injected True Shuffle toggle into Shuffle settings section", kTrueShuffleLog);
}

// ---------------------------------------------------------------------------
// MARK: - Swizzle helper
// ---------------------------------------------------------------------------

static BOOL swizzle(Class cls, SEL original, IMP replacement, IMP *outOrig) {
    if (!cls) {
        NSLog(@"%@ Class not found for selector: %@", kTrueShuffleLog, NSStringFromSelector(original));
        return NO;
    }
    Method m = class_getInstanceMethod(cls, original);
    if (!m) {
        // Try class method
        m = class_getClassMethod(cls, original);
        if (!m) {
            NSLog(@"%@ Method not found: %@ on %@", kTrueShuffleLog, NSStringFromSelector(original), NSStringFromClass(cls));
            return NO;
        }
    }
    *outOrig = method_setImplementation(m, replacement);
    NSLog(@"%@ ✓ Swizzled %@ on %@", kTrueShuffleLog, NSStringFromSelector(original), NSStringFromClass(cls));
    return YES;
}

// ---------------------------------------------------------------------------
// MARK: - Entry point
// ---------------------------------------------------------------------------

__attribute__((constructor))
static void TrueShuffle_init(void) {
    NSLog(@"%@ Initializing — TrueShuffle %s", kTrueShuffleLog, "1.0.0");
    NSLog(@"%@ True Shuffle currently: %@", kTrueShuffleLog, TrueShuffle_isEnabled() ? @"ON" : @"OFF");

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            // Hook 1 — Recommendation fetch layer
            Class recsClass = NSClassFromString(@"SPTFreeShuffleRecommendationsService");
            if (recsClass) {
                swizzle(recsClass,
                    NSSelectorFromString(@"fetchRecommendTracksForPlaylistName:currentTracks:skipTracks:minResults:decorationPolicy:completion:"),
                    (IMP)hook_fetchRecommendTracks_noURL, &orig_fetchRecommendTracks_noURL);

                swizzle(recsClass,
                    NSSelectorFromString(@"fetchRecommendTracksForPlaylistName:playlistURL:currentTracks:skipTracks:minResults:decorationPolicy:completion:"),
                    (IMP)hook_fetchRecommendTracks_withURL, &orig_fetchRecommendTracks_withURL);

                swizzle(recsClass,
                    NSSelectorFromString(@"shuffledRecommendations"),
                    (IMP)hook_shuffledRecommendations, &orig_shuffledRecommendations);

                swizzle(recsClass,
                    NSSelectorFromString(@"recommendedTracks"),
                    (IMP)hook_recommendedTracks, &orig_recommendedTracks);

                swizzle(recsClass,
                    NSSelectorFromString(@"loadRecommendations"),
                    (IMP)hook_loadRecommendations, &orig_loadRecommendations);

                swizzle(recsClass,
                    NSSelectorFromString(@"fetchRecommendations"),
                    (IMP)hook_fetchRecommendations, &orig_fetchRecommendations);
            } else {
                NSLog(@"%@ ✗ SPTFreeShuffleRecommendationsService not found", kTrueShuffleLog);
            }

            // Hook 2 — Smart shuffle state layer
            Class handlerClass = NSClassFromString(@"SPTSmartShuffleHandler");
            if (handlerClass) {
                swizzle(handlerClass,
                    NSSelectorFromString(@"isSmartShuffleAllowed"),
                    (IMP)hook_isSmartShuffleAllowed, &orig_isSmartShuffleAllowed);

                swizzle(handlerClass,
                    NSSelectorFromString(@"isSmartShuffleSupported"),
                    (IMP)hook_isSmartShuffleSupported, &orig_isSmartShuffleSupported);

                swizzle(handlerClass,
                    NSSelectorFromString(@"isSmartShuffled"),
                    (IMP)hook_isSmartShuffled, &orig_isSmartShuffled);

                swizzle(handlerClass,
                    NSSelectorFromString(@"isSmartShuffleExperimentEnabled"),
                    (IMP)hook_isSmartShuffleExperimentEnabled, &orig_isSmartShuffleExpEnabled);

                swizzle(handlerClass,
                    NSSelectorFromString(@"canToggleSmartShuffle"),
                    (IMP)hook_canToggleSmartShuffle, &orig_canToggleSmartShuffle);

                swizzle(handlerClass,
                    NSSelectorFromString(@"enableSmartShuffle"),
                    (IMP)hook_enableSmartShuffle, &orig_enableSmartShuffle);
            } else {
                NSLog(@"%@ ✗ SPTSmartShuffleHandler not found", kTrueShuffleLog);
            }

            // Hook 3 — Settings UI injection
            Class settingsSection = NSClassFromString(@"ShuffleSettingsUISection");
            if (settingsSection) {
                swizzle(settingsSection,
                    NSSelectorFromString(@"setupSettingsPageWithItem:"),
                    (IMP)hook_setupSettingsPageWithItem, &orig_setupSettingsPageWithItem);
            } else {
                NSLog(@"%@ ✗ ShuffleSettingsUISection not found — toggle not injected", kTrueShuffleLog);
            }

            NSLog(@"%@ Initialization complete", kTrueShuffleLog);
        }
    );
}
