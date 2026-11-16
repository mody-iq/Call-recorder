#import "CRPRootListController.h"
#include <roothide.h>
#include <stdint.h>

@interface CRPRecordingItem : NSObject
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, strong) NSDate *creationDate;
@property (nonatomic, assign) unsigned long long fileSize;
@property (nonatomic, assign) NSTimeInterval duration;
@end

@implementation CRPRecordingItem
@end

@interface CRPRootListController ()
@property (nonatomic, strong) NSMutableArray<CRPRecordingItem *> *recordings;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, copy) NSString *currentlyPlayingPath;
@end

@implementation CRPRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (UITableView *)recordingsTableView {
    if ([self respondsToSelector:@selector(table)] && [self table] != nil) {
        return [self table];
    }
    if ([self.view isKindOfClass:[UITableView class]]) {
        return (UITableView *)self.view;
    }
    return nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Call Recorder";
    self.recordings = [NSMutableArray array];

    UIBarButtonItem *refreshBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                target:self
                                                                                action:@selector(loadRecordings)];
    self.navigationItem.rightBarButtonItem = refreshBtn;

    UITableView *tv = [self recordingsTableView];
    if (tv) {
        tv.allowsSelection = YES;
        tv.allowsMultipleSelectionDuringEditing = NO;
    }

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

- (NSTimeInterval)readWavDurationAtPath:(NSString *)path fileSize:(unsigned long long)fileSize {
    if (fileSize <= 44) return 0.0;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return 0.0;
    NSData *hdr = [fh readDataOfLength:44];
    [fh closeFile];
    if (hdr.length < 44) return 0.0;

    const uint8_t *b = (const uint8_t *)hdr.bytes;
    if (memcmp(b, "RIFF", 4) != 0 || memcmp(b + 8, "WAVE", 4) != 0) {
        return 0.0;
    }

    uint32_t byteRate = 0;
    memcpy(&byteRate, b + 28, sizeof(uint32_t));
    if (byteRate == 0) return 0.0;

    unsigned long long payloadBytes = fileSize - 44ULL;
    return (NSTimeInterval)payloadBytes / (NSTimeInterval)byteRate;
}

- (void)loadRecordings {
    if (!self.recordings) {
        self.recordings = [NSMutableArray array];
    }
    [self.recordings removeAllObjects];

    NSString *dir = [self recordingsDirectory];
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:dir]) {
        [[self recordingsTableView] reloadData];
        return;
    }

    NSError *error = nil;
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:dir error:&error];
    if (error || !files) {
        [[self recordingsTableView] reloadData];
        return;
    }

    for (NSString *file in files) {
        if ([[file pathExtension].lowercaseString isEqualToString:@"wav"]) {
            NSString *fullPath = [dir stringByAppendingPathComponent:file];
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];

            CRPRecordingItem *item = [[CRPRecordingItem alloc] init];
            item.fileName = file;
            item.filePath = fullPath;
            item.creationDate = attrs[NSFileModificationDate] ?: (attrs[NSFileCreationDate] ?: [NSDate distantPast]);
            item.fileSize = size;
            item.duration = [self readWavDurationAtPath:fullPath fileSize:size];
            [self.recordings addObject:item];
        }
    }

    [self.recordings sortUsingComparator:^NSComparisonResult(CRPRecordingItem *a, CRPRecordingItem *b) {
        return [b.creationDate compare:a.creationDate];
    }];

    [[self recordingsTableView] reloadData];
}

- (void)stopPlayback {
    if (self.audioPlayer.isPlaying) {
        [self.audioPlayer stop];
    }
    self.audioPlayer = nil;
    self.currentlyPlayingPath = nil;
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    [[self recordingsTableView] reloadData];
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
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Playback Error"
                                                                       message:error.localizedDescription ?: @"Unable to play this WAV recording."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    self.audioPlayer.delegate = self;
    [self.audioPlayer prepareToPlay];
    if ([self.audioPlayer play]) {
        self.currentlyPlayingPath = path;
        [[self recordingsTableView] reloadData];
    }
}

#pragma mark - AVAudioPlayerDelegate

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    self.currentlyPlayingPath = nil;
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    [[self recordingsTableView] reloadData];
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    [self stopPlayback];
}

#pragma mark - Formatting Helpers

- (NSString *)formattedSize:(unsigned long long)bytes {
    if (bytes >= 1024ULL * 1024ULL) {
        return [NSString stringWithFormat:@"%.2f MB", (double)bytes / (1024.0 * 1024.0)];
    }
    return [NSString stringWithFormat:@"%.1f KB", (double)bytes / 1024.0];
}

