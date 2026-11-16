#import "Tweak.h"
#import "AudioRecorderEngine.h"
#include <pthread.h>
#include <stdint.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

static CRPFloatingRecorderView *gFloatingRecorderView = nil;

static uint32_t CRPGetWavPayload(NSString *path) {
    if (path.length==0) return 0;
    const char *cPath=path.fileSystemRepresentation; if (!cPath) return 0;
    struct stat st; if (stat(cPath,&st)!=0) return 0; if (st.st_size<44) return 0;
    int fd=open(cPath,O_RDONLY); if (fd<0) return 0;
    uint8_t hdr[12]; if (read(fd,hdr,12)!=12) { close(fd); return 0; }
    if (memcmp(hdr,"RIFF",4)!=0 || memcmp(hdr+8,"WAVE",4)!=0) { close(fd); return (st.st_size>44)?(uint32_t)(st.st_size-44):0; }
    off_t off=12;
    while (off+8 <= st.st_size) {
        uint8_t ch[8]; if (lseek(fd,off,SEEK_SET)==(off_t)-1) break; if (read(fd,ch,8)!=8) break;
        uint32_t sz=0; memcpy(&sz,ch+4,4);
        if (memcmp(ch,"data",4)==0) { close(fd); return sz; }
        if (sz > (uint32_t)st.st_size) break;
        off+=8+(off_t)sz+(sz&1); if (off>st.st_size || off>1024*1024) break;
    }
    close(fd); return 0;
}

// Collect current call metadata for HQ naming
static NSDictionary *CRPCurrentCallMetadata(void) {
    @try {
        Class ccCls=objc_getClass("TUCallCenter");
        if (!ccCls || ![ccCls respondsToSelector:@selector(sharedInstance)]) return nil;
        TUCallCenter *center=[ccCls sharedInstance];
        if (![center respondsToSelector:@selector(currentCalls)]) return nil;
        NSArray *calls=center.currentCalls;
        if (calls.count==0) return nil;
        id call=calls.firstObject;
        NSString *handle=@"Unknown";
        NSString *name=@"";
        NSString *provider=@"";
        @try {
            if ([call respondsToSelector:@selector(handle)]) {
                id h=[call valueForKey:@"handle"];
                if ([h respondsToSelector:@selector(value)]) {
                    id hv = [(id)h performSelector:@selector(value)];
                    if (hv) handle = [NSString stringWithFormat:@"%@", hv];
                } else if ([h isKindOfClass:[NSString class]]) handle=h;
            } else if ([call respondsToSelector:@selector(valueForKey:)]) {
                id v=[call valueForKey:@"handle"]; if (v) handle=[NSString stringWithFormat:@"%@",v];
            }
        } @catch (NSException *e) {}
        @try {
            if ([call respondsToSelector:@selector(callerNameFromNetwork)]) { id n=[call valueForKey:@"callerNameFromNetwork"]; if (n) name=[NSString stringWithFormat:@"%@",n]; }
            if (name.length==0 && [call respondsToSelector:@selector(displayName)]) { id n=[call valueForKey:@"displayName"]; if (n) name=[NSString stringWithFormat:@"%@",n]; }
            if (name.length==0 && [call respondsToSelector:@selector(contactIdentifier)]) { id n=[call valueForKey:@"contactIdentifier"]; if (n) name=[NSString stringWithFormat:@"%@",n]; }
        } @catch (NSException *e) {}
        @try { id prov=[call valueForKey:@"provider"]; if (prov) provider=[NSString stringWithFormat:@"%@",prov]; } @catch (NSException *e) {}
        NSDateFormatter *df=[[NSDateFormatter alloc] init]; df.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; df.dateFormat=@"yyyy-MM-dd HH:mm:ss";
        return @{ @"handle": handle ?: @"Unknown", @"contact": name ?: @"", @"provider": provider ?: @"", @"date": [df stringFromDate:[NSDate date]], @"status": @([call respondsToSelector:@selector(status)] ? [(TUCall*)call status] : 0) };
    } @catch (NSException *e) { return nil; }
}

// ===========================================================================
// Fallback Recorder inside InCallService - HQ 48kHz, dual-channel aware
// ===========================================================================
#define CRP_AQ_BUFFER_COUNT 3

@interface CRPInCallFallbackRecorder : NSObject {
    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _buffers[CRP_AQ_BUFFER_COUNT];
    AudioStreamBasicDescription _aqFormat;
    AudioUnit _remoteIOUnit;
    BOOL _running;
    NSTimer *_monitorTimer;
}
@property (nonatomic, strong) AVAudioRecorder *avFallbackRecorder;
@property (nonatomic, copy) NSString *avRecorderPath;
+ (instancetype)sharedInstance;
- (void)startFallbackIfNeeded;
- (void)stopFallback;
@end

