#import "Tweak.h"
#import "AudioRecorderEngine.h"
#include <pthread.h>

static CRPFloatingRecorderView *gFloatingRecorderView = nil;

// ============================================================================
// Floating Draggable Recorder Control (InCallService UI)
// ============================================================================
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
        self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.86];
        self.layer.cornerRadius = CGRectGetHeight(frame) / 2.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.35f;
        self.layer.shadowRadius = 8.0;
        self.layer.shadowOffset = CGSizeMake(0.0, 3.0);
        self.clipsToBounds = NO;

        _dotView = [[UIView alloc] initWithFrame:CGRectMake(14.0, (CGRectGetHeight(frame) - 14.0) / 2.0, 14.0, 14.0)];
        _dotView.layer.cornerRadius = 7.0;
        _dotView.backgroundColor = [UIColor systemRedColor];
        _dotView.userInteractionEnabled = NO;
        [self addSubview:_dotView];

        _timerLabel = [[UILabel alloc] initWithFrame:CGRectMake(35.0, 0.0, CGRectGetWidth(frame) - 45.0, CGRectGetHeight(frame))];
        _timerLabel.text = @"00:00";
        _timerLabel.textColor = [UIColor whiteColor];
        _timerLabel.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightSemibold];
        _timerLabel.textAlignment = NSTextAlignmentLeft;
        _timerLabel.userInteractionEnabled = NO;
        [self addSubview:_timerLabel];

        _toggleButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _toggleButton.frame = self.bounds;
        _toggleButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _toggleButton.accessibilityLabel = @"Toggle Call Recording";
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

    UIEdgeInsets safeInsets = superview.safeAreaInsets;
    CGFloat halfW = CGRectGetWidth(self.bounds) / 2.0;
    CGFloat halfH = CGRectGetHeight(self.bounds) / 2.0;
    CGFloat minX = MAX(8.0, safeInsets.left + 8.0) + halfW;
    CGFloat maxX = CGRectGetWidth(superview.bounds) - MAX(8.0, safeInsets.right + 8.0) - halfW;
    CGFloat minY = MAX(44.0, safeInsets.top + 8.0) + halfH;
    CGFloat maxY = CGRectGetHeight(superview.bounds) - MAX(20.0, safeInsets.bottom + 8.0) - halfH;

    if (maxX >= minX) {
        newCenter.x = MAX(minX, MIN(maxX, newCenter.x));
    }
    if (maxY >= minY) {
        newCenter.y = MAX(minY, MIN(maxY, newCenter.y));
    }

    self.center = newCenter;
    [gesture setTranslation:CGPointZero inView:superview];
}

- (void)handleTap {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];

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
    self.backgroundColor = [UIColor colorWithRed:0.62 green:0.07 blue:0.09 alpha:0.92];
    self.dotView.backgroundColor = [UIColor whiteColor];

    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @(1.0);
    pulse.toValue = @(0.25);
    pulse.duration = 0.65;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    [self.dotView.layer addAnimation:pulse forKey:@"crp_pulse"];

    [self.elapsedTimer invalidate];
    NSTimer *timer = [NSTimer timerWithTimeInterval:1.0
                                             target:self
                                           selector:@selector(tickTimer)
                                           userInfo:nil
                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.elapsedTimer = timer;
}

- (void)stopRecordingUI {
    self.isRecording = NO;
    [self.elapsedTimer invalidate];
    self.elapsedTimer = nil;
    [self.dotView.layer removeAnimationForKey:@"crp_pulse"];
    self.dotView.backgroundColor = [UIColor systemRedColor];
    self.elapsedSeconds = 0;
    self.timerLabel.text = @"00:00";
    self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.86];
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

static void CRPAttachFloatingRecorderToContainer(UIView *container) {
    if (!container) return;

    NSString *clsName = NSStringFromClass([container class]);
    if ([clsName containsString:@"Keyboard"] || [clsName containsString:@"TextEffects"]) {
        return;
    }

    CGRect bounds = container.bounds;
    if (CGRectGetWidth(bounds) < 200.0 || CGRectGetHeight(bounds) < 120.0) {
        return;
    }

    if (!gFloatingRecorderView) {
        CGFloat width = 118.0;
        CGFloat height = 44.0;
        CGFloat topInset = MAX(58.0, container.safeAreaInsets.top + 12.0);
        CGFloat xPos = MAX(16.0, CGRectGetWidth(bounds) - width - 16.0);
        gFloatingRecorderView = [[CRPFloatingRecorderView alloc] initWithFrame:CGRectMake(xPos, topInset, width, height)];
        gFloatingRecorderView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    }

    if (gFloatingRecorderView.superview != container) {
        [container addSubview:gFloatingRecorderView];
    }
    [container bringSubviewToFront:gFloatingRecorderView];
}

// ============================================================================
// Group 1: InCallServiceUI (Loaded in InCallService)
// ============================================================================
%group InCallServiceUI

%hook PHAudioCallViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    CRPAttachFloatingRecorderToContainer(self.view.window ?: self.view);
}

%end

%hook CNKFaceTimeInCallViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    CRPAttachFloatingRecorderToContainer(self.view.window ?: self.view);
}

%end

