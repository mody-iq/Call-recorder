#import "Tweak.h"
#import "AudioRecorderEngine.h"
#include <pthread.h>
#include <stdint.h>

static CRPFloatingRecorderView *gFloatingRecorderView = nil;

// ============================================================================
// Fallback Direct AudioQueue / AVAudioRecorder Capture inside InCallService
// (Automatically activates ONLY if audio daemons are not injected on RootHide)
// ============================================================================
#define CRP_AQ_BUFFER_COUNT 3

@interface CRPInCallFallbackRecorder : NSObject {
    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _buffers[CRP_AQ_BUFFER_COUNT];
    AudioStreamBasicDescription _aqFormat;
    BOOL _running;
}
@property (nonatomic, strong) AVAudioRecorder *avFallbackRecorder;
+ (instancetype)sharedInstance;
- (void)startFallbackIfNeeded;
- (void)stopFallback;
@end

static void CRPAudioQueueInputCallback(void *inUserData,
                                       AudioQueueRef inAQ,
                                       AudioQueueBufferRef inBuffer,
                                       const AudioTimeStamp *inStartTime,
                                       UInt32 inNumberPacketDescriptions,
                                       const AudioStreamPacketDescription *inPacketDescs) {
    CRPInCallFallbackRecorder *selfRef = (__bridge CRPInCallFallbackRecorder *)inUserData;
    if (!selfRef) return;

    if (inBuffer != NULL && inBuffer->mAudioDataByteSize > 0 && [AudioRecorderEngine sharedInstance].isRecording) {
        AudioStreamBasicDescription asbd;
        memset(&asbd, 0, sizeof(asbd));
        asbd.mSampleRate = 16000.0;
        asbd.mFormatID = kAudioFormatLinearPCM;
        asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        asbd.mBytesPerPacket = 2;
        asbd.mFramesPerPacket = 1;
        asbd.mBytesPerFrame = 2;
        asbd.mChannelsPerFrame = 1;
        asbd.mBitsPerChannel = 16;

        UInt32 frames = inBuffer->mAudioDataByteSize / 2u;
        AudioBufferList abl;
        abl.mNumberBuffers = 1;
        abl.mBuffers[0].mNumberChannels = 1;
        abl.mBuffers[0].mDataByteSize = inBuffer->mAudioDataByteSize;
        abl.mBuffers[0].mData = inBuffer->mAudioData;

        [[AudioRecorderEngine sharedInstance] appendAudioBufferList:&abl frames:frames format:asbd];
    }

    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
}

@implementation CRPInCallFallbackRecorder

+ (instancetype)sharedInstance {
    static CRPInCallFallbackRecorder *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[CRPInCallFallbackRecorder alloc] init];
    });
    return inst;
}

