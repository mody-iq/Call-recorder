#import "Tweak.h"
#import "AudioRecorderEngine.h"

static CRPFloatingRecorderView *gFloatingRecorderView = nil;

@interface CRPFloatingRecorderView ()
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIView *dotView;
@property (nonatomic, strong) UILabel *timerLabel;
@property (nonatomic, strong) NSTimer *elapsedTimer;
@property (nonatomic, assign) NSInteger elapsedSeconds;
@property (nonatomic, assign, readwrite) BOOL isRecording;
@end

@implementation CRPFloatingRecorderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
        self.layer.cornerRadius = 22.0;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;

        _dotView = [[UIView alloc] initWithFrame:CGRectMake(14, 15, 14, 14)];
        _dotView.layer.cornerRadius = 7.0;
        _dotView.backgroundColor = [UIColor systemRedColor];
        _dotView.userInteractionEnabled = NO;
        [self addSubview:_dotView];

        _timerLabel = [[UILabel alloc] initWithFrame:CGRectMake(36, 0, 76, 44)];
        _timerLabel.text = @"00:00";
        _timerLabel.textColor = [UIColor whiteColor];
        _timerLabel.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightSemibold];
        _timerLabel.textAlignment = NSTextAlignmentLeft;
        _timerLabel.userInteractionEnabled = NO;
        [self addSubview:_timerLabel];

        _toggleButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _toggleButton.frame = self.bounds;
        _toggleButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_toggleButton addTarget:self action:@selector(handleTap) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_toggleButton];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        _isRecording = NO;
        _elapsedSeconds = 0;
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *superview = self.superview;
    if (!superview) return;

    CGPoint translation = [gesture translationInView:superview];
    CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);

    CGFloat halfW = CGRectGetWidth(self.bounds) / 2.0;
    CGFloat halfH = CGRectGetHeight(self.bounds) / 2.0;
    newCenter.x = MAX(halfW + 8.0, MIN(CGRectGetWidth(superview.bounds) - halfW - 8.0, newCenter.x));
    newCenter.y = MAX(halfH + 44.0, MIN(CGRectGetHeight(superview.bounds) - halfH - 20.0, newCenter.y));

    self.center = newCenter;
    [gesture setTranslation:CGPointZero inView:superview];
}

- (void)handleTap {
    if (self.isRecording) {
        [self stopRecordingUI];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CRP_DARWIN_STOP_NOTIFICATION,
                                             NULL, NULL, true);
    } else {
        [self startRecordingUI];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CRP_DARWIN_START_NOTIFICATION,
                                             NULL, NULL, true);
    }
}

- (void)startRecordingUI {
    self.isRecording = YES;
    self.elapsedSeconds = 0;
    self.timerLabel.text = @"00:00";
    self.backgroundColor = [UIColor colorWithRed:0.65 green:0.08 blue:0.08 alpha:0.9];

    [self.elapsedTimer invalidate];
    self.elapsedTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                          target:self
                                                        selector:@selector(tickTimer)
                                                        userInfo:nil
                                                         repeats:YES];
}

- (void)stopRecordingUI {
    self.isRecording = NO;
    [self.elapsedTimer invalidate];
    self.elapsedTimer = nil;
    self.elapsedSeconds = 0;
    self.timerLabel.text = @"00:00";
    self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
}

- (void)stopRecordingIfNeeded {
    if (self.isRecording) {
        [self stopRecordingUI];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CRP_DARWIN_STOP_NOTIFICATION,
                                             NULL, NULL, true);
    }
}

- (void)tickTimer {
    self.elapsedSeconds += 1;
    NSInteger minutes = self.elapsedSeconds / 60;
    NSInteger seconds = self.elapsedSeconds % 60;
    self.timerLabel.text = [NSString stringWithFormat:@"%02ld:%02ld", (long)minutes, (long)seconds];
}

@end

// ============================================================================
// Group 1: InCallServiceUI
// ============================================================================
%group InCallServiceUI

