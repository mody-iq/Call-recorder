#import "AudioRecorderEngine.h"
#include <roothide.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct __attribute__((packed)) {
    char     riffId[4];
    uint32_t riffSize;
    char     waveId[4];
    char     fmtId[4];
    uint32_t fmtSize;
    uint16_t audioFormat;
    uint16_t numChannels;
    uint32_t sampleRate;
    uint32_t byteRate;
    uint16_t blockAlign;
    uint16_t bitsPerSample;
    char     dataId[4];
    uint32_t dataSize;
} CRPWavHeader;

_Static_assert(sizeof(CRPWavHeader) == 44, "WAV header must be 44 bytes");

static inline int16_t CRPFloatToInt16(float sample) {
    if (sample >= 1.0f) return INT16_MAX;
    if (sample <= -1.0f) return INT16_MIN;
    int32_t scaled = (int32_t)(sample * 32767.0f);
    if (scaled > INT16_MAX) return INT16_MAX;
    if (scaled < INT16_MIN) return INT16_MIN;
    return (int16_t)scaled;
}

static BOOL CRPProbeDirectoryWritable(NSString *dirPath) {
    if (dirPath.length == 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dirPath]) {
        NSDictionary *attrs = @{
            NSFilePosixPermissions: @(0777),
            NSFileProtectionKey: NSFileProtectionNone
        };
        [fm createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:attrs error:nil];
    }
    chmod(dirPath.fileSystemRepresentation, 0777);
    NSString *probeFile = [dirPath stringByAppendingPathComponent:[NSString stringWithFormat:@".crp_probe_%d", (int)getpid()]];
    const char *cPath = probeFile.fileSystemRepresentation;
    if (!cPath) return NO;
    int fd = open(cPath, O_CREAT | O_WRONLY | O_TRUNC, 0666);
    if (fd < 0) return NO;
    const char tag[4] = {'C','R','P','1'};
    ssize_t wrote = write(fd, tag, sizeof(tag));
    close(fd);
    unlink(cPath);
    return (wrote == (ssize_t)sizeof(tag));
}

static uint32_t CRPGetWavDataPayloadSizeAtPath(NSString *path) {
    if (path.length == 0) return 0;
    const char *cPath = path.fileSystemRepresentation;
    if (!cPath) return 0;
    struct stat st;
    if (stat(cPath, &st) != 0) return 0;
    if (st.st_size < 44) return 0;
    int fd = open(cPath, O_RDONLY);
    if (fd < 0) return 0;
    uint8_t header[12];
    ssize_t r = read(fd, header, sizeof(header));
    if (r != (ssize_t)sizeof(header)) { close(fd); return 0; }
    if (memcmp(header, "RIFF", 4) != 0 || memcmp(header + 8, "WAVE", 4) != 0) {
        close(fd);
        return (st.st_size > 44) ? (uint32_t)(st.st_size - 44) : 0;
    }
    off_t offset = 12;
    while (offset + 8 <= st.st_size) {
        uint8_t chunkHdr[8];
        if (lseek(fd, offset, SEEK_SET) == (off_t)-1) break;
        if (read(fd, chunkHdr, 8) != 8) break;
        char chunkId[5] = {0};
        memcpy(chunkId, chunkHdr, 4);
        uint32_t chunkSize = 0;
        memcpy(&chunkSize, chunkHdr + 4, 4);
        if (memcmp(chunkId, "data", 4) == 0) {
            close(fd);
            return chunkSize;
        }
        if (chunkSize > (uint32_t)(st.st_size)) break;
        offset += 8 + (off_t)chunkSize;
        if (chunkSize & 1) offset += 1;
        if (offset > st.st_size) break;
        if (offset > 1024 * 1024) break;
    }
    close(fd);
    return 0;
}

static BOOL CRPIsValidRecordingAtPath(NSString *path) {
    if (path.length == 0) return NO;
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) return NO;
    if (st.st_size <= 44) return NO;
    uint32_t payload = CRPGetWavDataPayloadSizeAtPath(path);
    if (payload == 0) {
        if (st.st_size > (44 + 4096)) return YES;
        return NO;
    }
    return payload >= 1024;
}

// =============== Smooth AGC - v1.3.4 fix: native rate, no forced 16k ===============
static double gSmoothedGain = 1.0;
static double gLastRMS = 2000.0;

