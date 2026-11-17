#import "Tweak.h"
#import "AudioRecorderEngine.h"
#include <pthread.h>
#include <stdint.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdatomic.h>

static CRPFloatingRecorderView *gFloatingRecorderView = nil;

// ===========================================================================
// Fallback Direct Recorder – InCallService only, lightweight
// ===========================================================================
#define CRP_AQ_BUFFER_COUNT 3

@interface CRPInCallFallbackRecorder : NSObject {
    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _buffers[CRP_AQ_BUFFER_COUNT];
    AudioStreamBasicDescription _aqFormat;
    AudioUnit _remoteIOUnit;
    BOOL _running;
}
+ (instancetype)sharedInstance;
- (void)startFallbackIfNeeded;
- (void)stopFallback;
@end

static void CRPAudioQueueInputCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer, const AudioTimeStamp *inStartTime, UInt32 inNumberPacketDescriptions, const AudioStreamPacketDescription *inPacketDescs) {
    CRPInCallFallbackRecorder *selfRef = (__bridge CRPInCallFallbackRecorder *)inUserData;
    if (!selfRef) return;
    if (inBuffer && inBuffer->mAudioDataByteSize > 0 && [AudioRecorderEngine sharedInstance].isRecording) {
        AudioStreamBasicDescription asbd; memset(&asbd,0,sizeof(asbd));
        asbd.mSampleRate = 16000.0;
        asbd.mFormatID = kAudioFormatLinearPCM;
        asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        asbd.mBytesPerPacket = 2; asbd.mFramesPerPacket = 1; asbd.mBytesPerFrame = 2; asbd.mChannelsPerFrame = 1; asbd.mBitsPerChannel = 16;
        UInt32 frames = inBuffer->mAudioDataByteSize / 2u;
        AudioBufferList abl; abl.mNumberBuffers = 1;
        abl.mBuffers[0].mNumberChannels = 1;
        abl.mBuffers[0].mDataByteSize = inBuffer->mAudioDataByteSize;
        abl.mBuffers[0].mData = inBuffer->mAudioData;
        [[AudioRecorderEngine sharedInstance] appendAudioBufferList:&abl frames:frames format:asbd];
    }
    if (inAQ && inBuffer) AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
}

static OSStatus CRPRemoteIOInputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    if (![AudioRecorderEngine sharedInstance].isRecording) return noErr;
    AudioUnit unit = (AudioUnit)inRefCon;
    if (!unit || !ioData) return noErr;
    OSStatus status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ioData);
    if (status == noErr && ioData->mNumberBuffers > 0) {
        AudioStreamBasicDescription asbd; memset(&asbd,0,sizeof(asbd));
        UInt32 sz = sizeof(asbd);
        if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, &sz) == noErr) {
            if (asbd.mFormatID == kAudioFormatLinearPCM) {
                [[AudioRecorderEngine sharedInstance] appendAudioBufferList:ioData frames:inNumberFrames format:asbd];
            }
        } else {
            asbd.mSampleRate = 16000; asbd.mFormatID = kAudioFormatLinearPCM;
            asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked;
            asbd.mBytesPerPacket=2; asbd.mFramesPerPacket=1; asbd.mBytesPerFrame=2; asbd.mChannelsPerFrame=1; asbd.mBitsPerChannel=16;
            [[AudioRecorderEngine sharedInstance] appendAudioBufferList:ioData frames:inNumberFrames format:asbd];
        }
    }
    return status;
}

@implementation CRPInCallFallbackRecorder

+ (instancetype)sharedInstance {
    static CRPInCallFallbackRecorder *inst=nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ inst=[[CRPInCallFallbackRecorder alloc] init]; });
    return inst;
}