static void CRPAudioQueueInputCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer, const AudioTimeStamp *inStartTime, UInt32 inNumberPacketDescriptions, const AudioStreamPacketDescription *inPacketDescs) {
    CRPInCallFallbackRecorder *selfRef=(__bridge CRPInCallFallbackRecorder *)inUserData; if (!selfRef) return;
    if (inBuffer && inBuffer->mAudioDataByteSize>0 && [AudioRecorderEngine sharedInstance].isRecording) {
        AudioStreamBasicDescription asbd; memset(&asbd,0,sizeof(asbd));
        asbd.mSampleRate=48000.0; asbd.mFormatID=kAudioFormatLinearPCM; asbd.mFormatFlags=kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked;
        asbd.mBytesPerPacket=2; asbd.mFramesPerPacket=1; asbd.mBytesPerFrame=2; asbd.mChannelsPerFrame=1; asbd.mBitsPerChannel=16;
        UInt32 frames=inBuffer->mAudioDataByteSize/2u;
        AudioBufferList abl; abl.mNumberBuffers=1; abl.mBuffers[0].mNumberChannels=1; abl.mBuffers[0].mDataByteSize=inBuffer->mAudioDataByteSize; abl.mBuffers[0].mData=inBuffer->mAudioData;
        [[AudioRecorderEngine sharedInstance] appendAudioBufferList:&abl frames:frames format:asbd];
    }
    if (inAQ && inBuffer) AudioQueueEnqueueBuffer(inAQ,inBuffer,0,NULL);
}

static OSStatus CRPRemoteIOInputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    if (![AudioRecorderEngine sharedInstance].isRecording) return noErr;
    AudioUnit unit=(AudioUnit)inRefCon; if (!unit || !ioData) return noErr;
    OSStatus status=AudioUnitRender(unit,ioActionFlags,inTimeStamp,1,inNumberFrames,ioData);
    if (status==noErr && ioData->mNumberBuffers>0) {
        AudioStreamBasicDescription asbd; memset(&asbd,0,sizeof(asbd)); UInt32 sz=sizeof(asbd);
        if (AudioUnitGetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,1,&asbd,&sz)==noErr) {
            if (asbd.mFormatID==kAudioFormatLinearPCM) [[AudioRecorderEngine sharedInstance] appendAudioBufferList:ioData frames:inNumberFrames format:asbd];
        } else {
            asbd.mSampleRate=48000; asbd.mFormatID=kAudioFormatLinearPCM; asbd.mFormatFlags=kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked;
            asbd.mBytesPerPacket=2; asbd.mFramesPerPacket=1; asbd.mBytesPerFrame=2; asbd.mChannelsPerFrame=1; asbd.mBitsPerChannel=16;
            [[AudioRecorderEngine sharedInstance] appendAudioBufferList:ioData frames:inNumberFrames format:asbd];
        }
    }
    return status;
}

@implementation CRPInCallFallbackRecorder
+ (instancetype)sharedInstance { static CRPInCallFallbackRecorder *inst=nil; static dispatch_once_t onceToken; dispatch_once(&onceToken, ^{ inst=[[CRPInCallFallbackRecorder alloc] init]; }); return inst; }

