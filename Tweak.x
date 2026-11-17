#import "Tweak.h"
#import "AudioRecorderEngine.h"
#include <pthread.h>
#include <stdint.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

static CRPFloatingRecorderView *gFloatingRecorderView = nil;

// Forward declare helper from AudioRecorderEngine.m for payload check inside Tweak
static uint32_t CRPGetWavPayload(NSString *path) {
    if (path.length == 0) return 0;
    const char *cPath = path.fileSystemRepresentation;
    if (!cPath) return 0;
    struct stat st;
    if (stat(cPath, &st) != 0) return 0;
    if (st.st_size < 44) return 0;
    int fd = open(cPath, O_RDONLY);
    if (fd < 0) return 0;
    uint8_t hdr[12];
    if (read(fd, hdr, 12) != 12) { close(fd); return 0; }
    if (memcmp(hdr, "RIFF", 4) != 0 || memcmp(hdr+8, "WAVE", 4) != 0) { close(fd); return (st.st_size > 44) ? (uint32_t)(st.st_size-44) : 0; }
    off_t off = 12;
    while (off + 8 <= st.st_size) {
        uint8_t ch[8];
        if (lseek(fd, off, SEEK_SET) == (off_t)-1) break;
        if (read(fd, ch, 8) != 8) break;
        uint32_t sz = 0; memcpy(&sz, ch+4, 4);
        if (memcmp(ch, "data", 4) == 0) { close(fd); return sz; }
        if (sz > (uint32_t)st.st_size) break;
        off += 8 + (off_t)sz + (sz & 1);
        if (off > st.st_size || off > 1024*1024) break;
    }
    close(fd);
    return 0;
}