%hook PHAudioCallViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    if (!gFloatingRecorderView) {
        CGFloat width = 116.0;
        CGFloat height = 44.0;
        CGFloat xPos = MAX(16.0, CGRectGetWidth(self.view.bounds) - width - 16.0);
        CGFloat yPos = 64.0;
        gFloatingRecorderView = [[CRPFloatingRecorderView alloc] initWithFrame:CGRectMake(xPos, yPos, width, height)];
        gFloatingRecorderView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    }

    if (gFloatingRecorderView.superview != self.view) {
        [self.view addSubview:gFloatingRecorderView];
    }
    [self.view bringSubviewToFront:gFloatingRecorderView];
}

%end

static void CRPHandleCallStatusChanged(NSNotification *note) {
    id call = note.object;
    if (call && [call respondsToSelector:@selector(status)]) {
        int status = [(TUCall *)call status];
        // TUCallStatusDisconnected == 6
        if (status == 6) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [gFloatingRecorderView stopRecordingIfNeeded];
            });
        }
    }
}

%end

// ============================================================================
// Group 2: AudioDaemonHooks (mediaserverd / audiomxd)
// ============================================================================
%group AudioDaemonHooks

static OSStatus (*orig_AudioUnitRender)(AudioUnit inUnit,
                                        AudioUnitRenderActionFlags *ioActionFlags,
                                        const AudioTimeStamp *inTimeStamp,
                                        UInt32 inBusNumber,
                                        UInt32 inNumberFrames,
                                        AudioBufferList *ioData);

static OSStatus hooked_AudioUnitRender(AudioUnit inUnit,
                                       AudioUnitRenderActionFlags *ioActionFlags,
                                       const AudioTimeStamp *inTimeStamp,
                                       UInt32 inBusNumber,
                                       UInt32 inNumberFrames,
                                       AudioBufferList *ioData) {
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);

    AudioRecorderEngine *engine = [AudioRecorderEngine sharedInstance];
    if (status == noErr && engine.isRecording && ioData != NULL && inNumberFrames > 0) {
        AudioStreamBasicDescription asbd;
        memset(&asbd, 0, sizeof(asbd));
        UInt32 propSize = sizeof(asbd);
        OSStatus fmtStatus = AudioUnitGetProperty(inUnit,
                                                  kAudioUnitProperty_StreamFormat,
                                                  kAudioUnitScope_Output,
                                                  inBusNumber,
                                                  &asbd,
                                                  &propSize);
        if (fmtStatus == noErr) {
            [engine appendAudioBufferList:ioData frames:inNumberFrames format:asbd];
        }
    }

    return status;
}

static void CRPStartNotificationCallback(CFNotificationCenterRef center,
                                         void *observer,
                                         CFStringRef name,
                                         const void *object,
                                         CFDictionaryRef userInfo) {
    [[AudioRecorderEngine sharedInstance] startRecording];
}

static void CRPStopNotificationCallback(CFNotificationCenterRef center,
                                        void *observer,
                                        CFStringRef name,
                                        const void *object,
                                        CFDictionaryRef userInfo) {
    [[AudioRecorderEngine sharedInstance] stopRecording];
}

%end

// ============================================================================
// Constructor
// ============================================================================
%ctor {
    @autoreleasepool {
        NSString *processName = [NSProcessInfo processInfo].processName;

        if ([processName isEqualToString:@"InCallService"]) {
            %init(InCallServiceUI);
            [[NSNotificationCenter defaultCenter] addObserverForName:@"TUCallCenterCallStatusChangedNotification"
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                CRPHandleCallStatusChanged(note);
            }];
        } else if ([processName isEqualToString:@"mediaserverd"] || [processName isEqualToString:@"audiomxd"]) {
            %init(AudioDaemonHooks);

            CFNotificationCenterRef darwinCenter = CFNotificationCenterGetDarwinNotifyCenter();
            CFNotificationCenterAddObserver(darwinCenter,
                                            NULL,
                                            CRPStartNotificationCallback,
                                            CRP_DARWIN_START_NOTIFICATION,
                                            NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(darwinCenter,
                                            NULL,
                                            CRPStopNotificationCallback,
                                            CRP_DARWIN_STOP_NOTIFICATION,
                                            NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);

            MSHookFunction((void *)AudioUnitRender,
                           (void *)hooked_AudioUnitRender,
                           (void **)&orig_AudioUnitRender);
        }
    }
}
