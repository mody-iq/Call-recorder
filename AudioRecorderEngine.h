#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudioTypes.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioRecorderEngine : NSObject

@property (nonatomic, assign, readonly, getter=isRecording) BOOL recording;
@property (nonatomic, copy, readonly, nullable) NSString *currentFilePath;

+ (instancetype)sharedInstance;

- (void)startRecording;
- (void)stopRecording;
- (void)appendAudioBufferList:(AudioBufferList *)ioData
                       frames:(UInt32)inNumberFrames
                       format:(AudioStreamBasicDescription)asbd;

@end

NS_ASSUME_NONNULL_END
