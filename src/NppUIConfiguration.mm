#import "NppUIConfiguration.h"

NSString *const NppToolbarVisibilityChanged = @"NppToolbarVisibilityChanged";
NSString *const NppToolbarVisibilityOverrides = @"toolbarVisibilityOverrides";
NSString *const NppMenuVisibilityOverrides = @"menuVisibilityOverrides";

BOOL NppToolbarItemRequired(NSString *identifier) {
    return [@[@"TB_New", @"TB_Open", @"TB_Save"] containsObject:identifier];
}

BOOL NppToolbarItemVisible(NSString *identifier, BOOL defaultVisible) {
    if (NppToolbarItemRequired(identifier)) return YES;
    NSNumber *value = [[NSUserDefaults standardUserDefaults]
        dictionaryForKey:NppToolbarVisibilityOverrides][identifier];
    return value ? value.boolValue : defaultVisible;
}

NSString *NppPluginToolbarIdentifier(NSDictionary *item) {
    return [NSString stringWithFormat:@"plugin:%@\n%@",
        item[@"pluginDir"] ?: @"", item[@"tooltip"] ?: @""];
}
