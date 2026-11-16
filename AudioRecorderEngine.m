#import "AudioRecorderEngine.h"
#include <roothide.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

typedef struct __attribute__((packed)) {
    char     riffId[4];       // "RIFF"
    uint32_t riffSize;        // 36 + dataSize
    char     waveId[4];       // "WAVE"
    char     fmtId[4];        // "fmt "
    uint32_t fmtSize;         // 16 for PCM
    uint16_t audioFormat;     // 1 = Linear PCM
    uint16_t numChannels;     // 1 or 2
    uint32_t sampleRate;      // e.g. 44100 or 48000
    uint32_t byteRate;        // sampleRate * numChannels * (bitsPerSample / 8)
    uint16_t blockAlign;      // numChannels * (bitsPerSample / 8)
    uint16_t bitsPerSample;   // 16
    char     dataId[4];       // "data"
    uint32_t dataSize;        // payload bytes
} CRPWavHeader;

_Static_assert(sizeof(CRPWavHeader) == 44, "WAV RIFF/PCM header must be exactly 44 bytes");

static inline int16_t CRPFloatToInt16(float sample) {
    if (sample >= 1.0f) return INT16_MAX;
    if (sample <= -1.0f) return INT16_MIN;
    int32_t scaled = (int32_t)(sample * 32767.0f);
    if (scaled > INT16_MAX) return INT16_MAX;
    if (scaled < INT16_MIN) return INT16_MIN;
    return (int16_t)scaled;
}

@interface AudioRecorderEngine () {
    dispatch_queue_t _ioQueue;
    NSFileHandle *_fileHandle;
    atomic_bool _recordingFlag;
    BOOL _headerInitialized;
    uint32_t _dataBytesWritten;
    uint32_t _bytesSinceLastHeaderFlush;
    uint16_t _wavChannels;
    uint32_t _wavSampleRate;
    NSString *_currentFilePath;
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

- (instancetype)init {
    self = [super init];
    if (self) {
        dispatch_queue_attr_t qosAttr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _ioQueue = dispatch_queue_create("com.callrecorder.ioqueue", qosAttr);
        atomic_init(&_recordingFlag, false);
        _headerInitialized = NO;
        _dataBytesWritten = 0;
        _bytesSinceLastHeaderFlush = 0;
        _wavChannels = 1;
        _wavSampleRate = 48000;
    }
    return self;
}

- (BOOL)isRecording {
    return atomic_load_explicit(&_recordingFlag, memory_order_relaxed) ? YES : NO;
}

- (NSString *)currentFilePath {
    __block NSString *path = nil;
    dispatch_sync(_ioQueue, ^{
        path = [self->_currentFilePath copy];
    });
    return path;
}

- (NSString *)recordingsDirectoryPath {
    return jbroot(@"/var/mobile/Library/CallRecordings");
}

- (void)ensureRecordingsDirectoryExists {
    NSString *dir = [self recordingsDirectoryPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        NSDictionary *attrs = @{
            NSFilePosixPermissions: @(0777),
            NSFileProtectionKey: NSFileProtectionNone
        };
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:attrs error:nil];
    }
    chmod(dir.fileSystemRepresentation, 0777);
}

- (CRPWavHeader)buildWavHeaderWithSampleRate:(uint32_t)sampleRate
                                    channels:(uint16_t)channels
                                    dataSize:(uint32_t)dataSize {
    CRPWavHeader header;
    memcpy(header.riffId, "RIFF", 4);
    header.riffSize = 36u + dataSize;
    memcpy(header.waveId, "WAVE", 4);
    memcpy(header.fmtId, "fmt ", 4);
    header.fmtSize = 16u;
    header.audioFormat = 1u; // Standard 16-bit Signed Linear PCM

    uint16_t safeChannels = (channels > 0 && channels <= 2) ? channels : 1;
    uint32_t safeRate = (sampleRate >= 8000 && sampleRate <= 192000) ? sampleRate : 48000;
    uint16_t bitsPerSample = 16u;

    header.numChannels = safeChannels;
    header.sampleRate = safeRate;
    header.bitsPerSample = bitsPerSample;
    header.blockAlign = (uint16_t)(safeChannels * (bitsPerSample / 8u));
    header.byteRate = safeRate * (uint32_t)header.blockAlign;

    memcpy(header.dataId, "data", 4);
    header.dataSize = dataSize;
    return header;
}

- (void)writeHeaderToStartOfFileWithDataSize:(uint32_t)dataSize {
    if (!_fileHandle) return;
    CRPWavHeader header = [self buildWavHeaderWithSampleRate:_wavSampleRate
                                                    channels:_wavChannels
                                                    dataSize:dataSize];
    @try {
        [_fileHandle seekToFileOffset:0];
        [_fileHandle writeData:[NSData dataWithBytes:&header length:sizeof(CRPWavHeader)]];
        [_fileHandle seekToEndOfFile];
    } @catch (NSException *exception) {
        // Guard against unexpected file handle errors in audio daemon
    }
}