static void CRPApplySmoothGainToPCM16(NSMutableData *pcmData) {
    if (!pcmData || pcmData.length < 4) return;
    int16_t *samples = (int16_t *)pcmData.mutableBytes;
    NSUInteger sampleCount = pcmData.length / sizeof(int16_t);
    if (sampleCount == 0) return;
    int64_t sum = 0;
    int64_t sumSq = 0;
    int32_t peak = 0;
    for (NSUInteger i = 0; i < sampleCount; i++) {
        int16_t s = samples[i];
        sum += s;
        int32_t absS = abs((int)s);
        if (absS > peak) peak = absS;
        sumSq += (int64_t)s * (int64_t)s;
    }
    double mean = (double)sum / (double)sampleCount;
    double rms = sqrt((double)sumSq / (double)sampleCount);
    if (rms < 5.0) return;
    gLastRMS = gLastRMS * 0.85 + rms * 0.15;
    double smoothRMS = gLastRMS;
    double targetRMS = 3200.0;
    double desiredGain = 1.0;
    if (smoothRMS < targetRMS * 0.9) {
        desiredGain = targetRMS / (smoothRMS + 60.0);
        if (desiredGain > 2.2) desiredGain = 2.2;
        if (desiredGain < 1.0) desiredGain = 1.0;
        if (peak > 0) {
            double headroom = 31000.0 / (double)peak;
            if (desiredGain > headroom) desiredGain = headroom;
        }
    } else if (smoothRMS > targetRMS * 1.6) {
        desiredGain = 0.95;
    } else {
        desiredGain = 1.0;
    }
    gSmoothedGain = gSmoothedGain * 0.88 + desiredGain * 0.12;
    double gain = gSmoothedGain;
    if (fabs(gain - 1.0) < 0.06) return;
    for (NSUInteger i = 0; i < sampleCount; i++) {
        double centered = (double)samples[i] - mean;
        double out = centered * gain;
        if (out > 32767.0) out = 32767.0;
        if (out < -32768.0) out = -32768.0;
        samples[i] = (int16_t)out;
    }
}

static void CRPResetAGCState(void) {
    gSmoothedGain = 1.0;
    gLastRMS = 2000.0;
}

@interface AudioRecorderEngine () {
    dispatch_queue_t _ioQueue;
    NSFileHandle *_fileHandle;
    atomic_bool _recordingFlag;
    atomic_uint_fast32_t _atomicBytesWritten;
    BOOL _headerInitialized;
    BOOL _notifiedCapturing;
    uint32_t _dataBytesWritten;
    uint32_t _bytesSinceLastHeaderFlush;
    uint16_t _wavChannels;
    uint32_t _wavSampleRate;
    NSString *_currentFilePath;
    NSString *_sessionTimestamp;
    NSDictionary *_pendingMetadata;
}
@end

@implementation AudioRecorderEngine

+ (instancetype)sharedInstance {
    static AudioRecorderEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AudioRecorderEngine alloc] init];
    });
    return instance;
}

+ (NSArray<NSString *> *)candidateStorageDirectories {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSString *jbPrimary = jbroot(@"/var/mobile/Library/CallRecordings");
    if (jbPrimary.length > 0) [dirs addObject:jbPrimary];
    NSArray<NSString *> *ordered = @[
        @"/private/var/mobile/Library/CallRecordings",
        @"/private/var/mobile/Media/CallRecordings",
        @"/private/var/mobile/Media/Recordings/CallRecordings",
        @"/private/var/mobile/Media/DCIM/CallRecordings",
        @"/private/var/tmp/CallRecordings"
    ];
    for (NSString *p in ordered) if (p.length>0 && ![dirs containsObject:p]) [dirs addObject:p];
    return dirs;
}

+ (NSString *)resolveWritableRecordingsDirectory {
    for (NSString *candidate in [self candidateStorageDirectories]) if (CRPProbeDirectoryWritable(candidate)) return candidate;
    return nil;
}