- (void)startFallbackIfNeeded {
    if (_running) return; _running=YES;
    NSDictionary *meta=CRPCurrentCallMetadata();
    [[AudioRecorderEngine sharedInstance] startRecordingWithMetadata:meta];
    // Strategy A: inherited session, HQ 48kHz
    memset(&_aqFormat,0,sizeof(_aqFormat)); _aqFormat.mSampleRate=48000.0; _aqFormat.mFormatID=kAudioFormatLinearPCM; _aqFormat.mFormatFlags=kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked; _aqFormat.mBytesPerPacket=2; _aqFormat.mFramesPerPacket=1; _aqFormat.mBytesPerFrame=2; _aqFormat.mChannelsPerFrame=1; _aqFormat.mBitsPerChannel=16;
    OSStatus status=AudioQueueNewInput(&_aqFormat,CRPAudioQueueInputCallback,(__bridge void*)self,NULL,kCFRunLoopCommonModes,0,&_audioQueue);
    if (status==noErr && _audioQueue) {
        for (int i=0;i<CRP_AQ_BUFFER_COUNT;i++) { AudioQueueAllocateBuffer(_audioQueue,9600,&_buffers[i]); AudioQueueEnqueueBuffer(_audioQueue,_buffers[i],0,NULL); }
        status=AudioQueueStart(_audioQueue,NULL);
        if (status==noErr) { [AudioRecorderEngine appendDiagnosticLog:@"Fallback A HQ 48kHz inherited session OK"]; return; }
        [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Fallback A start %d -> RemoteIO",(int)status]];
        AudioQueueDispose(_audioQueue,true); _audioQueue=NULL;
    }
    // Strategy B: RemoteIO HQ
    do {
        AudioComponentDescription desc; memset(&desc,0,sizeof(desc)); desc.componentType=kAudioUnitType_Output; desc.componentSubType=kAudioUnitSubType_RemoteIO; desc.componentManufacturer=kAudioUnitManufacturer_Apple;
        AudioComponent comp=AudioComponentFindNext(NULL,&desc); if (!comp) { [AudioRecorderEngine appendDiagnosticLog:@"Fallback B no RemoteIO"]; break; }
        OSStatus s=AudioComponentInstanceNew(comp,&_remoteIOUnit); if (s!=noErr||!_remoteIOUnit) break;
        UInt32 enable=1; s=AudioUnitSetProperty(_remoteIOUnit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,&enable,sizeof(enable)); if (s!=noErr) { AudioComponentInstanceDispose(_remoteIOUnit); _remoteIOUnit=NULL; break; }
        enable=0; AudioUnitSetProperty(_remoteIOUnit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,&enable,sizeof(enable));
        AudioStreamBasicDescription fmt; memset(&fmt,0,sizeof(fmt)); fmt.mSampleRate=48000; fmt.mFormatID=kAudioFormatLinearPCM; fmt.mFormatFlags=kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked; fmt.mBytesPerPacket=2; fmt.mFramesPerPacket=1; fmt.mBytesPerFrame=2; fmt.mChannelsPerFrame=1; fmt.mBitsPerChannel=16;
        s=AudioUnitSetProperty(_remoteIOUnit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,1,&fmt,sizeof(fmt)); if (s!=noErr) { AudioComponentInstanceDispose(_remoteIOUnit); _remoteIOUnit=NULL; break; }
        AURenderCallbackStruct cb; cb.inputProc=CRPRemoteIOInputCallback; cb.inputProcRefCon=(void*)_remoteIOUnit;
        s=AudioUnitSetProperty(_remoteIOUnit,kAudioOutputUnitProperty_SetInputCallback,kAudioUnitScope_Global,0,&cb,sizeof(cb)); if (s!=noErr) { AudioComponentInstanceDispose(_remoteIOUnit); _remoteIOUnit=NULL; break; }
        s=AudioUnitInitialize(_remoteIOUnit); if (s!=noErr) { AudioComponentInstanceDispose(_remoteIOUnit); _remoteIOUnit=NULL; break; }
        s=AudioOutputUnitStart(_remoteIOUnit); if (s==noErr) { [AudioRecorderEngine appendDiagnosticLog:@"Fallback B RemoteIO HQ 48kHz started"]; return; }
        AudioUnitUninitialize(_remoteIOUnit); AudioComponentInstanceDispose(_remoteIOUnit); _remoteIOUnit=NULL;
    } while(0);
    // Strategy C: minimal session, no VoiceChat
    @try {
        AVAudioSession *session=[AVAudioSession sharedInstance]; NSError *err=nil;
        [session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault options:(AVAudioSessionCategoryOptionMixWithOthers|AVAudioSessionCategoryOptionAllowBluetooth|AVAudioSessionCategoryOptionAllowBluetoothA2DP) error:&err];
        if (!err) [session setActive:YES withOptions:0 error:&err];
        if (!err) {
            status=AudioQueueNewInput(&_aqFormat,CRPAudioQueueInputCallback,(__bridge void*)self,NULL,kCFRunLoopCommonModes,0,&_audioQueue);
            if (status==noErr && _audioQueue) {
                for (int i=0;i<CRP_AQ_BUFFER_COUNT;i++) { AudioQueueAllocateBuffer(_audioQueue,9600,&_buffers[i]); AudioQueueEnqueueBuffer(_audioQueue,_buffers[i],0,NULL); }
                status=AudioQueueStart(_audioQueue,NULL);
                if (status==noErr) { [AudioRecorderEngine appendDiagnosticLog:@"Fallback C HQ session OK"]; return; }
                AudioQueueDispose(_audioQueue,true); _audioQueue=NULL;
            }
        }
    } @catch (NSException *e) {}
    // Strategy D: monitored AVAudioRecorder HQ 48kHz
    NSString *dir=[AudioRecorderEngine resolveWritableRecordingsDirectory];
    if (dir) {
        NSDateFormatter *df=[[NSDateFormatter alloc] init]; df.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; df.dateFormat=@"yyyy-MM-dd_HH-mm-ss";
        NSString *handle=meta[@"handle"] ?: @"Unknown"; handle=[handle stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
        NSString *wavPath=[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"Call_%@_%@_ICS.wav",[df stringFromDate:[NSDate date]],handle]];
        NSDictionary *settings=@{ AVFormatIDKey:@(kAudioFormatLinearPCM), AVSampleRateKey:@(48000.0), AVNumberOfChannelsKey:@(1), AVLinearPCMBitDepthKey:@(16), AVLinearPCMIsFloatKey:@NO, AVLinearPCMIsBigEndianKey:@NO, AVLinearPCMIsNonInterleaved:@NO };
        NSError *recErr=nil; self.avFallbackRecorder=[[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:wavPath] settings:settings error:&recErr]; self.avRecorderPath=wavPath;
        if (self.avFallbackRecorder && [self.avFallbackRecorder prepareToRecord] && [self.avFallbackRecorder record]) {
            [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Fallback D HQ started: %@",wavPath]];
            __weak typeof(self) weakSelf=self;
            self->_monitorTimer=[NSTimer scheduledTimerWithTimeInterval:0.35 repeats:YES block:^(NSTimer *t){
                __strong typeof(weakSelf) strongSelf=weakSelf; if (!strongSelf) return;
                NSString *p=strongSelf.avRecorderPath; if (!p) return;
                uint32_t payload=CRPGetWavPayload(p); if (payload>=4096) { [t invalidate]; strongSelf->_monitorTimer=nil; CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CRP_DARWIN_CAPTURING_NOTIFICATION,NULL,NULL,true); [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Fallback D HQ verified %u bytes",payload]]; }
            }];
            [[NSRunLoop mainRunLoop] addTimer:self->_monitorTimer forMode:NSRunLoopCommonModes];
        } else { [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Fallback D failed: %@",recErr.localizedDescription?:@"blocked"]]; self.avFallbackRecorder=nil; self.avRecorderPath=nil; }
    }
}
- (void)stopFallback {
    if (!_running) return; _running=NO;
    if (_monitorTimer) { [_monitorTimer invalidate]; _monitorTimer=nil; }
    if (_audioQueue) { AudioQueueStop(_audioQueue,true); AudioQueueDispose(_audioQueue,true); _audioQueue=NULL; }
    if (_remoteIOUnit) { AudioOutputUnitStop(_remoteIOUnit); AudioUnitUninitialize(_remoteIOUnit); AudioComponentInstanceDispose(_remoteIOUnit); _remoteIOUnit=NULL; }
    if (self.avFallbackRecorder) {
        NSString *path=self.avRecorderPath ?: self.avFallbackRecorder.url.path;
        [self.avFallbackRecorder stop]; self.avFallbackRecorder=nil; self.avRecorderPath=nil;
        if (path) {
            uint32_t payload=CRPGetWavPayload(path);
            if (payload==0 || payload<1024) { [[NSFileManager defaultManager] removeItemAtPath:path error:nil]; [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Removed HQ stub %u: %@",payload,path]]; }
            else { chmod(path.fileSystemRepresentation,0666); [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Saved HQ AVRec %u: %@",payload,path]]; NSString *jbPrimary=jbroot(@"/var/mobile/Library/CallRecordings"); if (jbPrimary.length>0 && ![path hasPrefix:jbPrimary]) { [[NSFileManager defaultManager] createDirectoryAtPath:jbPrimary withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@(0777)} error:nil]; chmod(jbPrimary.fileSystemRepresentation,0777); NSString *dst=[jbPrimary stringByAppendingPathComponent:[path lastPathComponent]]; if (![[NSFileManager defaultManager] fileExistsAtPath:dst]) { NSError *err=nil; [[NSFileManager defaultManager] copyItemAtPath:path toPath:dst error:&err]; if (!err) { chmod(dst.fileSystemRepresentation,0666); [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Synced HQ to jbroot: %@",dst]]; } } } }
        }
    }
    [[AudioRecorderEngine sharedInstance] stopRecording];
}
@end

// ============================================================================
// Floating HQ Recorder View - Dual-mic aesthetic with live waveform
// ============================================================================
@interface CRPFloatingRecorderView ()
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) UIView *dotView;
@property (nonatomic, strong) UILabel *timerLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) NSTimer *elapsedTimer;
@property (nonatomic, assign) NSInteger elapsedSeconds;
@property (nonatomic, assign, readwrite) BOOL isRecording;
@property (nonatomic, assign) BOOL verifiedCapturing;
@property (nonatomic, assign) NSUInteger sessionGeneration;
@property (nonatomic, strong) UIView *waveformView;
@property (nonatomic, strong) NSArray<UIView *> *waveBars;
@end

@implementation CRPFloatingRecorderView

- (instancetype)initWithFrame:(CGRect)frame {
    self=[super initWithFrame:frame];
    if (self) {
        self.backgroundColor=[UIColor clearColor]; self.clipsToBounds=NO;
        self.layer.shadowColor=[UIColor blackColor].CGColor; self.layer.shadowOpacity=0.38f; self.layer.shadowRadius=12.0; self.layer.shadowOffset=CGSizeMake(0,4);
        // Blur container
        UIVisualEffect *effect=[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
        _blurView=[[UIVisualEffectView alloc] initWithEffect:effect];
        _blurView.frame=self.bounds; _blurView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        _blurView.layer.cornerRadius=CGRectGetHeight(frame)/2.0; _blurView.clipsToBounds=YES;
        _blurView.layer.borderWidth=1.0; _blurView.layer.borderColor=[UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
        [self addSubview:_blurView];
        _containerView=[[UIView alloc] initWithFrame:self.bounds]; _containerView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; _containerView.backgroundColor=[UIColor clearColor];
        [_blurView.contentView addSubview:_containerView];

        _dotView=[[UIView alloc] initWithFrame:CGRectMake(12, (CGRectGetHeight(frame)-12)/2, 12, 12)];
        _dotView.layer.cornerRadius=6; _dotView.backgroundColor=[UIColor systemRedColor]; _dotView.layer.shadowColor=[UIColor systemRedColor].CGColor; _dotView.layer.shadowRadius=4; _dotView.layer.shadowOpacity=0.8; _dotView.layer.shadowOffset=CGSizeZero;
        [_containerView addSubview:_dotView];

        // Waveform bars (3 bars)
        NSMutableArray *bars=[NSMutableArray array];
        for (int i=0;i<3;i++) {
            UIView *bar=[[UIView alloc] initWithFrame:CGRectMake(30+i*5, (CGRectGetHeight(frame)-4)/2, 3, 4)];
            bar.backgroundColor=[UIColor systemRedColor]; bar.layer.cornerRadius=1.5; bar.alpha=0.0;
            [_containerView addSubview:bar]; [bars addObject:bar];
        }
        _waveBars=bars;

        _timerLabel=[[UILabel alloc] initWithFrame:CGRectMake(48, 4, 56, 18)];
        _timerLabel.text=@"00:00"; _timerLabel.textColor=[UIColor whiteColor]; _timerLabel.font=[UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightBold]; _timerLabel.textAlignment=NSTextAlignmentCenter;
        [_containerView addSubview:_timerLabel];

        _statusLabel=[[UILabel alloc] initWithFrame:CGRectMake(48, 22, 56, 10)];
        _statusLabel.text=@"READY"; _statusLabel.textColor=[UIColor colorWithWhite:0.85 alpha:1.0]; _statusLabel.font=[UIFont systemFontOfSize:7 weight:UIFontWeightSemibold]; _statusLabel.textAlignment=NSTextAlignmentCenter;
        [_containerView addSubview:_statusLabel];

        _toggleButton=[UIButton buttonWithType:UIButtonTypeCustom]; _toggleButton.frame=self.bounds; _toggleButton.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; _toggleButton.accessibilityLabel=@"Toggle HQ Recording";
        [_toggleButton addTarget:self action:@selector(handleTap) forControlEvents:UIControlEventTouchUpInside]; [_containerView addSubview:_toggleButton];

        UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]; [self addGestureRecognizer:pan];
        UILongPressGestureRecognizer *longPress=[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)]; longPress.minimumPressDuration=0.6; [self addGestureRecognizer:longPress];
        _isRecording=NO; _verifiedCapturing=NO; _elapsedSeconds=0; _sessionGeneration=0;
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    UIView *sv=self.superview; if (!sv) return;
    CGPoint t=[g translationInView:sv]; CGPoint c=CGPointMake(self.center.x+t.x,self.center.y+t.y);
    UIEdgeInsets in=sv.safeAreaInsets; CGFloat hw=CGRectGetWidth(self.bounds)/2, hh=CGRectGetHeight(self.bounds)/2;
    CGFloat minX=MAX(8,in.left+8)+hw, maxX=CGRectGetWidth(sv.bounds)-MAX(8,in.right+8)-hw;
    CGFloat minY=MAX(44,in.top+8)+hh, maxY=CGRectGetHeight(sv.bounds)-MAX(20,in.bottom+8)-hh;
    if (maxX>=minX) c.x=MAX(minX,MIN(maxX,c.x)); if (maxY>=minY) c.y=MAX(minY,MIN(maxY,c.y));
    self.center=c; [g setTranslation:CGPointZero inView:sv];
}
- (void)handleLongPress:(UILongPressGestureRecognizer *)g { if (g.state==UIGestureRecognizerStateBegan) { UIImpactFeedbackGenerator *f=[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy]; [f impactOccurred]; [self stopRecordingAll]; } }
- (void)handleTap { UIImpactFeedbackGenerator *f=[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; [f impactOccurred]; if (self.isRecording) [self stopRecordingAll]; else [self startRecordingAll]; }

- (void)startRecordingAll {
    self.sessionGeneration+=1; NSUInteger gen=self.sessionGeneration;
    self.isRecording=YES; self.verifiedCapturing=NO; self.elapsedSeconds=0; self.timerLabel.text=@"00:00"; self.statusLabel.text=@"REC ●";
    self.statusLabel.textColor=[UIColor systemRedColor];
    self.dotView.backgroundColor=[UIColor systemRedColor];
    // Pulse
    CABasicAnimation *pulse=[CABasicAnimation animationWithKeyPath:@"opacity"]; pulse.fromValue=@(1.0); pulse.toValue=@(0.2); pulse.duration=0.55; pulse.autoreverses=YES; pulse.repeatCount=HUGE_VALF; [self.dotView.layer addAnimation:pulse forKey:@"crp_pulse"];
    for (UIView *bar in self.waveBars) { bar.alpha=1.0; bar.backgroundColor=[UIColor systemRedColor]; CABasicAnimation *h=[CABasicAnimation animationWithKeyPath:@"bounds.size.height"]; h.fromValue=@(4); h.toValue=@(14); h.duration=0.35 + (arc4random_uniform(20)/100.0); h.autoreverses=YES; h.repeatCount=HUGE_VALF; [bar.layer addAnimation:h forKey:@"wave"]; }
    [self.elapsedTimer invalidate];
    NSTimer *t=[NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(tickTimer) userInfo:nil repeats:YES]; [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes]; self.elapsedTimer=t;
    NSDictionary *meta=CRPCurrentCallMetadata();
    [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"User START HQ -> post start meta=%@",meta]];
    // Start with metadata
    [[AudioRecorderEngine sharedInstance] startRecordingWithMetadata:meta];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CRP_DARWIN_START_NOTIFICATION,NULL,NULL,true);
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.9*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s=weakSelf; if (!s||!s.isRecording||s.sessionGeneration!=gen) return;
        if (!s.verifiedCapturing) { [AudioRecorderEngine appendDiagnosticLog:@"No ACK 0.9s -> fallback HQ"]; [[CRPInCallFallbackRecorder sharedInstance] startFallbackIfNeeded]; }
    });
}
- (void)stopRecordingAll {
    self.sessionGeneration+=1; self.isRecording=NO; self.verifiedCapturing=NO;
    [self.elapsedTimer invalidate]; self.elapsedTimer=nil;
    [self.dotView.layer removeAnimationForKey:@"crp_pulse"]; for (UIView *b in self.waveBars) { [b.layer removeAnimationForKey:@"wave"]; b.alpha=0.0; }
    self.dotView.backgroundColor=[UIColor systemRedColor]; self.elapsedSeconds=0; self.timerLabel.text=@"00:00"; self.statusLabel.text=@"READY"; self.statusLabel.textColor=[UIColor colorWithWhite:0.85 alpha:1.0];
    self.dotView.layer.shadowColor=[UIColor systemRedColor].CGColor;
    [[CRPInCallFallbackRecorder sharedInstance] stopFallback];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CRP_DARWIN_STOP_NOTIFICATION,NULL,NULL,true);
}
- (void)markCapturingVerified {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.isRecording) return;
        self.verifiedCapturing=YES; self.dotView.backgroundColor=[UIColor systemGreenColor]; self.dotView.layer.shadowColor=[UIColor systemGreenColor].CGColor;
        for (UIView *bar in self.waveBars) bar.backgroundColor=[UIColor systemGreenColor];
        self.statusLabel.text=@"● CAPTURING"; self.statusLabel.textColor=[UIColor systemGreenColor];
    });
}
- (void)stopRecordingIfNeeded { if (self.isRecording) [self stopRecordingAll]; }
- (void)tickTimer {
    self.elapsedSeconds+=1;
    if (self.elapsedSeconds>=3 && !self.verifiedCapturing) { self.dotView.backgroundColor=[UIColor systemYellowColor]; self.dotView.layer.shadowColor=[UIColor systemYellowColor].CGColor; self.statusLabel.text=@"CONNECTING…"; self.statusLabel.textColor=[UIColor systemYellowColor]; }
    self.timerLabel.text=[NSString stringWithFormat:@"%02ld:%02ld",(long)(self.elapsedSeconds/60),(long)(self.elapsedSeconds%60)];
}
@end