- (void)startRecording {
    dispatch_async(_ioQueue, ^{
        if (atomic_load_explicit(&self->_recordingFlag, memory_order_relaxed)) {
            return;
        }

        [self ensureRecordingsDirectoryExists];

        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
        NSString *timestamp = [formatter stringFromDate:[NSDate date]];
        NSString *fileName = [NSString stringWithFormat:@"Call_%@.wav", timestamp];
        NSString *filePath = [[self recordingsDirectoryPath] stringByAppendingPathComponent:fileName];

        NSDictionary *fileAttrs = @{
            NSFilePosixPermissions: @(0666),
            NSFileProtectionKey: NSFileProtectionNone
        };
        [[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:fileAttrs];
        chmod(filePath.fileSystemRepresentation, 0666);

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:filePath];
        if (!handle) {
            return;
        }

        self->_fileHandle = handle;
        self->_currentFilePath = [filePath copy];
        self->_dataBytesWritten = 0;
        self->_bytesSinceLastHeaderFlush = 0;
        self->_headerInitialized = NO;
        self->_wavChannels = 1;
        self->_wavSampleRate = 48000;

        // Write valid initial 44-byte WAV header immediately
        CRPWavHeader initialHeader = [self buildWavHeaderWithSampleRate:self->_wavSampleRate
                                                               channels:self->_wavChannels
                                                               dataSize:0];
        @try {
            [self->_fileHandle writeData:[NSData dataWithBytes:&initialHeader length:sizeof(CRPWavHeader)]];
        } @catch (NSException *exception) {
            [self->_fileHandle closeFile];
            self->_fileHandle = nil;
            self->_currentFilePath = nil;
            return;
        }

        atomic_store_explicit(&self->_recordingFlag, true, memory_order_release);
    });
}

- (void)stopRecording {
    dispatch_async(_ioQueue, ^{
        if (!atomic_load_explicit(&self->_recordingFlag, memory_order_relaxed)) {
            return;
        }

        atomic_store_explicit(&self->_recordingFlag, false, memory_order_release);

        if (self->_fileHandle) {
            [self writeHeaderToStartOfFileWithDataSize:self->_dataBytesWritten];
            @try {
                [self->_fileHandle synchronizeFile];
                [self->_fileHandle closeFile];
            } @catch (NSException *exception) {
            }
            self->_fileHandle = nil;
        }

        if (self->_currentFilePath) {
            chmod(self->_currentFilePath.fileSystemRepresentation, 0666);
        }

        self->_headerInitialized = NO;
        self->_dataBytesWritten = 0;
        self->_bytesSinceLastHeaderFlush = 0;
        self->_currentFilePath = nil;
    });
}