- (void)startFallbackIfNeeded {
    if (_running) return;
    _running = YES;
    // Async start – never block main thread
    [[AudioRecorderEngine sharedInstance] startRecording];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        memset(&self->_aqFormat,0,sizeof(self->_aqFormat));
        self->_aqFormat.mSampleRate=16000.0; self->_aqFormat.mFormatID=kAudioFormatLinearPCM;
        self->_aqFormat.mFormatFlags=kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked;
        self->_aqFormat.mBytesPerPacket=2; self->_aqFormat.mFramesPerPacket=1; self->_aqFormat.mBytesPerFrame=2; self->_aqFormat.mChannelsPerFrame=1; self->_aqFormat.mBitsPerChannel=16;
        OSStatus status = AudioQueueNewInput(&self->_aqFormat, CRPAudioQueueInputCallback, (__bridge void*)self, NULL, kCFRunLoopCommonModes, 0, &self->_audioQueue);
        if (status==noErr && self->_audioQueue) {
            for (int i=0;i<CRP_AQ_BUFFER_COUNT;i++) { AudioQueueAllocateBuffer(self->_audioQueue, 6400, &self->_buffers[i]); AudioQueueEnqueueBuffer(self->_audioQueue, self->_buffers[i], 0, NULL); }
            status = AudioQueueStart(self->_audioQueue, NULL);
            if (status==noErr) {
                [AudioRecorderEngine appendDiagnosticLog:@"InCallService fallback A AudioQueue 16k started"];
                return;
            }
            AudioQueueDispose(self->_audioQueue,true); self->_audioQueue=NULL;
        }
        // Strategy B – RemoteIO (rare)
        AudioComponentDescription desc; memset(&desc,0,sizeof(desc));
        desc.componentType=kAudioUnitType_Output; desc.componentSubType=kAudioUnitSubType_RemoteIO; desc.componentManufacturer=kAudioUnitManufacturer_Apple;
        AudioComponent comp = AudioComponentFindNext(NULL, &desc);
        if (!comp) return;
        OSStatus s = AudioComponentInstanceNew(comp, &self->_remoteIOUnit);
        if (s!=noErr || !self->_remoteIOUnit) return;
        UInt32 enable=1; s=AudioUnitSetProperty(self->_remoteIOUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, sizeof(enable));
        if (s!=noErr) { AudioComponentInstanceDispose(self->_remoteIOUnit); self->_remoteIOUnit=NULL; return; }
        enable=0; AudioUnitSetProperty(self->_remoteIOUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, sizeof(enable));
        AudioStreamBasicDescription fmt; memset(&fmt,0,sizeof(fmt));
        fmt.mSampleRate=16000; fmt.mFormatID=kAudioFormatLinearPCM; fmt.mFormatFlags=kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked;
        fmt.mBytesPerPacket=2; fmt.mFramesPerPacket=1; fmt.mBytesPerFrame=2; fmt.mChannelsPerFrame=1; fmt.mBitsPerChannel=16;
        s=AudioUnitSetProperty(self->_remoteIOUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, sizeof(fmt));
        if (s!=noErr) { AudioComponentInstanceDispose(self->_remoteIOUnit); self->_remoteIOUnit=NULL; return; }
        AURenderCallbackStruct cb; cb.inputProc=CRPRemoteIOInputCallback; cb.inputProcRefCon=(void*)self->_remoteIOUnit;
        s=AudioUnitSetProperty(self->_remoteIOUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, sizeof(cb));
        if (s!=noErr) { AudioComponentInstanceDispose(self->_remoteIOUnit); self->_remoteIOUnit=NULL; return; }
        s=AudioUnitInitialize(self->_remoteIOUnit);
        if (s!=noErr) { AudioComponentInstanceDispose(self->_remoteIOUnit); self->_remoteIOUnit=NULL; return; }
        s=AudioOutputUnitStart(self->_remoteIOUnit);
        if (s!=noErr) { AudioUnitUninitialize(self->_remoteIOUnit); AudioComponentInstanceDispose(self->_remoteIOUnit); self->_remoteIOUnit=NULL; }
    });
}

- (void)stopFallback {
    if (!_running) return;
    _running=NO;
    AudioQueueRef aq = _audioQueue; _audioQueue = NULL;
    AudioUnit rio = _remoteIOUnit; _remoteIOUnit = NULL;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (aq) { AudioQueueStop(aq,true); AudioQueueDispose(aq,true); }
        if (rio) { AudioOutputUnitStop(rio); AudioUnitUninitialize(rio); AudioComponentInstanceDispose(rio); }
    });
    [[AudioRecorderEngine sharedInstance] stopRecording];
}

@end