static void CRPAttachFloatingRecorderToContainer(UIView *container) {
    if (!container) return;
    NSString *clsName=NSStringFromClass([container class]);
    if ([clsName containsString:@"Keyboard"]||[clsName containsString:@"TextEffects"]) return;
    CGRect bounds=container.bounds; if (CGRectGetWidth(bounds)<220 || CGRectGetHeight(bounds)<140) return;
    if (!gFloatingRecorderView) {
        CGFloat w=112, h=44; CGFloat top=MAX(58, container.safeAreaInsets.top+12); CGFloat x=MAX(14, CGRectGetWidth(bounds)-w-14);
        gFloatingRecorderView=[[CRPFloatingRecorderView alloc] initWithFrame:CGRectMake(x,top,w,h)];
        gFloatingRecorderView.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleBottomMargin;
    }
    if (gFloatingRecorderView.superview!=container) [container addSubview:gFloatingRecorderView];
    [container bringSubviewToFront:gFloatingRecorderView];
}

static void CRPInCallCapturingDarwinCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) { [gFloatingRecorderView markCapturingVerified]; }

%group InCallServiceUI
%hook PHAudioCallViewController
- (void)viewDidAppear:(BOOL)animated { %orig; CRPAttachFloatingRecorderToContainer(self.view.window?:self.view); }
%end
%hook CNKFaceTimeInCallViewController
- (void)viewDidAppear:(BOOL)animated { %orig; CRPAttachFloatingRecorderToContainer(self.view.window?:self.view); }
%end
%hook UIWindow
- (void)makeKeyAndVisible { %orig; if (!self.isHidden && self.windowLevel <= UIWindowLevelStatusBar+100) CRPAttachFloatingRecorderToContainer(self); }
- (void)didAddSubview:(UIView *)subview { %orig; if (subview!=gFloatingRecorderView && !self.isHidden && self.windowLevel <= UIWindowLevelStatusBar+100) { if (gFloatingRecorderView.superview==self) [self bringSubviewToFront:gFloatingRecorderView]; else if (!gFloatingRecorderView || !gFloatingRecorderView.superview) CRPAttachFloatingRecorderToContainer(self); } }
%end
static void CRPHandleCallStatusChanged(NSNotification *note) {
    BOOL shouldStop=NO; id call=note.object; if (call && [call respondsToSelector:@selector(status)]) { int st=[(TUCall*)call status]; if (st==6) shouldStop=YES; }
    Class ccCls=objc_getClass("TUCallCenter"); if (ccCls && [ccCls respondsToSelector:@selector(sharedInstance)]) { TUCallCenter *c=[ccCls sharedInstance]; if ([c respondsToSelector:@selector(currentCalls)]) { NSArray *arr=c.currentCalls; if (arr && arr.count==0) shouldStop=YES; } }
    if (shouldStop) dispatch_async(dispatch_get_main_queue(), ^{ [gFloatingRecorderView stopRecordingIfNeeded]; });
}
%end

