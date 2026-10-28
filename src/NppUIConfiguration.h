#import <Cocoa/Cocoa.h>

extern NSString *const NppToolbarVisibilityChanged;
extern NSString *const NppToolbarVisibilityOverrides;
extern NSString *const NppMenuVisibilityOverrides;

BOOL NppToolbarItemRequired(NSString *identifier);
BOOL NppToolbarItemVisible(NSString *identifier, BOOL defaultVisible);
NSString *NppPluginToolbarIdentifier(NSDictionary *item);