// ============================================================================
// Floating View – lightweight, no file I/O
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
    self=[super initWithFrame:frame];
    if (self) {
        self.backgroundColor=[UIColor colorWithWhite:0.08 alpha:0.88];
        self.layer.cornerRadius=CGRectGetHeight(frame)/2.0; self.layer.borderWidth=1.0;
        self.layer.borderColor=[UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
        self.layer.shadowColor=[UIColor blackColor].CGColor; self.layer.shadowOpacity=0.32f; self.layer.shadowRadius=8.0; self.layer.shadowOffset=CGSizeMake(0,3); self.clipsToBounds=NO;
        _dotView=[[UIView alloc] initWithFrame:CGRectMake(14.0,(CGRectGetHeight(frame)-12.0)/2.0,12.0,12.0)];
        _dotView.layer.cornerRadius=6.0; _dotView.backgroundColor=[UIColor systemRedColor]; _dotView.userInteractionEnabled=NO; [self addSubview:_dotView];
        _timerLabel=[[UILabel alloc] initWithFrame:CGRectMake(34.0,0.0,CGRectGetWidth(frame)-44.0,CGRectGetHeight(frame))];
        _timerLabel.text=@"00:00"; _timerLabel.textColor=[UIColor whiteColor];
        _timerLabel.font=[UIFont monospacedDigitSystemFontOfSize:14.5 weight:UIFontWeightSemibold]; _timerLabel.textAlignment=NSTextAlignmentCenter; _timerLabel.userInteractionEnabled=NO; [self addSubview:_timerLabel];
        _toggleButton=[UIButton buttonWithType:UIButtonTypeCustom]; _toggleButton.frame=self.bounds; _toggleButton.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        _toggleButton.accessibilityLabel=@"Toggle Call Recording"; [_toggleButton addTarget:self action:@selector(handleTap) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:_toggleButton];
        UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]; [self addGestureRecognizer:pan];
        _isRecording=NO; _verifiedCapturing=NO; _elapsedSeconds=0; _sessionGeneration=0;
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *superview=self.superview; if (!superview) return;
    CGPoint translation=[gesture translationInView:superview];
    CGPoint newCenter=CGPointMake(self.center.x+translation.x,self.center.y+translation.y);
    UIEdgeInsets safeInsets=superview.safeAreaInsets;
    CGFloat halfW=CGRectGetWidth(self.bounds)/2.0, halfH=CGRectGetHeight(self.bounds)/2.0;
    CGFloat minX=MAX(8.0,safeInsets.left+8.0)+halfW, maxX=CGRectGetWidth(superview.bounds)-MAX(8.0,safeInsets.right+8.0)-halfW;
    CGFloat minY=MAX(44.0,safeInsets.top+8.0)+halfH, maxY=CGRectGetHeight(superview.bounds)-MAX(20.0,safeInsets.bottom+8.0)-halfH;
    if (maxX>=minX) newCenter.x=MAX(minX,MIN(maxX,newCenter.x));
    if (maxY>=minY) newCenter.y=MAX(minY,MIN(maxY,newCenter.y));
    self.center=newCenter; [gesture setTranslation:CGPointZero inView:superview];
}

- (void)handleTap {
    // Light haptic – create on demand to avoid pre-alloc
    UIImpactFeedbackGenerator *feedback=[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; [feedback impactOccurred];
    if (self.isRecording) [self stopRecordingAll]; else [self startRecordingAll];
}

- (void)startRecordingAll {
    self.sessionGeneration+=1; NSUInteger gen=self.sessionGeneration;
    self.isRecording=YES; self.verifiedCapturing=NO; self.elapsedSeconds=0; self.timerLabel.text=@"00:00";
    self.backgroundColor=[UIColor colorWithRed:0.64 green:0.08 blue:0.08 alpha:0.94]; self.dotView.backgroundColor=[UIColor whiteColor];
    CABasicAnimation *pulse=[CABasicAnimation animationWithKeyPath:@"opacity"]; pulse.fromValue=@(1.0); pulse.toValue=@(0.25); pulse.duration=0.65; pulse.autoreverses=YES; pulse.repeatCount=HUGE_VALF; [self.dotView.layer addAnimation:pulse forKey:@"crp_pulse"];
    [self.elapsedTimer invalidate];
    NSTimer *timer=[NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(tickTimer) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes]; self.elapsedTimer=timer;
    // Darwin notify – minimal work
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CRP_DARWIN_START_NOTIFICATION, NULL, NULL, true);
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.8*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf=weakSelf; if (!strongSelf || !strongSelf.isRecording || strongSelf.sessionGeneration!=gen) return;
        if (!strongSelf.verifiedCapturing) {
            [[CRPInCallFallbackRecorder sharedInstance] startFallbackIfNeeded];
        }
    });
}

