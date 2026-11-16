#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudioTypes.h>

NS_ASSUME_NONNULL_BEGIN

#define CRP_DARWIN_START_NOTIFICATION     CFSTR("com.relaxin.callrecorder/start")
#define CRP_DARWIN_STOP_NOTIFICATION      CFSTR("com.relaxin.callrecorder/stop")
#define CRP_DARWIN_CAPTURING_NOTIFICATION CFSTR("com.relaxin.callrecorder/capturing")
#define CRP_DARWIN_PING_NOTIFICATION      CFSTR("com.relaxin.callrecorder/ping")
#define CRP_DARWIN_PONG_NOTIFICATION      CFSTR("com.relaxin.callrecorder/pong")

@interface AudioRecorderEngine : NSObject

@property (nonatomic, assign, readonly, getter=isRecording) BOOL recording;
@property (nonatomic, copy, readonly, nullable) NSString *currentFilePath;
@property (nonatomic, assign, readonly) uint32_t currentBytesWritten;

+ (instancetype)sharedInstance;

+ (NSArray<NSString *> *)candidateStorageDirectories;
+ (nullable NSString *)resolveWritableRecordingsDirectory;
+ (void)consolidateRecordingsToPrimaryDirectory;
+ (void)appendDiagnosticLog:(NSString *)message;
+ (uint32_t)wavDataPayloadSizeAtPath:(NSString *)path;
+ (BOOL)isValidRecordingAtPath:(NSString *)path;

- (void)startRecording;
- (void)stopRecording;
- (void)startRecordingWithMetadata:(nullable NSDictionary *)metadata;
- (void)appendAudioBufferList:(AudioBufferList *)ioData
                       frames:(UInt32)inNumberFrames
                       format:(AudioStreamBasicDescription)asbd;

@end

NS_ASSUME_NONNULL_END
