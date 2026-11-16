#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@interface PSListController : UITableViewController
- (id)specifiers;
@end

@interface CRPRootListController : PSListController <AVAudioPlayerDelegate>
@end