- (void)stopRecordingAll {
    self.sessionGeneration+=1; self.isRecording=NO; self.verifiedCapturing=NO;
    [self.elapsedTimer invalidate]; self.elapsedTimer=nil;
    [self.dotView.layer removeAnimationForKey:@"crp_pulse"]; self.dotView.backgroundColor=[UIColor systemRedColor];
    self.elapsedSeconds=0; self.timerLabel.text=@"00:00"; self.backgroundColor=[UIColor colorWithWhite:0.08 alpha:0.88];
    [[CRPInCallFallbackRecorder sharedInstance] stopFallback];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CRP_DARWIN_STOP_NOTIFICATION, NULL, NULL, true);
}

- (void)markCapturingVerified {
    dispatch_async(dispatch_get_main_queue(), ^{ if (!self.isRecording) return; self.verifiedCapturing=YES; self.dotView.backgroundColor=[UIColor systemGreenColor]; });
}

- (void)stopRecordingIfNeeded { if (self.isRecording) [self stopRecordingAll]; }

- (void)tickTimer {
    self.elapsedSeconds+=1;
    if (self.elapsedSeconds>=3 && !self.verifiedCapturing) self.dotView.backgroundColor=[UIColor systemYellowColor];
    NSInteger minutes=self.elapsedSeconds/60, seconds=self.elapsedSeconds%60;
    self.timerLabel.text=[NSString stringWithFormat:@"%02ld:%02ld",(long)minutes,(long)seconds];
}

@end

static void CRPAttachFloatingRecorderToContainer(UIView *container) {
    if (!container) return;
    NSString *clsName=NSStringFromClass([container class]);
    if ([clsName containsString:@"Keyboard"] || [clsName containsString:@"TextEffects"] || [clsName containsString:@"CarPlay"]) return;
    CGRect bounds=container.bounds;
    if (CGRectGetWidth(bounds)<200.0 || CGRectGetHeight(bounds)<120.0) return;
    // Avoid double-add within 2s
    static CFAbsoluteTime sLastAttach=0; CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
    if (gFloatingRecorderView && gFloatingRecorderView.superview==container && (now - sLastAttach) < 1.5) return;
    sLastAttach=now;
    if (!gFloatingRecorderView) {
        CGFloat width=116.0, height=42.0;
        CGFloat topInset=MAX(58.0, container.safeAreaInsets.top+10.0);
        CGFloat xPos=MAX(14.0, CGRectGetWidth(bounds)-width-14.0);
        gFloatingRecorderView=[[CRPFloatingRecorderView alloc] initWithFrame:CGRectMake(xPos,topInset,width,height)];
        gFloatingRecorderView.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleBottomMargin;
    }
    if (gFloatingRecorderView.superview!=container) [container addSubview:gFloatingRecorderView];
    [container bringSubviewToFront:gFloatingRecorderView];
}

static void CRPInCallCapturingDarwinCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [gFloatingRecorderView markCapturingVerified];
}

// ============================================================================
// Group 1: InCallServiceUI
// ============================================================================
%group InCallServiceUI

%hook PHAudioCallViewController
- (void)viewDidAppear:(BOOL)animated { %orig; CRPAttachFloatingRecorderToContainer(self.view.window ?: self.view); }
%end

%hook CNKFaceTimeInCallViewController
- (void)viewDidAppear:(BOOL)animated { %orig; CRPAttachFloatingRecorderToContainer(self.view.window ?: self.view); }
%end