+ (void)consolidateRecordingsToPrimaryDirectory {
    NSArray<NSString *> *dirs = [self candidateStorageDirectories];
    if (dirs.count==0) return;
    NSString *primary = dirs.firstObject;
    if (primary.length==0) return;
    if (!CRPProbeDirectoryWritable(primary)) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSUInteger idx=1; idx<dirs.count; idx++) {
        NSString *fallback = dirs[idx];
        BOOL isDir=NO; if (![fm fileExistsAtPath:fallback isDirectory:&isDir] || !isDir) continue;
        NSArray<NSString *> *files=[fm contentsOfDirectoryAtPath:fallback error:nil];
        for (NSString *file in files) {
            NSString *ext=file.pathExtension.lowercaseString;
            if (![ext isEqualToString:@"wav"] && ![ext isEqualToString:@"m4a"] && ![ext isEqualToString:@"caf"] && ![ext isEqualToString:@"json"]) continue;
            NSString *src=[fallback stringByAppendingPathComponent:file];
            NSDictionary *attrs=[fm attributesOfItemAtPath:src error:nil];
            unsigned long long sz=[attrs[NSFileSize] unsignedLongLongValue];
            if (sz <= 44ULL && [ext isEqualToString:@"wav"]) continue;
            if ([ext isEqualToString:@"wav"]) {
                uint32_t payload=CRPGetWavDataPayloadSizeAtPath(src);
                if (payload==0) { if (sz <= (44ULL+4096ULL)) { [fm removeItemAtPath:src error:nil]; continue; } }
            }
            NSString *dst=[primary stringByAppendingPathComponent:file];
            if ([fm fileExistsAtPath:dst]) continue;
            NSError *err=nil; [fm copyItemAtPath:src toPath:dst error:&err];
            if (!err) { chmod(dst.fileSystemRepresentation, 0666); [self appendDiagnosticLog:[NSString stringWithFormat:@"Consolidated %@ -> %@", src, dst]]; }
        }
    }
}

+ (void)appendDiagnosticLog:(NSString *)message {
    if (message.length==0) return;
    static dispatch_queue_t logQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ logQueue=dispatch_queue_create("com.callrecorder.diagqueue", DISPATCH_QUEUE_SERIAL); });
    NSString *procName=[NSProcessInfo processInfo].processName ?: @"unknown";
    int pid=(int)getpid();
    dispatch_async(logQueue, ^{
        NSString *dir=[AudioRecorderEngine resolveWritableRecordingsDirectory];
        if (!dir) return;
        NSDateFormatter *df=[[NSDateFormatter alloc] init];
        df.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        df.dateFormat=@"HH:mm:ss.SSS";
        NSString *ts=[df stringFromDate:[NSDate date]];
        NSString *line=[NSString stringWithFormat:@"[%@] [%@:%d] %@\n", ts, procName, pid, message];
        NSData *lineData=[line dataUsingEncoding:NSUTF8StringEncoding]; if (!lineData) return;
        NSString *logPath=[dir stringByAppendingPathComponent:@"diagnostics.log"];
        const char *cLogPath=logPath.fileSystemRepresentation; if (!cLogPath) return;
        struct stat st; int openFlags=O_CREAT|O_WRONLY|O_APPEND;
        if (stat(cLogPath,&st)==0 && st.st_size>65536) openFlags=O_CREAT|O_WRONLY|O_TRUNC;
        int fd=open(cLogPath, openFlags, 0666);
        if (fd>=0) { (void)write(fd, lineData.bytes, lineData.length); close(fd); chmod(cLogPath,0666); }
    });
}

+ (uint32_t)wavDataPayloadSizeAtPath:(NSString *)path { return CRPGetWavDataPayloadSizeAtPath(path); }
+ (BOOL)isValidRecordingAtPath:(NSString *)path { return CRPIsValidRecordingAtPath(path); }

- (instancetype)init {
    self=[super init];
    if (self) {
        dispatch_queue_attr_t qosAttr=dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _ioQueue=dispatch_queue_create("com.callrecorder.ioqueue", qosAttr);
        atomic_init(&_recordingFlag, false);
        atomic_init(&_atomicBytesWritten, 0);
        _headerInitialized=NO; _notifiedCapturing=NO; _dataBytesWritten=0; _bytesSinceLastHeaderFlush=0; _wavChannels=1; _wavSampleRate=16000;
    }
    return self;
}

- (BOOL)isRecording { return atomic_load_explicit(&_recordingFlag, memory_order_relaxed) ? YES : NO; }
- (uint32_t)currentBytesWritten { return (uint32_t)atomic_load_explicit(&_atomicBytesWritten, memory_order_relaxed); }
- (NSString *)currentFilePath {
    __block NSString *path=nil;
    dispatch_sync(_ioQueue, ^{ path=[self->_currentFilePath copy]; });
    return path;
}