%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
    if (!self.isHidden && self.windowLevel <= UIWindowLevelStatusBar + 100.0) {
        CRPAttachFloatingRecorderToContainer(self);
    }
}

- (void)didAddSubview:(UIView *)subview {
    %orig;
    if (subview != gFloatingRecorderView && !self.isHidden && self.windowLevel <= UIWindowLevelStatusBar + 100.0) {
        if (gFloatingRecorderView.superview == self) {
            [self bringSubviewToFront:gFloatingRecorderView];
        } else if (!gFloatingRecorderView || gFloatingRecorderView.superview == nil) {
            CRPAttachFloatingRecorderToContainer(self);
        }
    }
}

%end

static void CRPHandleCallStatusChanged(NSNotification *note) {
    BOOL shouldStop = NO;

    id call = note.object;
    if (call && [call respondsToSelector:@selector(status)]) {
        int status = [(TUCall *)call status];
        // TUCallStatusDisconnected == 6
        if (status == 6) {
            shouldStop = YES;
        }
    }

    Class callCenterCls = objc_getClass("TUCallCenter");
    if (callCenterCls && [callCenterCls respondsToSelector:@selector(sharedInstance)]) {
        TUCallCenter *center = [callCenterCls sharedInstance];
        if ([center respondsToSelector:@selector(currentCalls)]) {
            NSArray *calls = center.currentCalls;
            if (calls && calls.count == 0) {
                shouldStop = YES;
            }
        }
    }

    if (shouldStop) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [gFloatingRecorderView stopRecordingIfNeeded];
        });
    }
}

%end

// ============================================================================
// Group 2: AudioDaemonHooks (Loaded in mediaserverd / audiomxd)
// ============================================================================
%group AudioDaemonHooks

static pthread_mutex_t gStreamLock = PTHREAD_MUTEX_INITIALIZER;
static AudioUnit gActiveUnit = NULL;
static UInt32 gActiveBus = 0;
static CFAbsoluteTime gLastRenderTimestamp = 0.0;

static void CRPResetActiveStreamLock(void) {
    pthread_mutex_lock(&gStreamLock);
    gActiveUnit = NULL;
    gActiveBus = 0;
    gLastRenderTimestamp = 0.0;
    pthread_mutex_unlock(&gStreamLock);
}

static OSStatus (*orig_AudioUnitRender)(AudioUnit inUnit,
                                        AudioUnitRenderActionFlags *ioActionFlags,
                                        const AudioTimeStamp *inTimeStamp,
                                        UInt32 inBusNumber,
                                        UInt32 inNumberFrames,
                                        AudioBufferList *ioData) = NULL;

static OSStatus hooked_AudioUnitRender(AudioUnit inUnit,
                                       AudioUnitRenderActionFlags *ioActionFlags,
                                       const AudioTimeStamp *inTimeStamp,
                                       UInt32 inBusNumber,
                                       UInt32 inNumberFrames,
                                       AudioBufferList *ioData) {
    if (orig_AudioUnitRender == NULL) {
        return -1;
    }

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
        if (fmtStatus != noErr) {
            propSize = sizeof(asbd);
            fmtStatus = AudioUnitGetProperty(inUnit,
                                             kAudioUnitProperty_StreamFormat,
                                             kAudioUnitScope_Input,
                                             inBusNumber,
                                             &asbd,
                                             &propSize);
        }

        if (fmtStatus == noErr && asbd.mFormatID == kAudioFormatLinearPCM) {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            BOOL allowThisStream = NO;

            pthread_mutex_lock(&gStreamLock);
            if (gActiveUnit == NULL || (now - gLastRenderTimestamp) > 0.5) {
                gActiveUnit = inUnit;
                gActiveBus = inBusNumber;
            }
            if (gActiveUnit == inUnit && gActiveBus == inBusNumber) {
                gLastRenderTimestamp = now;
                allowThisStream = YES;
            }
            pthread_mutex_unlock(&gStreamLock);

            if (allowThisStream) {
                [engine appendAudioBufferList:ioData frames:inNumberFrames format:asbd];
            }
        }
    }

    return status;
}

static void CRPStartNotificationCallback(CFNotificationCenterRef center,
                                         void *observer,
                                         CFStringRef name,
                                         const void *object,
                                         CFDictionaryRef userInfo) {
    CRPResetActiveStreamLock();
    [[AudioRecorderEngine sharedInstance] startRecording];
}

static void CRPStopNotificationCallback(CFNotificationCenterRef center,
                                        void *observer,
                                        CFStringRef name,
                                        const void *object,
                                        CFDictionaryRef userInfo) {
    [[AudioRecorderEngine sharedInstance] stopRecording];
    CRPResetActiveStreamLock();
}

%end

// ============================================================================
// Constructor (%ctor)
// ============================================================================
%ctor {
    @autoreleasepool {
        NSString *processName = [NSProcessInfo processInfo].processName;

        if ([processName isEqualToString:@"InCallService"]) {
            %init(InCallServiceUI);

            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            [nc addObserverForName:@"TUCallCenterCallStatusChangedNotification"
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                CRPHandleCallStatusChanged(note);
            }];
            [nc addObserverForName:@"TUCallStatusChangedNotification"
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
