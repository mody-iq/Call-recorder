#import "CRPRootListController.h"
#include <roothide.h>

@interface CRPRecordingItem : NSObject
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, strong) NSDate *creationDate;
@property (nonatomic, assign) unsigned long long fileSize;
@end

@implementation CRPRecordingItem
@end

@interface CRPRootListController ()
@property (nonatomic, strong) NSMutableArray<CRPRecordingItem *> *recordings;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, copy) NSString *currentlyPlayingPath;
@end

@implementation CRPRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Call Recorder";
    self.recordings = [NSMutableArray array];

    UIBarButtonItem *refreshBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                target:self
                                                                                action:@selector(loadRecordings)];
    self.navigationItem.rightBarButtonItem = refreshBtn;
    [self loadRecordings];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadRecordings];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopPlayback];
}

- (NSString *)recordingsDirectory {
    return jbroot(@"/var/mobile/Library/CallRecordings");
}

- (void)loadRecordings {
    [self.recordings removeAllObjects];
    NSString *dir = [self recordingsDirectory];
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:dir]) {
        [self.tableView reloadData];
        return;
    }

    NSError *error = nil;
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:dir error:&error];
    if (error || !files) {
        [self.tableView reloadData];
        return;
    }

    for (NSString *file in files) {
        if ([[file pathExtension].lowercaseString isEqualToString:@"wav"]) {
            NSString *fullPath = [dir stringByAppendingPathComponent:file];
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];

            CRPRecordingItem *item = [[CRPRecordingItem alloc] init];
            item.fileName = file;
            item.filePath = fullPath;
            item.creationDate = attrs[NSFileCreationDate] ?: [NSDate distantPast];
            item.fileSize = [attrs[NSFileSize] unsignedLongLongValue];
            [self.recordings addObject:item];
        }
    }

    [self.recordings sortUsingComparator:^NSComparisonResult(CRPRecordingItem *a, CRPRecordingItem *b) {
        return [b.creationDate compare:a.creationDate];
    }];

    [self.tableView reloadData];
}

- (void)stopPlayback {
    if (self.audioPlayer.isPlaying) {
        [self.audioPlayer stop];
    }
    self.audioPlayer = nil;
    self.currentlyPlayingPath = nil;
    [self.tableView reloadData];
}

- (void)playRecordingAtPath:(NSString *)path {
    if ([self.currentlyPlayingPath isEqualToString:path] && self.audioPlayer.isPlaying) {
        [self stopPlayback];
        return;
    }

    [self stopPlayback];

    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback error:nil];
    [session setActive:YES error:nil];

    NSURL *url = [NSURL fileURLWithPath:path];
    NSError *error = nil;
    self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
    if (!self.audioPlayer || error) {
        return;
    }

    self.audioPlayer.delegate = self;
    [self.audioPlayer prepareToPlay];
    if ([self.audioPlayer play]) {
        self.currentlyPlayingPath = path;
        [self.tableView reloadData];
    }
}

#pragma mark - AVAudioPlayerDelegate

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    self.currentlyPlayingPath = nil;
    [self.tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.recordings.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.recordings.count > 0 ? @"Recordings" : @"No Recordings Found";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"CRPRecordingCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    }

    CRPRecordingItem *item = self.recordings[indexPath.row];
    BOOL isPlaying = [self.currentlyPlayingPath isEqualToString:item.filePath];

    cell.textLabel.text = isPlaying ? [NSString stringWithFormat:@"▶ %@", item.fileName] : item.fileName;

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateStyle = NSDateFormatterMediumStyle;
    df.timeStyle = NSDateFormatterShortStyle;
    NSString *dateStr = [df stringFromDate:item.creationDate];
    double sizeKB = (double)item.fileSize / 1024.0;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %.1f KB", dateStr, sizeKB];

    UIButton *shareBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [shareBtn setImage:[UIImage systemImageNamed:@"square.and.arrow.up"] forState:UIControlStateNormal];
    shareBtn.frame = CGRectMake(0, 0, 36, 36);
    shareBtn.tag = indexPath.row;
    [shareBtn addTarget:self action:@selector(shareButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    cell.accessoryView = shareBtn;

    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    CRPRecordingItem *item = self.recordings[indexPath.row];
    [self playRecordingAtPath:item.filePath];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        CRPRecordingItem *item = self.recordings[indexPath.row];
        if ([self.currentlyPlayingPath isEqualToString:item.filePath]) {
            [self stopPlayback];
        }
        [[NSFileManager defaultManager] removeItemAtPath:item.filePath error:nil];
        [self.recordings removeObjectAtIndex:indexPath.row];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
    }
}

#pragma mark - Share

- (void)shareButtonTapped:(UIButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.recordings.count) return;

    CRPRecordingItem *item = self.recordings[row];
    NSURL *fileURL = [NSURL fileURLWithPath:item.filePath];
    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL]
                                                                             applicationActivities:nil];
    if (activityVC.popoverPresentationController) {
        activityVC.popoverPresentationController.sourceView = sender;
        activityVC.popoverPresentationController.sourceRect = sender.bounds;
    }
    [self presentViewController:activityVC animated:YES completion:nil];
}

@end