// ===========================================================================
// Fallback Direct Recorder inside InCallService
// v1.3.2: Only Strategies A (inherited AudioQueue) and B (RemoteIO) –
// NO AVAudioSession category changes, NO AVAudioRecorder.
// This prevents: 1) dial freeze (AVAudioSession activation blocks PhoneCall session)
//                2) mic route switch (speaker/receiver toggle)
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
    [[AudioRecorderEngine sharedInstance] startRecording];

    // Run heavy audio setup off main thread to avoid dial freeze
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Strategy A: Try inheriting InCallService's active telephony session without touching AVAudioSession
        memset(&self->_aqFormat,0,sizeof(self->_aqFormat));
        self->_aqFormat.mSampleRate=16000.0; self->_aqFormat.mFormatID=kAudioFormatLinearPCM;
        self->_aqFormat.mFormatFlags=kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked;
        self->_aqFormat.mBytesPerPacket=2; self->_aqFormat.mFramesPerPacket=1; self->_aqFormat.mBytesPerFrame=2; self->_aqFormat.mChannelsPerFrame=1; self->_aqFormat.mBitsPerChannel=16;
        OSStatus status = AudioQueueNewInput(&self->_aqFormat, CRPAudioQueueInputCallback, (__bridge void*)self, NULL, kCFRunLoopCommonModes, 0, &self->_audioQueue);
        if (status==noErr && self->_audioQueue) {
            for (int i=0;i<CRP_AQ_BUFFER_COUNT;i++) { AudioQueueAllocateBuffer(self->_audioQueue, 6400, &self->_buffers[i]); AudioQueueEnqueueBuffer(self->_audioQueue, self->_buffers[i], 0, NULL); }
            status = AudioQueueStart(self->_audioQueue, NULL);
            if (status==noErr) {
                [AudioRecorderEngine appendDiagnosticLog:@"InCallService fallback Strategy A succeeded (inherited telephony session, no route change)"];
                return;
            }
            [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Strategy A AudioQueueStart failed %d, trying RemoteIO", (int)status]];
            AudioQueueDispose(self->_audioQueue,true); self->_audioQueue=NULL;
        } else {
            [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Strategy A AudioQueueNewInput failed %d", (int)status]];
            self->_audioQueue=NULL;
        }

        // Strategy B: RemoteIO AudioUnit input (does not require AVAudioSession category change)
        AudioComponentDescription desc; memset(&desc,0,sizeof(desc));
        desc.componentType=kAudioUnitType_Output; desc.componentSubType=kAudioUnitSubType_RemoteIO; desc.componentManufacturer=kAudioUnitManufacturer_Apple;
        AudioComponent comp = AudioComponentFindNext(NULL, &desc);
        if (!comp) { [AudioRecorderEngine appendDiagnosticLog:@"Strategy B no RemoteIO component – fallback unavailable"]; [AudioRecorderEngine appendDiagnosticLog:@"Fallback not available: daemon capture required – check RootHide injection for mediaserverd/audiomxd"]; return; }
        OSStatus s = AudioComponentInstanceNew(comp, &self->_remoteIOUnit);
        if (s!=noErr || !self->_remoteIOUnit) { [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Strategy B instance failed %d – daemon required", (int)s]]; return; }
        UInt32 enable=1; s=AudioUnitSetProperty(self->_remoteIOUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, sizeof(enable));
        if (s!=noErr) { AudioComponentInstanceDispose(self->_remoteIOUnit); self->_remoteIOUnit=NULL; [AudioRecorderEngine appendDiagnosticLog:@"Strategy B EnableIO input failed"]; return; }
        enable=0; AudioUnitSetProperty(self->_remoteIOUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, sizeof(enable));
        AudioStreamBasicDescription fmt; memset(&fmt,0,sizeof(fmt));
        fmt.mSampleRate=16000; fmt.mFormatID=kAudioFormatLinearPCM; fmt.mFormatFlags=kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked;
        fmt.mBytesPerPacket=2; fmt.mFramesPerPacket=1; fmt.mBytesPerFrame=2; fmt.mChannelsPerFrame=1; fmt.mBitsPerChannel=16;
        s=AudioUnitSetProperty(self->_remoteIOUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, sizeof(fmt));
        if (s!=noErr) { AudioComponentInstanceDispose(self->_remoteIOUnit); self->_remoteIOUnit=NULL; [AudioRecorderEngine appendDiagnosticLog:@"Strategy B stream format failed"]; return; }
        AURenderCallbackStruct cb; cb.inputProc=CRPRemoteIOInputCallback; cb.inputProcRefCon=(void*)self->_remoteIOUnit;
        s=AudioUnitSetProperty(self->_remoteIOUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, sizeof(cb));
        if (s!=noErr) { AudioComponentInstanceDispose(self->_remoteIOUnit); self->_remoteIOUnit=NULL; [AudioRecorderEngine appendDiagnosticLog:@"Strategy B callback setup failed"]; return; }
        s=AudioUnitInitialize(self->_remoteIOUnit);
        if (s!=noErr) { AudioComponentInstanceDispose(self->_remoteIOUnit); self->_remoteIOUnit=NULL; [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Strategy B initialize failed %d", (int)s]]; return; }
        s=AudioOutputUnitStart(self->_remoteIOUnit);
        if (s==noErr) {
            [AudioRecorderEngine appendDiagnosticLog:@"InCallService fallback Strategy B RemoteIO started (no route change)"];
            return;
        }
        AudioUnitUninitialize(self->_remoteIOUnit); AudioComponentInstanceDispose(self->_remoteIOUnit); self->_remoteIOUnit=NULL;
        [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Strategy B RemoteIO start failed %d – daemon capture required", (int)s]];
        [AudioRecorderEngine appendDiagnosticLog:@"Fallback strategies exhausted – ensure RootHide injection for audio daemons (mediaserverd/audiomxd) is enabled"];
    });
}

- (void)stopFallback {
    if (!_running) return;
    _running=NO;
    // Stop audio queues on background to avoid main-thread block
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
    self=[super initWithFrame:frame];
    if (self) {
        self.backgroundColor=[UIColor colorWithWhite:0.08 alpha:0.86];
        self.layer.cornerRadius=CGRectGetHeight(frame)/2.0; self.layer.borderWidth=1.0;
        self.layer.borderColor=[UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
        self.layer.shadowColor=[UIColor blackColor].CGColor; self.layer.shadowOpacity=0.35f; self.layer.shadowRadius=8.0; self.layer.shadowOffset=CGSizeMake(0,3); self.clipsToBounds=NO;
        _dotView=[[UIView alloc] initWithFrame:CGRectMake(14.0,(CGRectGetHeight(frame)-14.0)/2.0,14.0,14.0)];
        _dotView.layer.cornerRadius=7.0; _dotView.backgroundColor=[UIColor systemRedColor]; _dotView.userInteractionEnabled=NO; [self addSubview:_dotView];
        _timerLabel=[[UILabel alloc] initWithFrame:CGRectMake(35.0,0.0,CGRectGetWidth(frame)-45.0,CGRectGetHeight(frame))];
        _timerLabel.text=@"00:00"; _timerLabel.textColor=[UIColor whiteColor];
        _timerLabel.font=[UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightSemibold]; _timerLabel.textAlignment=NSTextAlignmentLeft; _timerLabel.userInteractionEnabled=NO; [self addSubview:_timerLabel];
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
    UIImpactFeedbackGenerator *feedback=[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; [feedback impactOccurred];
    if (self.isRecording) [self stopRecordingAll]; else [self startRecordingAll];
}

- (void)startRecordingAll {
    self.sessionGeneration+=1; NSUInteger gen=self.sessionGeneration;
    self.isRecording=YES; self.verifiedCapturing=NO; self.elapsedSeconds=0; self.timerLabel.text=@"00:00";
    self.backgroundColor=[UIColor colorWithRed:0.62 green:0.07 blue:0.09 alpha:0.92]; self.dotView.backgroundColor=[UIColor whiteColor];
    CABasicAnimation *pulse=[CABasicAnimation animationWithKeyPath:@"opacity"]; pulse.fromValue=@(1.0); pulse.toValue=@(0.25); pulse.duration=0.65; pulse.autoreverses=YES; pulse.repeatCount=HUGE_VALF; [self.dotView.layer addAnimation:pulse forKey:@"crp_pulse"];
    [self.elapsedTimer invalidate];
    NSTimer *timer=[NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(tickTimer) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes]; self.elapsedTimer=timer;
    [AudioRecorderEngine appendDiagnosticLog:@"User tapped START in InCallService -> posting Darwin start"];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CRP_DARWIN_START_NOTIFICATION, NULL, NULL, true);
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.85*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf=weakSelf; if (!strongSelf || !strongSelf.isRecording || strongSelf.sessionGeneration!=gen) return;
        if (!strongSelf.verifiedCapturing) {
            [AudioRecorderEngine appendDiagnosticLog:@"No daemon capture ACK after 0.85s -> activating InCallService fallback (A/B only, no AVSession)"];
            [[CRPInCallFallbackRecorder sharedInstance] startFallbackIfNeeded];
        }
    });
}

- (void)stopRecordingAll {
    self.sessionGeneration+=1; self.isRecording=NO; self.verifiedCapturing=NO;
    [self.elapsedTimer invalidate]; self.elapsedTimer=nil;
    [self.dotView.layer removeAnimationForKey:@"crp_pulse"]; self.dotView.backgroundColor=[UIColor systemRedColor];
    self.elapsedSeconds=0; self.timerLabel.text=@"00:00"; self.backgroundColor=[UIColor colorWithWhite:0.08 alpha:0.86];
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
    if ([clsName containsString:@"Keyboard"] || [clsName containsString:@"TextEffects"]) return;
    CGRect bounds=container.bounds;
    if (CGRectGetWidth(bounds)<200.0 || CGRectGetHeight(bounds)<120.0) return;
    if (!gFloatingRecorderView) {
        CGFloat width=118.0, height=44.0;
        CGFloat topInset=MAX(58.0, container.safeAreaInsets.top+12.0);
        CGFloat xPos=MAX(16.0, CGRectGetWidth(bounds)-width-16.0);
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
// Group 1: InCallServiceUI (Loaded in InCallService)
// ============================================================================
%group InCallServiceUI

%hook PHAudioCallViewController
- (void)viewDidAppear:(BOOL)animated { %orig; CRPAttachFloatingRecorderToContainer(self.view.window ?: self.view); }
%end

%hook CNKFaceTimeInCallViewController
- (void)viewDidAppear:(BOOL)animated { %orig; CRPAttachFloatingRecorderToContainer(self.view.window ?: self.view); }
%end

static void CRPHandleCallStatusChanged(NSNotification *note) {
    // Lightweight check off main thread if needed, but must dispatch stop to main
    BOOL shouldStop=NO;
    id call=note.object;
    if (call && [call respondsToSelector:@selector(status)]) { int status=[(TUCall*)call status]; if (status==6) shouldStop=YES; }
    // Only check TUCallCenter if notification didn't already indicate disconnect - avoid extra IPC on every call event
    if (!shouldStop) {
        Class callCenterCls=objc_getClass("TUCallCenter");
        if (callCenterCls && [callCenterCls respondsToSelector:@selector(sharedInstance)]) {
            // Dispatch currentCalls check to avoid blocking notification thread
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
// Group 2: AudioDaemonHooks (Loaded in mediaserverd / audiomxd / callservicesd / avconferenced / coreaudiod)
// ============================================================================
%group AudioDaemonHooks

static pthread_mutex_t gStreamLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_key_t gRenderDepthKey;
static pthread_once_t gRenderKeyOnce = PTHREAD_ONCE_INIT;
static AudioUnit gActiveUnit = NULL;
static UInt32 gActiveBus = 0;
static CFAbsoluteTime gLastRenderTimestamp = 0.0;
static CFAbsoluteTime gLastNonSilentTimestamp = 0.0;

static void CRPInitRenderDepthKey(void) { pthread_key_create(&gRenderDepthKey,NULL); }
static inline intptr_t CRPGetRenderDepth(void) { pthread_once(&gRenderKeyOnce,CRPInitRenderDepthKey); return (intptr_t)pthread_getspecific(gRenderDepthKey); }
static inline void CRPSetRenderDepth(intptr_t v) { pthread_once(&gRenderKeyOnce,CRPInitRenderDepthKey); pthread_setspecific(gRenderDepthKey,(const void*)v); }
static void CRPResetActiveStreamLock(void) { pthread_mutex_lock(&gStreamLock); gActiveUnit=NULL; gActiveBus=0; gLastRenderTimestamp=0.0; gLastNonSilentTimestamp=0.0; pthread_mutex_unlock(&gStreamLock); }
static BOOL CRPBufferListHasSignal(const AudioBufferList *ioData, const AudioUnitRenderActionFlags *flags) {
    if (flags && ((*flags) & kAudioUnitRenderAction_OutputIsSilence)) return NO;
    if (!ioData || ioData->mNumberBuffers==0) return NO;
    const AudioBuffer *buf=&ioData->mBuffers[0];
    if (!buf->mData || buf->mDataByteSize<4) return NO;
    const uint32_t *words=(const uint32_t*)buf->mData;
    UInt32 count=MIN((UInt32)(buf->mDataByteSize/sizeof(uint32_t)),64u);
    UInt32 step=MAX(1u,count/16u);
    for (UInt32 i=0;i<count;i+=step) if (words[i]!=0u) return YES;
    return NO;
}

static void CRPCaptureRenderedAudio(AudioUnit inUnit, const AudioUnitRenderActionFlags *ioActionFlags, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    AudioRecorderEngine *engine=[AudioRecorderEngine sharedInstance];
    if (!engine.isRecording || !inUnit || !ioData || inNumberFrames==0) return;
    AudioStreamBasicDescription asbd; memset(&asbd,0,sizeof(asbd)); UInt32 propSize=sizeof(asbd);
    OSStatus fmtStatus=AudioUnitGetProperty(inUnit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,inBusNumber,&asbd,&propSize);
    if (fmtStatus!=noErr) { propSize=sizeof(asbd); fmtStatus=AudioUnitGetProperty(inUnit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,inBusNumber,&asbd,&propSize); }
    if (fmtStatus!=noErr || asbd.mFormatID!=kAudioFormatLinearPCM) return;
    BOOL hasSignal=CRPBufferListHasSignal(ioData, ioActionFlags);
    CFAbsoluteTime now=CFAbsoluteTimeGetCurrent(); BOOL allowThisStream=NO;
    pthread_mutex_lock(&gStreamLock);
    if (gActiveUnit==NULL || (now - gLastRenderTimestamp) > 0.45) { gActiveUnit=inUnit; gActiveBus=inBusNumber; }
    else if (hasSignal && (gActiveUnit!=inUnit || gActiveBus!=inBusNumber) && (now - gLastNonSilentTimestamp) > 0.25) { gActiveUnit=inUnit; gActiveBus=inBusNumber; }
    if (gActiveUnit==inUnit && gActiveBus==inBusNumber) { gLastRenderTimestamp=now; if (hasSignal) gLastNonSilentTimestamp=now; allowThisStream=YES; }
    pthread_mutex_unlock(&gStreamLock);
    if (allowThisStream) [engine appendAudioBufferList:ioData frames:inNumberFrames format:asbd];
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
    if (status==noErr && inUnit) AudioUnitAddRenderNotify(inUnit, CRPAudioUnitRenderNotify, (void*)inUnit);
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

// AudioConverterFillComplexBuffer hook - captures mixed/converted audio that bypasses AudioUnitRender
extern OSStatus AudioConverterFillComplexBuffer(AudioConverterRef, AudioConverterComplexInputDataProc, void*, UInt32*, AudioBufferList*, AudioStreamPacketDescription*);
static OSStatus (*orig_AudioConverterFillComplexBuffer)(AudioConverterRef, AudioConverterComplexInputDataProc, void*, UInt32*, AudioBufferList*, AudioStreamPacketDescription*)=NULL;
static OSStatus hooked_AudioConverterFillComplexBuffer(AudioConverterRef inAudioConverter, AudioConverterComplexInputDataProc inInputDataProc, void *inInputDataProcUserData, UInt32 *ioOutputDataPacketSize, AudioBufferList *outOutputData, AudioStreamPacketDescription *outPacketDescription) {
    if (!orig_AudioConverterFillComplexBuffer) return -1;
    OSStatus status=orig_AudioConverterFillComplexBuffer(inAudioConverter, inInputDataProc, inInputDataProcUserData, ioOutputDataPacketSize, outOutputData, outPacketDescription);
    if (status==noErr && [AudioRecorderEngine sharedInstance].isRecording && outOutputData && ioOutputDataPacketSize && *ioOutputDataPacketSize>0) {
        AudioStreamBasicDescription asbd; memset(&asbd,0,sizeof(asbd)); UInt32 sz=sizeof(asbd);
        OSStatus s=AudioConverterGetProperty(inAudioConverter, kAudioConverterCurrentOutputStreamDescription, &sz, &asbd);
        if (s==noErr && asbd.mFormatID==kAudioFormatLinearPCM && outOutputData->mNumberBuffers>0) {
            UInt32 frames=*ioOutputDataPacketSize;
            if (asbd.mFramesPerPacket>0) frames = (*ioOutputDataPacketSize) * asbd.mFramesPerPacket;
            BOOL hasSignal=NO;
            for (UInt32 b=0;b<outOutputData->mNumberBuffers;b++) { if (outOutputData->mBuffers[b].mData && outOutputData->mBuffers[b].mDataByteSize>=4) { const uint32_t *w=(const uint32_t*)outOutputData->mBuffers[b].mData; UInt32 cnt=MIN((UInt32)(outOutputData->mBuffers[b].mDataByteSize/4),32u); for (UInt32 i=0;i<cnt;i+=4) if (w[i]!=0) { hasSignal=YES; break; } if (hasSignal) break; } }
            if (hasSignal) {
                [[AudioRecorderEngine sharedInstance] appendAudioBufferList:outOutputData frames:frames format:asbd];
            } else {
                static CFAbsoluteTime lastSilentLog=0; CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
                if (now-lastSilentLog>5.0) { lastSilentLog=now; [[AudioRecorderEngine sharedInstance] appendAudioBufferList:outOutputData frames:frames format:asbd]; }
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
    // Lightweight pong – do NOT probe directory synchronously; defer to background
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        NSString *dir=[AudioRecorderEngine resolveWritableRecordingsDirectory] ?: @"NONE";
        [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"PONG alive (writableDir=%@)", dir]];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CRP_DARWIN_PONG_NOTIFICATION, NULL, NULL, true);
    });
}

%end

// ============================================================================
// Constructor – minimal work on main thread to avoid dial freeze
// ============================================================================
%ctor {
    @autoreleasepool {
        NSString *processName=[NSProcessInfo processInfo].processName ?: @"";
        CFNotificationCenterRef darwinCenter=CFNotificationCenterGetDarwinNotifyCenter();
        if ([processName isEqualToString:@"InCallService"]) {
            %init(InCallServiceUI);
            CFNotificationCenterAddObserver(darwinCenter,NULL,CRPInCallCapturingDarwinCallback,CRP_DARWIN_CAPTURING_NOTIFICATION,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
            NSNotificationCenter *nc=[NSNotificationCenter defaultCenter];
            [nc addObserverForName:@"TUCallCenterCallStatusChangedNotification" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note){ CRPHandleCallStatusChanged(note); }];
            [nc addObserverForName:@"TUCallStatusChangedNotification" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note){ CRPHandleCallStatusChanged(note); }];
            // Defer heavy I/O off main thread
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                NSString *dir=[AudioRecorderEngine resolveWritableRecordingsDirectory] ?: @"NONE";
                [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Loaded InCallServiceUI v1.3.2 (writableDir=%@, no AVSession, no UIWindow hook)", dir]];
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
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                NSString *dir=[AudioRecorderEngine resolveWritableRecordingsDirectory] ?: @"NONE";
                [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Loaded AudioDaemonHooks v1.3.2 (writableDir=%@, AUProcess=%@, AudioConverter=%@)", dir, procSym?@"hooked":@"n/a", convSym?@"hooked":@"n/a"]];
            });
        }
    }
}