- (void)startFallbackIfNeeded {
    if (_running) return;
    _running = YES;

    [[AudioRecorderEngine sharedInstance] startRecording];

    memset(&_aqFormat, 0, sizeof(_aqFormat));
    _aqFormat.mSampleRate = 16000.0;
    _aqFormat.mFormatID = kAudioFormatLinearPCM;
    _aqFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    _aqFormat.mBytesPerPacket = 2;
    _aqFormat.mFramesPerPacket = 1;
    _aqFormat.mBytesPerFrame = 2;
    _aqFormat.mChannelsPerFrame = 1;
    _aqFormat.mBitsPerChannel = 16;

    OSStatus status = AudioQueueNewInput(&_aqFormat,
                                         CRPAudioQueueInputCallback,
                                         (__bridge void *)self,
                                         NULL,
                                         kCFRunLoopCommonModes,
                                         0,
                                         &_audioQueue);
    if (status == noErr && _audioQueue != NULL) {
        UInt32 bufSize = 6400; // 200ms @ 16kHz 16-bit mono
        for (int i = 0; i < CRP_AQ_BUFFER_COUNT; i++) {
            AudioQueueAllocateBuffer(_audioQueue, bufSize, &_buffers[i]);
            AudioQueueEnqueueBuffer(_audioQueue, _buffers[i], 0, NULL);
        }

        // Attempt 1: Start directly inheriting InCallService's active telephony session
        status = AudioQueueStart(_audioQueue, NULL);
        if (status != noErr) {
            // Attempt 2: Activate PlayAndRecord with MixWithOthers
            AVAudioSession *session = [AVAudioSession sharedInstance];
            NSError *sessErr = nil;
            [session setCategory:AVAudioSessionCategoryPlayAndRecord
                            mode:AVAudioSessionModeVoiceChat
                         options:(AVAudioSessionCategoryOptionMixWithOthers |
                                  AVAudioSessionCategoryOptionAllowBluetooth |
                                  AVAudioSessionCategoryOptionAllowBluetoothA2DP)
                           error:&sessErr];
            [session setActive:YES error:&sessErr];
            status = AudioQueueStart(_audioQueue, NULL);
            [AudioRecorderEngine appendDiagnosticLog:
             [NSString stringWithFormat:@"InCallService fallback AudioQueueStart retry status=%d sessErr=%@",
              (int)status, sessErr.localizedDescription ?: @"none"]];
        } else {
            [AudioRecorderEngine appendDiagnosticLog:@"InCallService fallback AudioQueueStart succeeded on inherited session"];
        }

        if (status == noErr) {
            return;
        }

        AudioQueueDispose(_audioQueue, true);
        _audioQueue = NULL;
    } else {
        [AudioRecorderEngine appendDiagnosticLog:
         [NSString stringWithFormat:@"InCallService AudioQueueNewInput failed status=%d", (int)status]];
    }

    // Attempt 3: AVAudioRecorder fallback writing LinearPCM WAV directly
    NSString *dir = [AudioRecorderEngine resolveWritableRecordingsDirectory];
    if (dir) {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        df.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
        NSString *wavPath = [dir stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"Call_%@_ICS.wav", [df stringFromDate:[NSDate date]]]];
        NSDictionary *settings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @(16000.0),
            AVNumberOfChannelsKey: @(1),
            AVLinearPCMBitDepthKey: @(16),
            AVLinearPCMIsFloatKey: @NO,
            AVLinearPCMIsBigEndianKey: @NO
        };
        NSError *recErr = nil;
        self.avFallbackRecorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:wavPath]
                                                              settings:settings
                                                                 error:&recErr];
        if (self.avFallbackRecorder && [self.avFallbackRecorder prepareToRecord] && [self.avFallbackRecorder record]) {
            [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"InCallService AVAudioRecorder started: %@", wavPath]];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CRP_DARWIN_CAPTURING_NOTIFICATION,
                                                 NULL, NULL, true);
        } else {
            [AudioRecorderEngine appendDiagnosticLog:
             [NSString stringWithFormat:@"InCallService AVAudioRecorder failed: %@ (Enable tweak injection for audiomxd & mediaserverd in RootHide Manager!)",
              recErr.localizedDescription ?: @"blocked by active PhoneCall session"]];
            self.avFallbackRecorder = nil;
        }
    }
}

- (void)stopFallback {
    if (!_running) return;
    _running = NO;

    if (_audioQueue != NULL) {
        AudioQueueStop(_audioQueue, true);
        AudioQueueDispose(_audioQueue, true);
        _audioQueue = NULL;
    }

    if (self.avFallbackRecorder) {
        NSURL *url = self.avFallbackRecorder.url;
        [self.avFallbackRecorder stop];
        self.avFallbackRecorder = nil;
        if (url.path) {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil];
            if ([attrs[NSFileSize] unsignedLongLongValue] <= 44ULL) {
                [[NSFileManager defaultManager] removeItemAtPath:url.path error:nil];
            }
        }
    }

    [[AudioRecorderEngine sharedInstance] stopRecording];
}

@end

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
@property (nonatomic, assign) BOOL verifiedCapturing;
@property (nonatomic, assign) NSUInteger sessionGeneration;
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
        _verifiedCapturing = NO;
        _elapsedSeconds = 0;
        _sessionGeneration = 0;
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
        [self stopRecordingAll];
    } else {
        [self startRecordingAll];
    }
}