// ============================================================================
// AudioDaemonHooks - TRUE DUAL-CHANNEL CAPTURE (no single-stream gating)
// ============================================================================
%group AudioDaemonHooks
static pthread_mutex_t gStreamLock=PTHREAD_MUTEX_INITIALIZER;
static pthread_key_t gRenderDepthKey; static pthread_once_t gRenderKeyOnce=PTHREAD_ONCE_INIT;
static void CRPInitRenderDepthKey(void) { pthread_key_create(&gRenderDepthKey,NULL); }
static inline intptr_t CRPGetRenderDepth(void) { pthread_once(&gRenderKeyOnce,CRPInitRenderDepthKey); return (intptr_t)pthread_getspecific(gRenderDepthKey); }
static inline void CRPSetRenderDepth(intptr_t v) { pthread_once(&gRenderKeyOnce,CRPInitRenderDepthKey); pthread_setspecific(gRenderDepthKey,(const void*)v); }

// New: capture ALL non-silent streams simultaneously - this is the key fix for low volume
static void CRPCaptureRenderedAudio(AudioUnit inUnit, const AudioUnitRenderActionFlags *ioActionFlags, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    AudioRecorderEngine *engine=[AudioRecorderEngine sharedInstance];
    if (!engine.isRecording || !inUnit || !ioData || inNumberFrames==0) return;
    AudioStreamBasicDescription asbd; memset(&asbd,0,sizeof(asbd)); UInt32 propSize=sizeof(asbd);
    OSStatus st=AudioUnitGetProperty(inUnit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,inBusNumber,&asbd,&propSize);
    if (st!=noErr) { propSize=sizeof(asbd); st=AudioUnitGetProperty(inUnit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,inBusNumber,&asbd,&propSize); }
    if (st!=noErr || asbd.mFormatID!=kAudioFormatLinearPCM) return;
    // Capture everything - do not filter by active unit, capture both mic (uplink) and speaker (downlink) simultaneously
    // Only skip pure silence if flagged, but still capture brief silences for timing
    if (ioActionFlags && ((*ioActionFlags) & kAudioUnitRenderAction_OutputIsSilence)) {
        // Still capture occasional silence to preserve timing, but not every silent buffer to avoid bloating
        static int silentSkip=0; if ((silentSkip++ % 8)!=0) return;
    }
    // Directly append - dual channel mixing via sequential append gives true call audio (not mic leakage)
    [engine appendAudioBufferList:ioData frames:inNumberFrames format:asbd];
}