static void CRPHandleCallStatusChanged(NSNotification *note) {
    BOOL shouldStop=NO;
    id call=note.object;
    if (call && [call respondsToSelector:@selector(status)]) { int status=[(TUCall*)call status]; if (status==6) shouldStop=YES; }
    if (!shouldStop) {
        Class callCenterCls=objc_getClass("TUCallCenter");
        if (callCenterCls && [callCenterCls respondsToSelector:@selector(sharedInstance)]) {
            TUCallCenter *center=[callCenterCls sharedInstance];
            if ([center respondsToSelector:@selector(currentCalls)]) {
                NSArray *calls=center.currentCalls;
                if (calls && calls.count==0) shouldStop=YES;
            }
        }
    }
    if (shouldStop) dispatch_async(dispatch_get_main_queue(), ^{ [gFloatingRecorderView stopRecordingIfNeeded]; });
}

%end

// ============================================================================
// Group 2: AudioDaemonHooks – ultra-light render path, no main-thread stalls
// ============================================================================
%group AudioDaemonHooks

static pthread_mutex_t gStreamLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_key_t gRenderDepthKey;
static pthread_once_t gRenderKeyOnce = PTHREAD_ONCE_INIT;
static AudioUnit gActiveUnit = NULL;
static UInt32 gActiveBus = 0;
static CFAbsoluteTime gLastRenderTimestamp = 0.0;
static CFAbsoluteTime gLastNonSilentTimestamp = 0.0;
static CFAbsoluteTime gLastAnyCaptureTime = 0.0;
static CFAbsoluteTime gLastOutputTime = 0.0;
// Format cache – avoids AudioUnitGetProperty on render thread
static AudioUnit gCachedUnit = NULL;
static AudioStreamBasicDescription gCachedASBD; static BOOL gCachedValid=NO;

static void CRPInitRenderDepthKey(void) { pthread_key_create(&gRenderDepthKey,NULL); }
static inline intptr_t CRPGetRenderDepth(void) { pthread_once(&gRenderKeyOnce,CRPInitRenderDepthKey); return (intptr_t)pthread_getspecific(gRenderDepthKey); }
static inline void CRPSetRenderDepth(intptr_t v) { pthread_once(&gRenderKeyOnce,CRPInitRenderDepthKey); pthread_setspecific(gRenderDepthKey,(const void*)v); }
static void CRPResetActiveStreamLock(void) {
    pthread_mutex_lock(&gStreamLock);
    gActiveUnit=NULL; gActiveBus=0; gLastRenderTimestamp=0.0; gLastNonSilentTimestamp=0.0; gLastAnyCaptureTime=0.0; gLastOutputTime=0.0; gCachedUnit=NULL; gCachedValid=NO; memset(&gCachedASBD,0,sizeof(gCachedASBD));
    pthread_mutex_unlock(&gStreamLock);
}
static inline BOOL CRPBufferListHasSignal(const AudioBufferList *ioData, const AudioUnitRenderActionFlags *flags) {
    if (flags && ((*flags) & kAudioUnitRenderAction_OutputIsSilence)) return NO;
    if (!ioData || ioData->mNumberBuffers==0) return NO;
    const AudioBuffer *buf=&ioData->mBuffers[0];
    if (!buf->mData || buf->mDataByteSize<4) return NO;
    const uint32_t *words=(const uint32_t*)buf->mData;
    UInt32 count=MIN((UInt32)(buf->mDataByteSize/sizeof(uint32_t)),32u);
    for (UInt32 i=0;i<count;i+=8) if (words[i]!=0u) return YES;
    // Fallback: check second buffer if exists
    if (ioData->mNumberBuffers>1) {
        const AudioBuffer *b2=&ioData->mBuffers[1];
        if (b2->mData && b2->mDataByteSize>=4) {
            const uint32_t *w2=(const uint32_t*)b2->mData;
            UInt32 c2=MIN((UInt32)(b2->mDataByteSize/4),16u);
            for (UInt32 i=0;i<c2;i+=4) if (w2[i]!=0u) return YES;
        }
    }
    return NO;
}

