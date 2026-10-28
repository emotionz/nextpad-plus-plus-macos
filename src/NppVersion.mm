#import "NppVersion.h"

NSString *NppForkVersion(void) {
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.1.2-rc1";
}

NSString *NppUpstreamBaseVersion(void) {
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NppUpstreamBaseVersion"] ?: @"1.1.2";
}

NSString *NppNormalizedReleaseVersion(NSString *version) {
    if (![version isKindOfClass:NSString.class]) return nil;
    NSString *value = [version stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([value.lowercaseString hasPrefix:@"v"]) value = [value substringFromIndex:1];
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:
        @"^[0-9]+\\.[0-9]+\\.[0-9]+$" options:0 error:nil];
    return [pattern numberOfMatchesInString:value options:0 range:NSMakeRange(0, value.length)] == 1 ? value : nil;
}

BOOL NppUpstreamReleaseIsNewer(NSString *version) {
    NSString *latest = NppNormalizedReleaseVersion(version);
    NSString *base = NppNormalizedReleaseVersion(NppUpstreamBaseVersion());
    return latest && base && [latest compare:base options:NSNumericSearch] == NSOrderedDescending;
}