- (CRPWavHeader)buildWavHeaderWithSampleRate:(uint32_t)sampleRate channels:(uint16_t)channels dataSize:(uint32_t)dataSize {
    CRPWavHeader header;
    memcpy(header.riffId,"RIFF",4); header.riffSize=36u+dataSize; memcpy(header.waveId,"WAVE",4);
    memcpy(header.fmtId,"fmt ",4); header.fmtSize=16u; header.audioFormat=1u;
    uint16_t safeChannels=(channels>0 && channels<=2)?channels:1;
    uint32_t safeRate=(sampleRate>=8000 && sampleRate<=192000)?sampleRate:16000;
    uint16_t bitsPerSample=16u;
    header.numChannels=safeChannels; header.sampleRate=safeRate; header.bitsPerSample=bitsPerSample;
    header.blockAlign=(uint16_t)(safeChannels*(bitsPerSample/8u)); header.byteRate=safeRate*(uint32_t)header.blockAlign;
    memcpy(header.dataId,"data",4); header.dataSize=dataSize;
    return header;
}

- (void)writeHeaderToStartOfFileWithDataSize:(uint32_t)dataSize {
    if (!_fileHandle) return;
    CRPWavHeader header=[self buildWavHeaderWithSampleRate:_wavSampleRate channels:_wavChannels dataSize:dataSize];
    @try { [_fileHandle seekToFileOffset:0]; [_fileHandle writeData:[NSData dataWithBytes:&header length:sizeof(CRPWavHeader)]]; [_fileHandle seekToEndOfFile]; } @catch (NSException *e) {}
}