- (NSString *)formattedDuration:(NSTimeInterval)seconds {
    NSInteger total = (NSInteger)(seconds + 0.5);
    NSInteger mins = total / 60;
    NSInteger secs = total % 60;
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)mins, (long)secs];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.recordings.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.recordings.count > 0
        ? [NSString stringWithFormat:@"Recorded Calls (%lu)", (unsigned long)self.recordings.count]
        : @"No Recorded Calls Yet";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"Tap a recording to play/stop • Swipe left to delete • Tap share button to export.\nStorage: %@", [self recordingsDirectory]];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const kCellIdentifier = @"CRPRecordingCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kCellIdentifier];
    }

    CRPRecordingItem *item = self.recordings[indexPath.row];
    BOOL isPlaying = [self.currentlyPlayingPath isEqualToString:item.filePath] && self.audioPlayer.isPlaying;

    cell.textLabel.text = isPlaying
        ? [NSString stringWithFormat:@"⏹ %@", item.fileName]
        : [NSString stringWithFormat:@"▶ %@", item.fileName];
    cell.textLabel.font = [UIFont systemFontOfSize:15.0 weight:isPlaying ? UIFontWeightSemibold : UIFontWeightRegular];
    cell.textLabel.textColor = isPlaying ? [UIColor systemRedColor] : [UIColor labelColor];

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateStyle = NSDateFormatterMediumStyle;
    df.timeStyle = NSDateFormatterShortStyle;
    NSString *dateStr = [df stringFromDate:item.creationDate];

    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@ • %@",
                                 dateStr,
                                 [self formattedDuration:item.duration],
                                 [self formattedSize:item.fileSize]];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    UIButton *shareBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *shareIcon = [UIImage systemImageNamed:@"square.and.arrow.up"];
    if (shareIcon) {
        [shareBtn setImage:shareIcon forState:UIControlStateNormal];
    } else {
        [shareBtn setTitle:@"Share" forState:UIControlStateNormal];
    }
    shareBtn.frame = CGRectMake(0.0, 0.0, 38.0, 38.0);
    shareBtn.tag = indexPath.row;
    [shareBtn addTarget:self action:@selector(shareButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    cell.accessoryView = shareBtn;

    return cell;
}

#pragma mark - UITableViewDelegate

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 60.0;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.recordings.count) return;
    CRPRecordingItem *item = self.recordings[indexPath.row];
    [self playRecordingAtPath:item.filePath];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleDelete;
}

- (void)deleteRecordingAtIndexPath:(NSIndexPath *)indexPath inTableView:(UITableView *)tableView {
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.recordings.count) return;
    CRPRecordingItem *item = self.recordings[indexPath.row];
    if ([self.currentlyPlayingPath isEqualToString:item.filePath]) {
        [self stopPlayback];
    }

    NSError *delErr = nil;
    [[NSFileManager defaultManager] removeItemAtPath:item.filePath error:&delErr];
    if (!delErr || ![[NSFileManager defaultManager] fileExistsAtPath:item.filePath]) {
        [self.recordings removeObjectAtIndex:indexPath.row];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        [tableView reloadData];
    }
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        [self deleteRecordingAtIndexPath:indexPath inTableView:tableView];
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                               title:@"Delete"
                                                                             handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [weakSelf deleteRecordingAtIndexPath:indexPath inTableView:tableView];
        completionHandler(YES);
    }];

    UIContextualAction *shareAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                              title:@"Share"
                                                                            handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [weakSelf presentShareSheetForRow:indexPath.row sourceView:sourceView];
        completionHandler(YES);
    }];
    shareAction.backgroundColor = [UIColor systemBlueColor];

    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction, shareAction]];
}

#pragma mark - Share / Export

- (void)shareButtonTapped:(UIButton *)sender {
    [self presentShareSheetForRow:sender.tag sourceView:sender];
}

- (void)presentShareSheetForRow:(NSInteger)row sourceView:(UIView *)sourceView {
    if (row < 0 || row >= (NSInteger)self.recordings.count) return;

    CRPRecordingItem *item = self.recordings[row];
    NSURL *fileURL = [NSURL fileURLWithPath:item.filePath];
    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL]
                                                                             applicationActivities:nil];
    if (activityVC.popoverPresentationController) {
        UIView *anchor = sourceView ?: self.view;
        activityVC.popoverPresentationController.sourceView = anchor;
        activityVC.popoverPresentationController.sourceRect = anchor.bounds;
    }
    [self presentViewController:activityVC animated:YES completion:nil];
}

@end