- (void)startRecordingAll {
    self.sessionGeneration += 1;
    NSUInteger gen = self.sessionGeneration;

    self.isRecording = YES;
    self.verifiedCapturing = NO;
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

    [AudioRecorderEngine appendDiagnosticLog:@"User tapped START in InCallService -> posting Darwin start"];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CRP_DARWIN_START_NOTIFICATION,
                                         NULL, NULL, true);

    // Watchdog: if no audio daemon starts capturing within 0.85s, start InCallService direct fallback
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.85 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.isRecording || strongSelf.sessionGeneration != gen) {
            return;
        }
        if (!strongSelf.verifiedCapturing) {
            [AudioRecorderEngine appendDiagnosticLog:@"No daemon capture ACK after 0.85s -> activating InCallService fallback"];
            [[CRPInCallFallbackRecorder sharedInstance] startFallbackIfNeeded];
        }
    });
}

- (void)stopRecordingAll {
    self.sessionGeneration += 1;
    self.isRecording = NO;
    self.verifiedCapturing = NO;
    [self.elapsedTimer invalidate];
    self.elapsedTimer = nil;
    [self.dotView.layer removeAnimationForKey:@"crp_pulse"];
    self.dotView.backgroundColor = [UIColor systemRedColor];
    self.elapsedSeconds = 0;
    self.timerLabel.text = @"00:00";
    self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.86];

    [[CRPInCallFallbackRecorder sharedInstance] stopFallback];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CRP_DARWIN_STOP_NOTIFICATION,
                                         NULL, NULL, true);
}

- (void)markCapturingVerified {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.isRecording) return;
        self.verifiedCapturing = YES;
        self.dotView.backgroundColor = [UIColor systemGreenColor];
    });
}

- (void)stopRecordingIfNeeded {
    if (self.isRecording) {
        [self stopRecordingAll];
    }
}