- (BOOL)openWavFileIfNeededWithSampleRate:(uint32_t)sampleRate channels:(uint16_t)channels {
    if (_fileHandle) return YES;
    NSString *dir=[AudioRecorderEngine resolveWritableRecordingsDirectory];
    if (!dir) { [AudioRecorderEngine appendDiagnosticLog:@"ERROR: No writable directory"]; return NO; }
    NSString *procName=[NSProcessInfo processInfo].processName ?: @"audio";
    NSString *ts=_sessionTimestamp;
    if (ts.length==0) {
        NSDateFormatter *f=[[NSDateFormatter alloc] init]; f.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; f.dateFormat=@"yyyy-MM-dd_HH-mm-ss";
        ts=[f stringFromDate:[NSDate date]]; _sessionTimestamp=[ts copy];
    }
    NSString *contactTag=@"";
    if (_pendingMetadata[@"handle"]) {
        NSString *h=_pendingMetadata[@"handle"];
        h=[h stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
        h=[h stringByReplacingOccurrencesOfString:@":" withString:@""];
        if (h.length>0 && h.length<32) contactTag=[NSString stringWithFormat:@"_%@", h];
    }
    NSString *fileName=[NSString stringWithFormat:@"Call_%@%@_%@.wav", ts, contactTag, procName];
    NSString *filePath=[dir stringByAppendingPathComponent:fileName];
    const char *cPath=filePath.fileSystemRepresentation; if (!cPath) return NO;
    int fd=open(cPath, O_CREAT|O_RDWR|O_TRUNC, 0666);
    if (fd<0) { [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"ERROR: open(%@) errno=%d", filePath, errno]]; return NO; }
    chmod(cPath, 0666);
    NSFileHandle *handle=[[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    if (!handle) { close(fd); return NO; }
    _fileHandle=handle; _currentFilePath=[filePath copy];
    // v1.3.4: use native rate/channels - no forced 16k resampling (fixes fast audio)
    _wavChannels=(channels>0 && channels<=2)?channels:1;
    _wavSampleRate=(sampleRate>=8000 && sampleRate<=192000)?sampleRate:16000;
    _headerInitialized=YES;
    CRPWavHeader initial=[self buildWavHeaderWithSampleRate:_wavSampleRate channels:_wavChannels dataSize:0];
    @try { [_fileHandle writeData:[NSData dataWithBytes:&initial length:sizeof(CRPWavHeader)]]; } @catch (NSException *e) { [_fileHandle closeFile]; _fileHandle=nil; _currentFilePath=nil; return NO; }
    [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Created WAV native %uHz %uch: %@ (smooth AGC)", _wavSampleRate, _wavChannels, filePath]];
    if (_pendingMetadata) {
        NSString *jsonPath=[[filePath stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"];
        NSData *jsonData=[NSJSONSerialization dataWithJSONObject:_pendingMetadata options:NSJSONWritingPrettyPrinted error:nil];
        if (jsonData) { [jsonData writeToFile:jsonPath atomically:YES]; chmod(jsonPath.fileSystemRepresentation, 0666); }
    }
    return YES;
}

- (void)startRecording { [self startRecordingWithMetadata:nil]; }

- (void)startRecordingWithMetadata:(nullable NSDictionary *)metadata {
    dispatch_async(_ioQueue, ^{
        if (atomic_load_explicit(&self->_recordingFlag, memory_order_relaxed)) return;
        NSDateFormatter *f=[[NSDateFormatter alloc] init]; f.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; f.dateFormat=@"yyyy-MM-dd_HH-mm-ss";
        self->_sessionTimestamp=[[f stringFromDate:[NSDate date]] copy];
        self->_pendingMetadata=metadata?[metadata copy]:nil;
        self->_fileHandle=nil; self->_currentFilePath=nil; self->_dataBytesWritten=0; self->_bytesSinceLastHeaderFlush=0; self->_headerInitialized=NO; self->_notifiedCapturing=NO; self->_wavChannels=1; self->_wavSampleRate=16000;
        atomic_store_explicit(&self->_atomicBytesWritten, 0, memory_order_relaxed);
        atomic_store_explicit(&self->_recordingFlag, true, memory_order_release);
        CRPResetAGCState();
        NSString *metaDesc=metadata ? [NSString stringWithFormat:@" meta=%@", metadata] : @"";
        [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Recording armed native-rate smooth-AGC%@", metaDesc]];
    });
}

- (void)stopRecording {
    dispatch_async(_ioQueue, ^{
        if (!atomic_load_explicit(&self->_recordingFlag, memory_order_relaxed)) return;
        atomic_store_explicit(&self->_recordingFlag, false, memory_order_release);
        if (self->_fileHandle) {
            [self writeHeaderToStartOfFileWithDataSize:self->_dataBytesWritten];
            @try { [self->_fileHandle synchronizeFile]; [self->_fileHandle closeFile]; } @catch (NSException *e) {}
            self->_fileHandle=nil;
            if (self->_currentFilePath) {
                chmod(self->_currentFilePath.fileSystemRepresentation, 0666);
                if (self->_dataBytesWritten==0) {
                    [[NSFileManager defaultManager] removeItemAtPath:self->_currentFilePath error:nil];
                    NSString *jsonPath=[[self->_currentFilePath stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"];
                    [[NSFileManager defaultManager] removeItemAtPath:jsonPath error:nil];
                    [AudioRecorderEngine appendDiagnosticLog:@"Removed 0-byte stub"];
                } else {
                    [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Saved WAV native: %@ (%u bytes)", self->_currentFilePath, self->_dataBytesWritten]];
                    NSString *jbPrimary=jbroot(@"/var/mobile/Library/CallRecordings");
                    if (jbPrimary.length>0 && ![self->_currentFilePath hasPrefix:jbPrimary]) {
                        NSString *dst=[jbPrimary stringByAppendingPathComponent:[self->_currentFilePath lastPathComponent]];
                        if (![[NSFileManager defaultManager] fileExistsAtPath:dst]) {
                            if (CRPProbeDirectoryWritable(jbPrimary)) {
                                NSError *err=nil; [[NSFileManager defaultManager] copyItemAtPath:self->_currentFilePath toPath:dst error:&err];
                                if (!err) {
                                    chmod(dst.fileSystemRepresentation, 0666);
                                    NSString *srcJson=[[self->_currentFilePath stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"];
                                    if ([[NSFileManager defaultManager] fileExistsAtPath:srcJson]) {
                                        NSString *dstJson=[[dst stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"];
                                        [[NSFileManager defaultManager] copyItemAtPath:srcJson toPath:dstJson error:nil];
                                        chmod(dstJson.fileSystemRepresentation, 0666);
                                    }
                                    [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"Synced to jbroot: %@", dst]];
                                }
                            }
                        }
                    }
                }
            }
        } else {
            [AudioRecorderEngine appendDiagnosticLog:@"Stopped (0 buffers in this process - waiting for daemon)"];
        }
        self->_headerInitialized=NO; self->_notifiedCapturing=NO; self->_dataBytesWritten=0; self->_bytesSinceLastHeaderFlush=0; self->_currentFilePath=nil; self->_sessionTimestamp=nil; self->_pendingMetadata=nil;
        atomic_store_explicit(&self->_atomicBytesWritten, 0, memory_order_relaxed);
        CRPResetAGCState();
        [AudioRecorderEngine consolidateRecordingsToPrimaryDirectory];
    });
}

// Convert any format to PCM16 but KEEP native rate/channels (no resampling) – fixes fast audio
- (NSData *)convertBuffers:(NSArray<NSData *> *)buffers frames:(UInt32)frames format:(AudioStreamBasicDescription)asbd outChannels:(uint16_t *)outChannels outSampleRate:(uint32_t *)outSampleRate {
    if (buffers.count==0 || frames==0) return nil;
    BOOL isFloat=(asbd.mFormatFlags & kAudioFormatFlagIsFloat)!=0;
    BOOL isNonInterleaved=((asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved)!=0) || (buffers.count>1);
    uint32_t bits=asbd.mBitsPerChannel>0?asbd.mBitsPerChannel:(isFloat?32u:16u);
    uint32_t rawChannels=asbd.mChannelsPerFrame>0?asbd.mChannelsPerFrame:(uint32_t)buffers.count;
    uint32_t inRate=(asbd.mSampleRate>=8000.0 && asbd.mSampleRate<=192000.0)?(uint32_t)(asbd.mSampleRate+0.5):16000u;
    uint16_t targetChannels=(rawChannels>=2)?2:1;
    if (targetChannels>2) targetChannels=2;
    if (targetChannels==0) targetChannels=1;
    if (outChannels) *outChannels=targetChannels;
    if (outSampleRate) *outSampleRate=inRate;
    // Fast path: already int16 interleaved mono/stereo at native rate
    if (!isFloat && bits==16 && !isNonInterleaved && rawChannels==targetChannels) {
        NSData *first=buffers[0];
        NSUInteger expectedBytes=(NSUInteger)frames*(NSUInteger)targetChannels*sizeof(int16_t);
        if (first.length>=expectedBytes) return (first.length==expectedBytes)?first:[first subdataWithRange:NSMakeRange(0,expectedBytes)];
        return first;
    }
    NSUInteger outByteCount=(NSUInteger)frames*(NSUInteger)targetChannels*sizeof(int16_t);
    NSMutableData *pcm16=[NSMutableData dataWithLength:outByteCount];
    int16_t *dst=(int16_t *)pcm16.mutableBytes;
    for (uint16_t ch=0; ch<targetChannels; ch++) {
        NSData *planeData=nil; uint32_t stride=1, offset=0;
        if (isNonInterleaved) { planeData=(ch<buffers.count)?buffers[ch]:buffers[0]; stride=1; offset=0; }
        else { planeData=buffers[0]; stride=(rawChannels>0)?rawChannels:1; offset=(ch<rawChannels)?ch:0; }
        const uint8_t *bytes=(const uint8_t *)planeData.bytes; NSUInteger byteLen=planeData.length;
        if (isFloat && bits==32) {
            const float *src=(const float *)bytes; NSUInteger maxSamples=byteLen/sizeof(float);
            for (UInt32 f=0; f<frames; f++) { NSUInteger idx=(NSUInteger)f*stride+offset; float val=(idx<maxSamples)?src[idx]:0.0f; dst[(NSUInteger)f*targetChannels+ch]=CRPFloatToInt16(val); }
        } else if (isFloat && bits==64) {
            const double *src=(const double *)bytes; NSUInteger maxSamples=byteLen/sizeof(double);
            for (UInt32 f=0; f<frames; f++) { NSUInteger idx=(NSUInteger)f*stride+offset; float val=(idx<maxSamples)?(float)src[idx]:0.0f; dst[(NSUInteger)f*targetChannels+ch]=CRPFloatToInt16(val); }
        } else if (!isFloat && bits==16) {
            const int16_t *src=(const int16_t *)bytes; NSUInteger maxSamples=byteLen/sizeof(int16_t);
            for (UInt32 f=0; f<frames; f++) { NSUInteger idx=(NSUInteger)f*stride+offset; dst[(NSUInteger)f*targetChannels+ch]=(idx<maxSamples)?src[idx]:0; }
        } else if (!isFloat && bits==32) {
            const int32_t *src=(const int32_t *)bytes; NSUInteger maxSamples=byteLen/sizeof(int32_t);
            uint32_t fracBits=(asbd.mFormatFlags>>7)&0x3Fu;
            for (UInt32 f=0; f<frames; f++) { NSUInteger idx=(NSUInteger)f*stride+offset; int32_t raw=(idx<maxSamples)?src[idx]:0; int32_t shifted=(fracBits==24u)?(raw>>9):(raw>>16); if (shifted>INT16_MAX) shifted=INT16_MAX; if (shifted<INT16_MIN) shifted=INT16_MIN; dst[(NSUInteger)f*targetChannels+ch]=(int16_t)shifted; }
        } else if (!isFloat && bits==24) {
            NSUInteger maxSamples=byteLen/3u;
            for (UInt32 f=0; f<frames; f++) { NSUInteger idx=(NSUInteger)f*stride+offset; if (idx<maxSamples) { const uint8_t *p=bytes+idx*3u; int16_t s16=(int16_t)((uint16_t)p[1]|((uint16_t)p[2]<<8)); dst[(NSUInteger)f*targetChannels+ch]=s16; } else dst[(NSUInteger)f*targetChannels+ch]=0; }
        } else return nil;
    }
    return pcm16;
}

- (void)appendAudioBufferList:(AudioBufferList *)ioData frames:(UInt32)inNumberFrames format:(AudioStreamBasicDescription)asbd {
    if (!atomic_load_explicit(&_recordingFlag, memory_order_relaxed)) return;
    if (ioData==NULL || ioData->mNumberBuffers==0 || inNumberFrames==0) return;
    UInt32 numBuffers=MIN(ioData->mNumberBuffers,2u);
    NSMutableArray<NSData *> *copiedBuffers=[NSMutableArray arrayWithCapacity:numBuffers];
    for (UInt32 i=0;i<numBuffers;i++) { AudioBuffer buf=ioData->mBuffers[i]; if (buf.mData && buf.mDataByteSize>0) [copiedBuffers addObject:[NSData dataWithBytes:buf.mData length:buf.mDataByteSize]]; }
    if (copiedBuffers.count==0) return;
    AudioStreamBasicDescription formatCopy=asbd; UInt32 framesCopy=inNumberFrames;
    dispatch_async(_ioQueue, ^{
        if (!atomic_load_explicit(&self->_recordingFlag, memory_order_relaxed)) return;
        uint16_t ch=1; uint32_t rate=16000;
        NSMutableData *pcm16Data=[[self convertBuffers:copiedBuffers frames:framesCopy format:formatCopy outChannels:&ch outSampleRate:&rate] mutableCopy];
        if (!pcm16Data || pcm16Data.length==0) return;
        CRPApplySmoothGainToPCM16(pcm16Data);
        if (![self openWavFileIfNeededWithSampleRate:rate channels:ch]) return;
        if ((uint64_t)self->_dataBytesWritten + (uint64_t)pcm16Data.length > (uint64_t)(UINT32_MAX-44u)) return;
        @try {
            [self->_fileHandle writeData:pcm16Data];
            self->_dataBytesWritten+=(uint32_t)pcm16Data.length;
            self->_bytesSinceLastHeaderFlush+=(uint32_t)pcm16Data.length;
            atomic_store_explicit(&self->_atomicBytesWritten, self->_dataBytesWritten, memory_order_relaxed);
            if (!self->_notifiedCapturing && self->_dataBytesWritten >= 4096u) {
                self->_notifiedCapturing=YES;
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CRP_DARWIN_CAPTURING_NOTIFICATION, NULL, NULL, true);
                [AudioRecorderEngine appendDiagnosticLog:[NSString stringWithFormat:@"PCM verified %u bytes native %uHz %uch -> CAPTURING", self->_dataBytesWritten, rate, ch]];
            }
            if (self->_bytesSinceLastHeaderFlush >= 32768u) { self->_bytesSinceLastHeaderFlush=0; [self writeHeaderToStartOfFileWithDataSize:self->_dataBytesWritten]; }
        } @catch (NSException *e) {}
    });
}

@end