static void CRPCaptureRenderedAudio(AudioUnit inUnit, const AudioUnitRenderActionFlags *ioActionFlags, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    if (![AudioRecorderEngine sharedInstance].isRecording || !inUnit || !ioData || inNumberFrames==0) return;
    BOOL hasSignal=CRPBufferListHasSignal(ioData, ioActionFlags);
    if (!hasSignal) return; // skip silence early – reduces work

    CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();

    // Fast dedup + bus preference – minimal lock time
    pthread_mutex_lock(&gStreamLock);
    if (gLastAnyCaptureTime != 0.0 && (now - gLastAnyCaptureTime) < 0.014) {
        // Within 14ms duplicate window – allow only if same stream continuing
        if (!(gActiveUnit==inUnit && gActiveBus==inBusNumber)) {
            pthread_mutex_unlock(&gStreamLock);
            return;
        }
    }
    if (inBusNumber == 1 && gLastOutputTime != 0.0 && (now - gLastOutputTime) < 0.45) {
        // Prefer mixed output bus 0 over mic-only bus 1
        pthread_mutex_unlock(&gStreamLock);
        return;
    }
    BOOL allow=NO;
    if (gActiveUnit==NULL || (now - gLastRenderTimestamp) > 0.45) { gActiveUnit=inUnit; gActiveBus=inBusNumber; }
    else if (gActiveUnit!=inUnit || gActiveBus!=inBusNumber) {
        if ((now - gLastNonSilentTimestamp) > 0.28) { gActiveUnit=inUnit; gActiveBus=inBusNumber; }
    }
    if (gActiveUnit==inUnit && gActiveBus==inBusNumber) {
        gLastRenderTimestamp=now; gLastNonSilentTimestamp=now;
        if (inBusNumber==0) gLastOutputTime=now;
        gLastAnyCaptureTime=now;
        allow=YES;
    }
    // Prepare ASBD – try cache first, avoid GetProperty on render thread if possible
    AudioStreamBasicDescription asbdToUse; BOOL haveASBD=NO;
    if (gCachedValid && gCachedUnit==inUnit) {
        asbdToUse=gCachedASBD; haveASBD=YES;
    }
    pthread_mutex_unlock(&gStreamLock);
    if (!allow) return;

    AudioStreamBasicDescription asbd; BOOL gotFormat=NO;
    if (haveASBD) { asbd=asbdToUse; gotFormat=YES; }
    else {
        UInt32 propSize=sizeof(asbd); memset(&asbd,0,sizeof(asbd));
        if (AudioUnitGetProperty(inUnit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,inBusNumber,&asbd,&propSize)==noErr && asbd.mFormatID==kAudioFormatLinearPCM) gotFormat=YES;
        else {
            propSize=sizeof(asbd); memset(&asbd,0,sizeof(asbd));
            if (AudioUnitGetProperty(inUnit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,inBusNumber,&asbd,&propSize)==noErr && asbd.mFormatID==kAudioFormatLinearPCM) gotFormat=YES;
        }
        if (gotFormat) {
            pthread_mutex_lock(&gStreamLock);
            gCachedUnit=inUnit; gCachedASBD=asbd; gCachedValid=YES;
            pthread_mutex_unlock(&gStreamLock);
        }
    }
    if (!gotFormat) return;
    [[AudioRecorderEngine sharedInstance] appendAudioBufferList:ioData frames:inNumberFrames format:asbd];
}

static OSStatus CRPAudioUnitRenderNotify(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    if (ioActionFlags && ((*ioActionFlags) & kAudioUnitRenderAction_PostRender)) {
        if (CRPGetRenderDepth()==0) { AudioUnit unit=(AudioUnit)inRefCon; CRPCaptureRenderedAudio(unit, ioActionFlags, inBusNumber, inNumberFrames, ioData); }
    }
    return noErr;
}

static OSStatus (*orig_AudioUnitInitialize)(AudioUnit inUnit)=NULL;
static OSStatus hooked_AudioUnitInitialize(AudioUnit inUnit) {
    if (!orig_AudioUnitInitialize) return -1;
    OSStatus status=orig_AudioUnitInitialize(inUnit);
    if (status==noErr && inUnit) {
        AudioUnitAddRenderNotify(inUnit, CRPAudioUnitRenderNotify, (void*)inUnit);
        // Pre-cache format to avoid render-thread queries
        AudioStreamBasicDescription asbd; memset(&asbd,0,sizeof(asbd)); UInt32 sz=sizeof(asbd);
        if (AudioUnitGetProperty(inUnit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,0,&asbd,&sz)==noErr && asbd.mFormatID==kAudioFormatLinearPCM) {
            pthread_mutex_lock(&gStreamLock); gCachedUnit=inUnit; gCachedASBD=asbd; gCachedValid=YES; pthread_mutex_unlock(&gStreamLock);
        }
    }
    return status;
}

