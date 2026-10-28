#import <Foundation/Foundation.h>

NSString *NppForkVersion(void);
NSString *NppUpstreamBaseVersion(void);
NSString *NppNormalizedReleaseVersion(NSString *version);
BOOL NppUpstreamReleaseIsNewer(NSString *version);
