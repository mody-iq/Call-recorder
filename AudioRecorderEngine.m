#import "AudioRecorderEngine.h"
#include <roothide.h>
#include <stdint.h>
#include <string.h>

typedef struct __attribute__((packed)) {
    char     riffId[4];       // "RIFF"
    uint32_t riffSize;        // 36 + dataSize
    char     waveId[4];       // "WAVE"
    char     fmtId[4];        // "fmt "
    uint32_t fmtSize;         // 16 for PCM
    uint16_t audioFormat;     // 1 = PCM, 3 = IEEE Float
    uint16_t numChannels;     // 1 or 2
    uint32_t sampleRate;      // e.g. 44100 or 48000
    uint32_t byteRate;        // sampleRate * numChannels * bitsPerSample / 8
    uint16_t blockAlign;      // numChannels * bitsPerSample / 8
    uint16_t bitsPerSample;   // 16 or 32
    char     dataId[4];       // "data"
    uint32_t dataSize;        // total audio payload bytes
} CRPWavHeader;

@interface AudioRecorderEngine () {
    dispatch_queue_t _ioQueue;
    NSFileHandle *_fileHandle;
    BOOL _isRecording;
    BOOL _headerInitialized;
    uint32_t _dataBytesWritten;
    AudioStreamBasicDescription _activeFormat;
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
        _ioQueue = dispatch_queue_create("com.callrecorder.ioqueue", DISPATCH_QUEUE_SERIAL);
        _isRecording = NO;
        _headerInitialized = NO;
        _dataBytesWritten = 0;
        memset(&_activeFormat, 0, sizeof(_activeFormat));
    }
    return self;
}

- (BOOL)isRecording {
    return _isRecording;
}

- (NSString *)currentFilePath {
    return _currentFilePath;
}

- (NSString *)recordingsDirectoryPath {
    return jbroot(@"/var/mobile/Library/CallRecordings");
}

- (void)ensureRecordingsDirectoryExists {
    NSString *dir = [self recordingsDirectoryPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        NSDictionary *attrs = @{
            NSFilePosixPermissions: @(0755)
        };
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:attrs error:nil];
    }
}

- (CRPWavHeader)buildWavHeaderWithFormat:(AudioStreamBasicDescription)asbd dataSize:(uint32_t)dataSize {
    CRPWavHeader header;
    memcpy(header.riffId, "RIFF", 4);
    header.riffSize = 36 + dataSize;
    memcpy(header.waveId, "WAVE", 4);
    memcpy(header.fmtId, "fmt ", 4);
    header.fmtSize = 16;

    BOOL isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    header.audioFormat = isFloat ? 3 : 1;

    uint16_t channels = (uint16_t)(asbd.mChannelsPerFrame > 0 ? asbd.mChannelsPerFrame : 1);
    uint32_t sampleRate = (uint32_t)(asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000);
    uint16_t bitsPerSample = (uint16_t)(asbd.mBitsPerChannel > 0 ? asbd.mBitsPerChannel : 16);

    header.numChannels = channels;
    header.sampleRate = sampleRate;
    header.bitsPerSample = bitsPerSample;
    header.blockAlign = (uint16_t)(channels * (bitsPerSample / 8));
    header.byteRate = sampleRate * header.blockAlign;

    memcpy(header.dataId, "data", 4);
    header.dataSize = dataSize;
    return header;
}

- (void)startRecording {
    dispatch_async(_ioQueue, ^{
        if (self->_isRecording) {
            return;
        }

        [self ensureRecordingsDirectoryExists];

        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
        [formatter setDateFormat:@"yyyy-MM-dd_HH-mm-ss"];
        NSString *timestamp = [formatter stringFromDate:[NSDate date]];
        NSString *fileName = [NSString stringWithFormat:@"Call_%@.wav", timestamp];
        NSString *filePath = [[self recordingsDirectoryPath] stringByAppendingPathComponent:fileName];

        [[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:filePath];
        if (!handle) {
            return;
        }

        self->_fileHandle = handle;
        self->_currentFilePath = [filePath copy];
        self->_dataBytesWritten = 0;
        self->_headerInitialized = NO;
        memset(&self->_activeFormat, 0, sizeof(self->_activeFormat));

        // Reserve 44-byte WAV header
        uint8_t emptyHeader[44];
        memset(emptyHeader, 0, sizeof(emptyHeader));
        [self->_fileHandle writeData:[NSData dataWithBytes:emptyHeader length:sizeof(emptyHeader)]];

        self->_isRecording = YES;
    });
}

- (void)stopRecording {
    dispatch_async(_ioQueue, ^{
        if (!self->_isRecording) {
            return;
        }

        self->_isRecording = NO;

        if (self->_fileHandle) {
            if (self->_headerInitialized) {
                CRPWavHeader finalHeader = [self buildWavHeaderWithFormat:self->_activeFormat
                                                                  dataSize:self->_dataBytesWritten];
                [self->_fileHandle seekToFileOffset:0];
                [self->_fileHandle writeData:[NSData dataWithBytes:&finalHeader length:sizeof(CRPWavHeader)]];
            }
            [self->_fileHandle synchronizeFile];
            [self->_fileHandle closeFile];
            self->_fileHandle = nil;
        }

        self->_headerInitialized = NO;
        self->_dataBytesWritten = 0;
        self->_currentFilePath = nil;
    });
}

- (void)appendAudioBufferList:(AudioBufferList *)ioData
                       frames:(UInt32)inNumberFrames
                       format:(AudioStreamBasicDescription)asbd {
    if (!_isRecording || ioData == NULL || ioData->mNumberBuffers == 0 || inNumberFrames == 0) {
        return;
    }

    // Copy PCM buffer data immediately on the audio thread before dispatching async I/O
    NSMutableData *copiedAudio = nil;
    if (ioData->mNumberBuffers == 1) {
        AudioBuffer buf = ioData->mBuffers[0];
        if (buf.mData != NULL && buf.mDataByteSize > 0) {
            copiedAudio = [NSMutableData dataWithBytes:buf.mData length:buf.mDataByteSize];
        }
    } else {
        // Interleave or concatenate non-interleaved buffers
        UInt32 totalSize = 0;
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            totalSize += ioData->mBuffers[i].mDataByteSize;
        }
        if (totalSize > 0) {
            copiedAudio = [NSMutableData dataWithCapacity:totalSize];
            for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
                AudioBuffer buf = ioData->mBuffers[i];
                if (buf.mData != NULL && buf.mDataByteSize > 0) {
                    [copiedAudio appendBytes:buf.mData length:buf.mDataByteSize];
                }
            }
        }
    }

    if (!copiedAudio || copiedAudio.length == 0) {
        return;
    }

    AudioStreamBasicDescription formatCopy = asbd;

    dispatch_async(_ioQueue, ^{
        if (!self->_isRecording || !self->_fileHandle) {
            return;
        }

        if (!self->_headerInitialized) {
            self->_activeFormat = formatCopy;
            CRPWavHeader initialHeader = [self buildWavHeaderWithFormat:self->_activeFormat dataSize:0];
            [self->_fileHandle seekToFileOffset:0];
            [self->_fileHandle writeData:[NSData dataWithBytes:&initialHeader length:sizeof(CRPWavHeader)]];
            [self->_fileHandle seekToEndOfFile];
            self->_headerInitialized = YES;
        }

        [self->_fileHandle writeData:copiedAudio];
        self->_dataBytesWritten += (uint32_t)copiedAudio.length;
    });
}

@end