static OSStatus CRPAudioUnitRenderNotify(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    if (ioActionFlags && ((*ioActionFlags) & kAudioUnitRenderAction_PostRender)) { if (CRPGetRenderDepth()==0) { AudioUnit unit=(AudioUnit)inRefCon; CRPCaptureRenderedAudio(unit,ioActionFlags,inBusNumber,inNumberFrames,ioData); } }
    return noErr;
}
static OSStatus (*orig_AudioUnitInitialize)(AudioUnit)=NULL;
static OSStatus hooked_AudioUnitInitialize(AudioUnit inUnit) {
    if (!orig_AudioUnitInitialize) return -1; OSStatus s=orig_AudioUnitInitialize(inUnit); if (s==noErr && inUnit) AudioUnitAddRenderNotify(inUnit,CRPAudioUnitRenderNotify,(void*)inUnit); return s;
}
static OSStatus (*orig_AudioUnitRender)(AudioUnit,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32,UInt32,AudioBufferList*)=NULL;
static OSStatus hooked_AudioUnitRender(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    if (!orig_AudioUnitRender) return -1; intptr_t d=CRPGetRenderDepth(); CRPSetRenderDepth(d+1); OSStatus s=orig_AudioUnitRender(inUnit,ioActionFlags,inTimeStamp,inBusNumber,inNumberFrames,ioData); CRPSetRenderDepth(d); if (s==noErr) CRPCaptureRenderedAudio(inUnit,ioActionFlags,inBusNumber,inNumberFrames,ioData); return s;
}
extern OSStatus AudioUnitProcess(AudioUnit,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32,AudioBufferList*);
static OSStatus (*orig_AudioUnitProcess)(AudioUnit,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32,AudioBufferList*)=NULL;
static OSStatus hooked_AudioUnitProcess(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inNumberFrames, AudioBufferList *ioData) {
    if (!orig_AudioUnitProcess) return -1; intptr_t d=CRPGetRenderDepth(); CRPSetRenderDepth(d+1); OSStatus s=orig_AudioUnitProcess(inUnit,ioActionFlags,inTimeStamp,inNumberFrames,ioData); CRPSetRenderDepth(d); if (s==noErr) CRPCaptureRenderedAudio(inUnit,ioActionFlags,0,inNumberFrames,ioData); return s;
}
extern OSStatus AudioConverterFillComplexBuffer(AudioConverterRef, AudioConverterComplexInputDataProc, void*, UInt32*, AudioBufferList*, AudioStreamPacketDescription*);
static OSStatus (*orig_AudioConverterFillComplexBuffer)(AudioConverterRef,AudioConverterComplexInputDataProc,void*,UInt32*,AudioBufferList*,AudioStreamPacketDescription*)=NULL;
static OSStatus hooked_AudioConverterFillComplexBuffer(AudioConverterRef inAudioConverter, AudioConverterComplexInputDataProc inInputDataProc, void *inInputDataProcUserData, UInt32 *ioOutputDataPacketSize, AudioBufferList *outOutputData, AudioStreamPacketDescription *outPacketDescription) {
    if (!orig_AudioConverterFillComplexBuffer) return -1;
    OSStatus s=orig_AudioConverterFillComplexBuffer(inAudioConverter,inInputDataProc,inInputDataProcUserData,ioOutputDataPacketSize,outOutputData,outPacketDescription);
    if (s==noErr && [AudioRecorderEngine sharedInstance].isRecording && outOutputData && ioOutputDataPacketSize && *ioOutputDataPacketSize>0) {
        AudioStreamBasicDescription asbd; memset(&asbd,0,sizeof(asbd)); UInt32 sz=sizeof(asbd);
        OSStatus p=AudioConverterGetProperty(inAudioConverter,kAudioConverterCurrentOutputStreamDescription,&sz,&asbd);
        if (p==noErr && asbd.mFormatID==kAudioFormatLinearPCM && outOutputData->mNumberBuffers>0) {
            UInt32 frames=*ioOutputDataPacketSize; if (asbd.mFramesPerPacket>0) frames=(*ioOutputDataPacketSize)*asbd.mFramesPerPacket;
            // For converter, also capture all - check for any non-zero to avoid pure silence
            BOOL hasSignal=NO; for (UInt32 b=0;b<outOutputData->mNumberBuffers;b++) if (outOutputData->mBuffers[b].mData && outOutputData->mBuffers[b].mDataByteSize>=4) { const uint32_t *w=(const uint32_t*)outOutputData->mBuffers[b].mData; for (UInt32 i=0;i<MIN((UInt32)(outOutputData->mBuffers[b].mDataByteSize/4),16u);i++) if (w[i]!=0) { hasSignal=YES; break; } }
            if (hasSignal) [[AudioRecorderEngine sharedInstance] appendAudioBufferList:outOutputData frames:frames format:asbd];
        }
    }
    return s;
}
static void CRPStartNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    pthread_mutex_lock(&gStreamLock); pthread_mutex_unlock(&gStreamLock);
    NSDictionary *meta=CRPCurrentCallMetadata();
    if (meta) [[AudioRecorderEngine sharedInstance] startRecordingWithMetadata:meta]; else [[AudioRecorderEngine sharedInstance] startRecording];
}
static void CRPStopNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) { [[AudioRecorderEngine sharedInstance] stopRecording]; }
static void CRPPingNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NSString *dir=[AudioRecorderEngine resolveWritableRecordingsDirectory]?:@"NONE"; [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"PONG HQ (AUDIO QUALITY PRO) dir=%@",dir]];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CRP_DARWIN_PONG_NOTIFICATION,NULL,NULL,true);
}
%end