- (NSData *)convertBuffers:(NSArray<NSData *> *)buffers
                    frames:(UInt32)frames
                    format:(AudioStreamBasicDescription)asbd
               outChannels:(uint16_t *)outChannels
             outSampleRate:(uint32_t *)outSampleRate {
    if (buffers.count == 0 || frames == 0) return nil;

    BOOL isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL isNonInterleaved = ((asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0) || (buffers.count > 1);
    uint32_t bits = asbd.mBitsPerChannel > 0 ? asbd.mBitsPerChannel : (isFloat ? 32u : 16u);
    uint32_t rawChannels = asbd.mChannelsPerFrame > 0 ? asbd.mChannelsPerFrame : (uint32_t)buffers.count;
    uint16_t targetChannels = (rawChannels >= 2) ? 2 : 1;
    uint32_t sampleRate = (asbd.mSampleRate >= 8000.0 && asbd.mSampleRate <= 192000.0)
        ? (uint32_t)(asbd.mSampleRate + 0.5)
        : 48000u;

    if (outChannels) *outChannels = targetChannels;
    if (outSampleRate) *outSampleRate = sampleRate;

    // Fast path: already 16-bit interleaved (or mono) signed integer PCM
    if (!isFloat && bits == 16 && (!isNonInterleaved || targetChannels == 1) && rawChannels == targetChannels) {
        NSData *first = buffers[0];
        NSUInteger expectedBytes = (NSUInteger)frames * (NSUInteger)targetChannels * sizeof(int16_t);
        if (first.length >= expectedBytes) {
            return (first.length == expectedBytes) ? first : [first subdataWithRange:NSMakeRange(0, expectedBytes)];
        }
        return first;
    }

    NSUInteger outByteCount = (NSUInteger)frames * (NSUInteger)targetChannels * sizeof(int16_t);
    NSMutableData *pcm16 = [NSMutableData dataWithLength:outByteCount];
    int16_t *dst = (int16_t *)pcm16.mutableBytes;

    for (uint16_t ch = 0; ch < targetChannels; ch++) {
        NSData *planeData = nil;
        uint32_t stride = 1;
        uint32_t offset = 0;

        if (isNonInterleaved) {
            planeData = (ch < buffers.count) ? buffers[ch] : buffers[0];
            stride = 1;
            offset = 0;
        } else {
            planeData = buffers[0];
            stride = (rawChannels > 0) ? rawChannels : 1;
            offset = (ch < rawChannels) ? ch : 0;
        }

        const uint8_t *bytes = (const uint8_t *)planeData.bytes;
        NSUInteger byteLen = planeData.length;

        if (isFloat && bits == 32) {
            const float *src = (const float *)bytes;
            NSUInteger maxSamples = byteLen / sizeof(float);
            for (UInt32 f = 0; f < frames; f++) {
                NSUInteger idx = (NSUInteger)f * stride + offset;
                float val = (idx < maxSamples) ? src[idx] : 0.0f;
                dst[(NSUInteger)f * targetChannels + ch] = CRPFloatToInt16(val);
            }
        } else if (!isFloat && bits == 16) {
            const int16_t *src = (const int16_t *)bytes;
            NSUInteger maxSamples = byteLen / sizeof(int16_t);
            for (UInt32 f = 0; f < frames; f++) {
                NSUInteger idx = (NSUInteger)f * stride + offset;
                dst[(NSUInteger)f * targetChannels + ch] = (idx < maxSamples) ? src[idx] : 0;
            }
        } else if (!isFloat && bits == 32) {
            // Handle 32-bit integer or 8.24 fixed-point CoreAudio samples
            const int32_t *src = (const int32_t *)bytes;
            NSUInteger maxSamples = byteLen / sizeof(int32_t);
            uint32_t fracBits = (asbd.mFormatFlags >> 7) & 0x3Fu;
            for (UInt32 f = 0; f < frames; f++) {
                NSUInteger idx = (NSUInteger)f * stride + offset;
                int32_t raw = (idx < maxSamples) ? src[idx] : 0;
                int32_t shifted = (fracBits == 24u) ? (raw >> 9) : (raw >> 16);
                if (shifted > INT16_MAX) shifted = INT16_MAX;
                if (shifted < INT16_MIN) shifted = INT16_MIN;
                dst[(NSUInteger)f * targetChannels + ch] = (int16_t)shifted;
            }
        } else {
            memset(dst, 0, outByteCount);
            break;
        }
    }

    return pcm16;
}

- (void)appendAudioBufferList:(AudioBufferList *)ioData
                       frames:(UInt32)inNumberFrames
                       format:(AudioStreamBasicDescription)asbd {
    if (!atomic_load_explicit(&_recordingFlag, memory_order_relaxed)) {
        return;
    }
    if (ioData == NULL || ioData->mNumberBuffers == 0 || inNumberFrames == 0) {
        return;
    }

    // Copy raw PCM buffers immediately on the real-time thread with zero disk I/O
    UInt32 numBuffers = MIN(ioData->mNumberBuffers, 2u);
    NSMutableArray<NSData *> *copiedBuffers = [NSMutableArray arrayWithCapacity:numBuffers];
    for (UInt32 i = 0; i < numBuffers; i++) {
        AudioBuffer buf = ioData->mBuffers[i];
        if (buf.mData != NULL && buf.mDataByteSize > 0) {
            NSData *chunk = [NSData dataWithBytes:buf.mData length:buf.mDataByteSize];
            [copiedBuffers addObject:chunk];
        }
    }

    if (copiedBuffers.count == 0) {
        return;
    }

    AudioStreamBasicDescription formatCopy = asbd;
    UInt32 framesCopy = inNumberFrames;

    dispatch_async(_ioQueue, ^{
        if (!atomic_load_explicit(&self->_recordingFlag, memory_order_relaxed) || !self->_fileHandle) {
            return;
        }

        uint16_t ch = self->_wavChannels;
        uint32_t rate = self->_wavSampleRate;
        NSData *pcm16Data = [self convertBuffers:copiedBuffers
                                          frames:framesCopy
                                          format:formatCopy
                                     outChannels:&ch
                                   outSampleRate:&rate];
        if (!pcm16Data || pcm16Data.length == 0) {
            return;
        }

        if (!self->_headerInitialized) {
            self->_wavChannels = ch;
            self->_wavSampleRate = rate;
            [self writeHeaderToStartOfFileWithDataSize:0];
            self->_headerInitialized = YES;
        }

        if ((uint64_t)self->_dataBytesWritten + (uint64_t)pcm16Data.length > (uint64_t)(UINT32_MAX - 44u)) {
            return;
        }

        @try {
            [self->_fileHandle writeData:pcm16Data];
            self->_dataBytesWritten += (uint32_t)pcm16Data.length;
            self->_bytesSinceLastHeaderFlush += (uint32_t)pcm16Data.length;

            // Flush updated WAV header every ~128 KB so files remain playable even on unexpected daemon exit
            if (self->_bytesSinceLastHeaderFlush >= 131072u) {
                self->_bytesSinceLastHeaderFlush = 0;
                [self writeHeaderToStartOfFileWithDataSize:self->_dataBytesWritten];
            }
        } @catch (NSException *exception) {
        }
    });
}

@end
