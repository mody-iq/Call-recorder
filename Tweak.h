#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudioTypes.h>
#include <substrate.h>
#include <roothide.h>

#define CRP_DARWIN_START_NOTIFICATION CFSTR("com.relaxin.callrecorder/start")
#define CRP_DARWIN_STOP_NOTIFICATION  CFSTR("com.relaxin.callrecorder/stop")

@interface TUCall : NSObject
@property (nonatomic, readonly) int status;
@end

@interface TUCallCenter : NSObject
+ (instancetype)sharedInstance;
@property (nonatomic, copy, readonly) NSArray<TUCall *> *currentCalls;
@end

@interface PHAudioCallViewController : UIViewController
@end

@interface CNKFaceTimeInCallViewController : UIViewController
@end

@interface CRPFloatingRecorderView : UIView
@property (nonatomic, assign, readonly) BOOL isRecording;
- (void)stopRecordingIfNeeded;
@end