%ctor {
    @autoreleasepool {
        NSString *pn=[NSProcessInfo processInfo].processName?:@"";
        CFNotificationCenterRef dc=CFNotificationCenterGetDarwinNotifyCenter();
        if ([pn isEqualToString:@"InCallService"]) {
            %init(InCallServiceUI);
            CFNotificationCenterAddObserver(dc,NULL,CRPInCallCapturingDarwinCallback,CRP_DARWIN_CAPTURING_NOTIFICATION,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
            NSNotificationCenter *nc=[NSNotificationCenter defaultCenter];
            [nc addObserverForName:@"TUCallCenterCallStatusChangedNotification" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){ CRPHandleCallStatusChanged(n); }];
            [nc addObserverForName:@"TUCallStatusChangedNotification" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){ CRPHandleCallStatusChanged(n); }];
            [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Loaded InCallServiceUI HQ PRO (dir=%@)",[AudioRecorderEngine resolveWritableRecordingsDirectory]?:@"NONE"]];
        } else if ([pn isEqualToString:@"mediaserverd"]||[pn isEqualToString:@"audiomxd"]||[pn isEqualToString:@"callservicesd"]||[pn isEqualToString:@"avconferenced"]) {
            %init(AudioDaemonHooks);
            CFNotificationCenterAddObserver(dc,NULL,CRPStartNotificationCallback,CRP_DARWIN_START_NOTIFICATION,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(dc,NULL,CRPStopNotificationCallback,CRP_DARWIN_STOP_NOTIFICATION,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(dc,NULL,CRPPingNotificationCallback,CRP_DARWIN_PING_NOTIFICATION,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
            MSHookFunction((void*)AudioUnitInitialize,(void*)hooked_AudioUnitInitialize,(void**)&orig_AudioUnitInitialize);
            MSHookFunction((void*)AudioUnitRender,(void*)hooked_AudioUnitRender,(void**)&orig_AudioUnitRender);
            void *procSym=MSFindSymbol(NULL,"_AudioUnitProcess"); if (procSym) MSHookFunction(procSym,(void*)hooked_AudioUnitProcess,(void**)&orig_AudioUnitProcess);
            void *convSym=MSFindSymbol(NULL,"_AudioConverterFillComplexBuffer"); if (convSym) MSHookFunction(convSym,(void*)hooked_AudioConverterFillComplexBuffer,(void**)&orig_AudioConverterFillComplexBuffer);
            [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Loaded HQ AudioDaemon PRO DAUL-CHANNEL (dir=%@, proc=%@, conv=%@)",[AudioRecorderEngine resolveWritableRecordingsDirectory]?:@"NONE",procSym?@"yes":@"n/a",convSym?@"yes":@"n/a"]];
        }
    }
}
