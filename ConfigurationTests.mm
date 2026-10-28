#import <Cocoa/Cocoa.h>
#import "NppUIConfiguration.h"
#import "NppVersion.h"
#import "MenuBuilder.h"
#import "NppLocalizer.h"

static void check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults removeObjectForKey:NppToolbarVisibilityOverrides];
        [defaults removeObjectForKey:NppMenuVisibilityOverrides];
        check([NppForkVersion() hasPrefix:[NppUpstreamBaseVersion() stringByAppendingString:@"-rc"]], @"packaged fork version");
        check([NppUpstreamBaseVersion() isEqual:@"1.1.2"], @"independent upstream base");
        check(!NppUpstreamReleaseIsNewer(@"v1.1.2"), @"same base must not trigger an update for rc fork");
        check(NppUpstreamReleaseIsNewer(@"v1.1.3"), @"higher patch release");
        check(NppUpstreamReleaseIsNewer(@"1.1.10"), @"numeric version comparison");
        check(!NppUpstreamReleaseIsNewer(@"v1.1.1"), @"older upstream release");
        for (id value in @[@"1.1.3-rc1", @"bad", @"1.2", NSNull.null, @[]])
            check(!NppUpstreamReleaseIsNewer(value), @"invalid or prerelease version rejected");
        check(NppToolbarItemVisible(@"TB_Copy", YES), @"unconfigured button honors existing visibility");
        [defaults setObject:@{@"TB_New": @NO, @"TB_Open": @NO, @"TB_Save": @NO, @"TB_Copy": @NO, @"TB_Project": @YES}
                    forKey:NppToolbarVisibilityOverrides];
        for (NSString *identifier in @[@"TB_New", @"TB_Open", @"TB_Save"])
            check(NppToolbarItemVisible(identifier, NO), @"required buttons cannot be hidden");
        check(!NppToolbarItemVisible(@"TB_Copy", YES), @"hide ordinary button");
        check(NppToolbarItemVisible(@"TB_Project", NO), @"restore a previously hidden button");
        NSDictionary *pluginA = @{@"pluginDir": @"PluginA", @"tooltip": @"Format"};
        NSDictionary *pluginB = @{@"pluginDir": @"PluginB", @"tooltip": @"Format"};
        check(![NppPluginToolbarIdentifier(pluginA) isEqual:NppPluginToolbarIdentifier(pluginB)], @"plugin command visibility is scoped to its plugin");
        [defaults removeObjectForKey:NppToolbarVisibilityOverrides];
        check(NppToolbarItemVisible(@"TB_Copy", YES), @"reset restores original visibility");

        [MenuBuilder buildMainMenu];
        NSArray *tags = @[@(kMenuTagMacro), @(kMenuTagRun), @(kMenuTagWindow), @(kMenuTagHelp)];
        for (NSNumber *tag in tags) check(![NSApp.mainMenu itemWithTag:tag.integerValue].hidden, @"menus shown by default");
        [defaults setObject:@{@"macro": @NO, @"run": @NO, @"window": @NO, @"help": @NO} forKey:NppMenuVisibilityOverrides];
        [MenuBuilder applyVisibility];
        for (NSNumber *tag in tags) {
            NSMenuItem *item = [NSApp.mainMenu itemWithTag:tag.integerValue];
            check(item.hidden && item.allowsKeyEquivalentWhenHidden, @"menu hide retains shortcut eligibility");
        }
        BOOL preferencesVisible = NO;
        for (NSMenuItem *item in NSApp.mainMenu.itemArray.firstObject.submenu.itemArray) {
            if (item.action == @selector(showPreferences:)) preferencesVisible = !item.hidden;
            if (item.action == @selector(installCommandLineTool:)) check(item.hidden, @"CLI installer hidden");
        }
        check(preferencesVisible, @"Preferences remains accessible");
        [defaults removeObjectForKey:NppMenuVisibilityOverrides]; [MenuBuilder applyVisibility];
        for (NSNumber *tag in tags) check(![NSApp.mainMenu itemWithTag:tag.integerValue].hidden, @"menu reset");

        NppLocalizer *loc = NppLocalizer.shared;
        check([loc loadLanguageNamed:@"chineseSimplified"], @"load bundled Chinese language");
        for (NSString *text in @[@"Function Visibility", @"Menu Bar", @"Check Upstream Releases…", @"Base64 Decode (Strict Mode)", @"Show Control Characters & Unicode EOL"])
            check(![[loc translate:text] isEqual:text], [@"translation: " stringByAppendingString:text]);
        for (NSString *term in @[@"JSON", @"XML", @"UTF-8", @"Git", @"API", @"Python"])
            check([[loc translate:term] isEqual:term], [@"technical term preserved: " stringByAppendingString:term]);
        check(![[loc translate:@"Ascending"] isEqual:[loc translate:@"Ascending (case-insensitive)"]], @"sort variants keep distinct translations");
        check([[loc translate:@"Base64 Decode (Strict Mode)"] containsString:@"严格"], @"strict Base64 mode is labeled");
        check(![[loc translate:@"Base64 Decode"] isEqual:[loc translate:@"Base64 Decode (Strict Mode)"]], @"Base64 modes keep distinct translations");
        // Recursive translation, including a third-level menu item.
        NSMenu *root = [[NSMenu alloc] initWithTitle:@"Tools"];
        NSMenuItem *parent = [[NSMenuItem alloc] initWithTitle:@"Converter" action:nil keyEquivalent:@""];
        NSMenu *second = [[NSMenu alloc] initWithTitle:@"Converter"];
        NSMenuItem *child = [[NSMenuItem alloc] initWithTitle:@"Base64" action:nil keyEquivalent:@""];
        NSMenu *third = [[NSMenu alloc] initWithTitle:@"Base64"];
        NSMenuItem *command = [[NSMenuItem alloc] initWithTitle:@"Base64 Decode (Strict Mode)" action:nil keyEquivalent:@""];
        [third addItem:command]; child.submenu = third; [second addItem:child]; parent.submenu = second; [root addItem:parent];
        NSApp.mainMenu = root; [loc applyToMainMenu];
        check([command.title containsString:@"解码"], @"third-level menu translation");
        check([parent.title isEqual:@"转换工具"], @"second-level menu translation");
        check([loc loadLanguageNamed:@"english"], @"switch back to English");
        check([command.title isEqual:@"Base64 Decode (Strict Mode)"], @"restore original menu title");
        NSLog(@"PASS: configuration, version and recursive localization checks");
    }
    return 0;
}