static OSStatus (*orig_AudioUnitRender)(AudioUnit,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32,UInt32,AudioBufferList*)=NULL;
static OSStatus hooked_AudioUnitRender(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    if (!orig_AudioUnitRender) return -1;
    intptr_t depth=CRPGetRenderDepth(); CRPSetRenderDepth(depth+1);
    OSStatus status=orig_AudioUnitRender(inUnit,ioActionFlags,inTimeStamp,inBusNumber,inNumberFrames,ioData);
    CRPSetRenderDepth(depth);
    if (status==noErr) CRPCaptureRenderedAudio(inUnit, ioActionFlags, inBusNumber, inNumberFrames, ioData);
    return status;
}
extern OSStatus AudioUnitProcess(AudioUnit,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32,AudioBufferList*);
static OSStatus (*orig_AudioUnitProcess)(AudioUnit,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32,AudioBufferList*)=NULL;
static OSStatus hooked_AudioUnitProcess(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inNumberFrames, AudioBufferList *ioData) {
    if (!orig_AudioUnitProcess) return -1;
    intptr_t depth=CRPGetRenderDepth(); CRPSetRenderDepth(depth+1);
    OSStatus status=orig_AudioUnitProcess(inUnit,ioActionFlags,inTimeStamp,inNumberFrames,ioData);
    CRPSetRenderDepth(depth);
    if (status==noErr) CRPCaptureRenderedAudio(inUnit, ioActionFlags, 0, inNumberFrames, ioData);
    return status;
}

extern OSStatus AudioConverterFillComplexBuffer(AudioConverterRef, AudioConverterComplexInputDataProc, void*, UInt32*, AudioBufferList*, AudioStreamPacketDescription*);
static OSStatus (*orig_AudioConverterFillComplexBuffer)(AudioConverterRef, AudioConverterComplexInputDataProc, void*, UInt32*, AudioBufferList*, AudioStreamPacketDescription*)=NULL;
static OSStatus hooked_AudioConverterFillComplexBuffer(AudioConverterRef inAudioConverter, AudioConverterComplexInputDataProc inInputDataProc, void *inInputDataProcUserData, UInt32 *ioOutputDataPacketSize, AudioBufferList *outOutputData, AudioStreamPacketDescription *outPacketDescription) {
    if (!orig_AudioConverterFillComplexBuffer) return -1;
    OSStatus status=orig_AudioConverterFillComplexBuffer(inAudioConverter, inInputDataProc, inInputDataProcUserData, ioOutputDataPacketSize, outOutputData, outPacketDescription);
    if (status==noErr && [AudioRecorderEngine sharedInstance].isRecording && outOutputData && ioOutputDataPacketSize && *ioOutputDataPacketSize>0) {
        CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
        pthread_mutex_lock(&gStreamLock);
        BOOL shouldSkip = (gLastAnyCaptureTime != 0.0 && (now - gLastAnyCaptureTime) < 0.012);
        pthread_mutex_unlock(&gStreamLock);
        if (shouldSkip) return status;
        AudioStreamBasicDescription asbd; memset(&asbd,0,sizeof(asbd)); UInt32 sz=sizeof(asbd);
        OSStatus s=AudioConverterGetProperty(inAudioConverter, kAudioConverterCurrentOutputStreamDescription, &sz, &asbd);
        if (s==noErr && asbd.mFormatID==kAudioFormatLinearPCM && outOutputData->mNumberBuffers>0) {
            UInt32 frames=*ioOutputDataPacketSize;
            if (asbd.mFramesPerPacket>0) frames = (*ioOutputDataPacketSize) * asbd.mFramesPerPacket;
            BOOL hasSignal=NO;
            for (UInt32 b=0;b<outOutputData->mNumberBuffers;b++) { if (outOutputData->mBuffers[b].mData && outOutputData->mBuffers[b].mDataByteSize>=4) { const uint32_t *w=(const uint32_t*)outOutputData->mBuffers[b].mData; UInt32 cnt=MIN((UInt32)(outOutputData->mBuffers[b].mDataByteSize/4),16u); for (UInt32 i=0;i<cnt;i+=4) if (w[i]!=0) { hasSignal=YES; break; } if (hasSignal) break; } }
            if (hasSignal) {
                pthread_mutex_lock(&gStreamLock); gLastAnyCaptureTime=now; gLastOutputTime=now; pthread_mutex_unlock(&gStreamLock);
                [[AudioRecorderEngine sharedInstance] appendAudioBufferList:outOutputData frames:frames format:asbd];
            }
        }
    }
    return status;
}