- (void)tickTimer {
    self.elapsedSeconds += 1;
    if (self.elapsedSeconds >= 3 && !self.verifiedCapturing) {
        self.dotView.backgroundColor = [UIColor systemYellowColor];
    }
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

static void CRPInCallCapturingDarwinCallback(CFNotificationCenterRef center,
                                             void *observer,
                                             CFStringRef name,
                                             const void *object,
                                             CFDictionaryRef userInfo) {
    [gFloatingRecorderView markCapturingVerified];
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
// Group 2: AudioDaemonHooks (Loaded in mediaserverd / audiomxd / callservicesd / avconferenced)
// ============================================================================
%group AudioDaemonHooks

static pthread_mutex_t gStreamLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_key_t gRenderDepthKey;
static pthread_once_t gRenderKeyOnce = PTHREAD_ONCE_INIT;
static AudioUnit gActiveUnit = NULL;
static UInt32 gActiveBus = 0;
static CFAbsoluteTime gLastRenderTimestamp = 0.0;
static CFAbsoluteTime gLastNonSilentTimestamp = 0.0;

static void CRPInitRenderDepthKey(void) {
    pthread_key_create(&gRenderDepthKey, NULL);
}

static inline intptr_t CRPGetRenderDepth(void) {
    pthread_once(&gRenderKeyOnce, CRPInitRenderDepthKey);
    return (intptr_t)pthread_getspecific(gRenderDepthKey);
}

static inline void CRPSetRenderDepth(intptr_t val) {
    pthread_once(&gRenderKeyOnce, CRPInitRenderDepthKey);
    pthread_setspecific(gRenderDepthKey, (const void *)val);
}

static void CRPResetActiveStreamLock(void) {
    pthread_mutex_lock(&gStreamLock);
    gActiveUnit = NULL;
    gActiveBus = 0;
    gLastRenderTimestamp = 0.0;
    gLastNonSilentTimestamp = 0.0;
    pthread_mutex_unlock(&gStreamLock);
}

static BOOL CRPBufferListHasSignal(const AudioBufferList *ioData, const AudioUnitRenderActionFlags *flags) {
    if (flags != NULL && ((*flags) & kAudioUnitRenderAction_OutputIsSilence)) {
        return NO;
    }
    if (ioData == NULL || ioData->mNumberBuffers == 0) {
        return NO;
    }
    const AudioBuffer *buf = &ioData->mBuffers[0];
    if (buf->mData == NULL || buf->mDataByteSize < 4) {
        return NO;
    }
    const uint32_t *words = (const uint32_t *)buf->mData;
    UInt32 count = MIN((UInt32)(buf->mDataByteSize / sizeof(uint32_t)), 64u);
    UInt32 step = MAX(1u, count / 16u);
    for (UInt32 i = 0; i < count; i += step) {
        if (words[i] != 0u) {
            return YES;
        }
    }
    return NO;
}

static void CRPCaptureRenderedAudio(AudioUnit inUnit,
                                    const AudioUnitRenderActionFlags *ioActionFlags,
                                    UInt32 inBusNumber,
                                    UInt32 inNumberFrames,
                                    AudioBufferList *ioData) {
    AudioRecorderEngine *engine = [AudioRecorderEngine sharedInstance];
    if (!engine.isRecording || inUnit == NULL || ioData == NULL || inNumberFrames == 0) {
        return;
    }

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

    if (fmtStatus != noErr || asbd.mFormatID != kAudioFormatLinearPCM) {
        return;
    }

    BOOL hasSignal = CRPBufferListHasSignal(ioData, ioActionFlags);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL allowThisStream = NO;

    pthread_mutex_lock(&gStreamLock);
    if (gActiveUnit == NULL || (now - gLastRenderTimestamp) > 0.45) {
        gActiveUnit = inUnit;
        gActiveBus = inBusNumber;
    } else if (hasSignal && (gActiveUnit != inUnit || gActiveBus != inBusNumber) && (now - gLastNonSilentTimestamp) > 0.25) {
        // Switch immediately away from a silent unit to a unit carrying real voice signal
        gActiveUnit = inUnit;
        gActiveBus = inBusNumber;
    }

    if (gActiveUnit == inUnit && gActiveBus == inBusNumber) {
        gLastRenderTimestamp = now;
        if (hasSignal) {
            gLastNonSilentTimestamp = now;
        }
        allowThisStream = YES;
    }
    pthread_mutex_unlock(&gStreamLock);

    if (allowThisStream) {
        [engine appendAudioBufferList:ioData frames:inNumberFrames format:asbd];
    }
}

static OSStatus CRPAudioUnitRenderNotify(void *inRefCon,
                                         AudioUnitRenderActionFlags *ioActionFlags,
                                         const AudioTimeStamp *inTimeStamp,
                                         UInt32 inBusNumber,
                                         UInt32 inNumberFrames,
                                         AudioBufferList *ioData) {
    if (ioActionFlags != NULL && ((*ioActionFlags) & kAudioUnitRenderAction_PostRender)) {
        if (CRPGetRenderDepth() == 0) {
            AudioUnit unit = (AudioUnit)inRefCon;
            CRPCaptureRenderedAudio(unit, ioActionFlags, inBusNumber, inNumberFrames, ioData);
        }
    }
    return noErr;
}

static OSStatus (*orig_AudioUnitInitialize)(AudioUnit inUnit) = NULL;
static OSStatus hooked_AudioUnitInitialize(AudioUnit inUnit) {
    if (orig_AudioUnitInitialize == NULL) return -1;
    OSStatus status = orig_AudioUnitInitialize(inUnit);
    if (status == noErr && inUnit != NULL) {
        AudioUnitAddRenderNotify(inUnit, CRPAudioUnitRenderNotify, (void *)inUnit);
    }
    return status;
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
    if (orig_AudioUnitRender == NULL) return -1;

    intptr_t depth = CRPGetRenderDepth();
    CRPSetRenderDepth(depth + 1);
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    CRPSetRenderDepth(depth);

    if (status == noErr) {
        CRPCaptureRenderedAudio(inUnit, ioActionFlags, inBusNumber, inNumberFrames, ioData);
    }
    return status;
}

extern OSStatus AudioUnitProcess(AudioUnit inUnit,
                                 AudioUnitRenderActionFlags *ioActionFlags,
                                 const AudioTimeStamp *inTimeStamp,
                                 UInt32 inNumberFrames,
                                 AudioBufferList *ioData);

static OSStatus (*orig_AudioUnitProcess)(AudioUnit inUnit,
                                         AudioUnitRenderActionFlags *ioActionFlags,
                                         const AudioTimeStamp *inTimeStamp,
                                         UInt32 inNumberFrames,
                                         AudioBufferList *ioData) = NULL;

static OSStatus hooked_AudioUnitProcess(AudioUnit inUnit,
                                        AudioUnitRenderActionFlags *ioActionFlags,
                                        const AudioTimeStamp *inTimeStamp,
                                        UInt32 inNumberFrames,
                                        AudioBufferList *ioData) {
    if (orig_AudioUnitProcess == NULL) return -1;

    intptr_t depth = CRPGetRenderDepth();
    CRPSetRenderDepth(depth + 1);
    OSStatus status = orig_AudioUnitProcess(inUnit, ioActionFlags, inTimeStamp, inNumberFrames, ioData);
    CRPSetRenderDepth(depth);

    if (status == noErr) {
        CRPCaptureRenderedAudio(inUnit, ioActionFlags, 0, inNumberFrames, ioData);
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

static void CRPPingNotificationCallback(CFNotificationCenterRef center,
                                        void *observer,
                                        CFStringRef name,
                                        const void *object,
                                        CFDictionaryRef userInfo) {
    NSString *dir = [AudioRecorderEngine resolveWritableRecordingsDirectory] ?: @"NONE";
    [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"PONG alive (writableDir=%@)", dir]];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CRP_DARWIN_PONG_NOTIFICATION,
                                         NULL, NULL, true);
}

%end

// ============================================================================
// Constructor (%ctor)
// ============================================================================
%ctor {
    @autoreleasepool {
        NSString *processName = [NSProcessInfo processInfo].processName ?: @"";
        CFNotificationCenterRef darwinCenter = CFNotificationCenterGetDarwinNotifyCenter();

        if ([processName isEqualToString:@"InCallService"]) {
            %init(InCallServiceUI);

            CFNotificationCenterAddObserver(darwinCenter,
                                            NULL,
                                            CRPInCallCapturingDarwinCallback,
                                            CRP_DARWIN_CAPTURING_NOTIFICATION,
                                            NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);

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

            NSString *dir = [AudioRecorderEngine resolveWritableRecordingsDirectory] ?: @"NONE";
            [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Loaded InCallServiceUI (writableDir=%@)", dir]];
        } else if ([processName isEqualToString:@"mediaserverd"] ||
                   [processName isEqualToString:@"audiomxd"] ||
                   [processName isEqualToString:@"callservicesd"] ||
                   [processName isEqualToString:@"avconferenced"]) {
            %init(AudioDaemonHooks);

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
            CFNotificationCenterAddObserver(darwinCenter,
                                            NULL,
                                            CRPPingNotificationCallback,
                                            CRP_DARWIN_PING_NOTIFICATION,
                                            NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);

            MSHookFunction((void *)AudioUnitInitialize,
                           (void *)hooked_AudioUnitInitialize,
                           (void **)&orig_AudioUnitInitialize);
            MSHookFunction((void *)AudioUnitRender,
                           (void *)hooked_AudioUnitRender,
                           (void **)&orig_AudioUnitRender);

            void *procSym = MSFindSymbol(NULL, "_AudioUnitProcess");
            if (procSym != NULL) {
                MSHookFunction(procSym,
                               (void *)hooked_AudioUnitProcess,
                               (void **)&orig_AudioUnitProcess);
            }

            NSString *dir = [AudioRecorderEngine resolveWritableRecordingsDirectory] ?: @"NONE";
            [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Loaded AudioDaemonHooks (writableDir=%@, AUProcess=%@)",
                                                      dir, procSym ? @"hooked" : @"n/a"]];
        }
    }
}