static void CRPStartNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    CRPResetActiveStreamLock(); [[AudioRecorderEngine sharedInstance] startRecording];
}
static void CRPStopNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [[AudioRecorderEngine sharedInstance] stopRecording]; CRPResetActiveStreamLock();
}
static void CRPPingNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CRP_DARWIN_PONG_NOTIFICATION, NULL, NULL, true);
    });
}

%end

// ============================================================================
// Constructor – absolute minimal, defer all I/O
// ============================================================================
%ctor {
    @autoreleasepool {
        NSString *processName=[NSProcessInfo processInfo].processName ?: @"";
        CFNotificationCenterRef darwinCenter=CFNotificationCenterGetDarwinNotifyCenter();
        if ([processName isEqualToString:@"InCallService"]) {
            %init(InCallServiceUI);
            CFNotificationCenterAddObserver(darwinCenter,NULL,CRPInCallCapturingDarwinCallback,CRP_DARWIN_CAPTURING_NOTIFICATION,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
            // TUCall observers – dispatch to main queue lazily
            NSNotificationCenter *nc=[NSNotificationCenter defaultCenter];
            [nc addObserverForName:@"TUCallCenterCallStatusChangedNotification" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note){ CRPHandleCallStatusChanged(note); }];
            [nc addObserverForName:@"TUCallStatusChangedNotification" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note){ CRPHandleCallStatusChanged(note); }];
            // Defer log – no file I/O at load time (fixes dial freeze)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2*NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                [AudioRecorderEngine appendDiagnosticLog:@"InCallServiceUI v1.3.4 loaded (deferred)"];
            });
        } else if ([processName isEqualToString:@"mediaserverd"] || [processName isEqualToString:@"audiomxd"] || [processName isEqualToString:@"callservicesd"] || [processName isEqualToString:@"avconferenced"] || [processName isEqualToString:@"coreaudiod"]) {
            %init(AudioDaemonHooks);
            CFNotificationCenterAddObserver(darwinCenter,NULL,CRPStartNotificationCallback,CRP_DARWIN_START_NOTIFICATION,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(darwinCenter,NULL,CRPStopNotificationCallback,CRP_DARWIN_STOP_NOTIFICATION,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(darwinCenter,NULL,CRPPingNotificationCallback,CRP_DARWIN_PING_NOTIFICATION,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
            MSHookFunction((void*)AudioUnitInitialize,(void*)hooked_AudioUnitInitialize,(void**)&orig_AudioUnitInitialize);
            MSHookFunction((void*)AudioUnitRender,(void*)hooked_AudioUnitRender,(void**)&orig_AudioUnitRender);
            void *procSym=MSFindSymbol(NULL,"_AudioUnitProcess");
            if (procSym) MSHookFunction(procSym,(void*)hooked_AudioUnitProcess,(void**)&orig_AudioUnitProcess);
            void *convSym=MSFindSymbol(NULL,"_AudioConverterFillComplexBuffer");
            if (convSym) MSHookFunction(convSym,(void*)hooked_AudioConverterFillComplexBuffer,(void**)&orig_AudioConverterFillComplexBuffer);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0*NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                [AudioRecorderEngine appendDiagnosticLog:@"AudioDaemonHooks v1.3.4 loaded (deferred, cache)"];
            });
        }
    }
}
