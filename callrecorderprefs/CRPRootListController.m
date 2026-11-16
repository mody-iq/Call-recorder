#import "CRPRootListController.h"
#include <roothide.h>
#include <stdint.h>

#define CRP_PREFS_PING_NOTIFICATION CFSTR("com.relaxin.callrecorder/ping")
#define CRP_PREFS_PONG_NOTIFICATION CFSTR("com.relaxin.callrecorder/pong")

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
@property (nonatomic, assign) NSInteger pongCount;
@end

static void CRPPrefsPongCallback(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    CRPRootListController *ctrl = (__bridge CRPRootListController *)observer;
    if (ctrl) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ctrl.pongCount += 1;
        });
    }
}

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

- (NSArray<NSString *> *)candidateDirectories {
    NSMutableArray<NSString *> *dirs = [NSMutableArray arrayWithObjects:
        @"/private/var/mobile/Media/Recordings/CallRecordings",
        @"/private/var/mobile/Media/DCIM/CallRecordings",
        @"/private/var/mobile/Media/CallRecordings",
        nil];

    NSString *jbDir = jbroot(@"/var/mobile/Library/CallRecordings");
    if (jbDir.length > 0 && ![dirs containsObject:jbDir]) {
        [dirs addObject:jbDir];
    }

    NSArray<NSString *> *extra = @[
        @"/private/var/mobile/Library/CallRecordings",
        @"/private/var/tmp/CallRecordings"
    ];
    for (NSString *d in extra) {
        if (![dirs containsObject:d]) {
            [dirs addObject:d];
        }
    }
    return dirs;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Call Recorder";
    self.recordings = [NSMutableArray array];
    self.pongCount = 0;

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    CRPPrefsPongCallback,
                                    CRP_PREFS_PONG_NOTIFICATION,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    UIBarButtonItem *refreshBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                target:self
                                                                                action:@selector(loadRecordings)];
    UIImage *diagIcon = [UIImage systemImageNamed:@"stethoscope"] ?: [UIImage systemImageNamed:@"info.circle"];
    UIBarButtonItem *diagBtn = nil;
    if (diagIcon) {
        diagBtn = [[UIBarButtonItem alloc] initWithImage:diagIcon
                                                   style:UIBarButtonItemStylePlain
                                                  target:self
                                                  action:@selector(showDiagnostics)];
    } else {
        diagBtn = [[UIBarButtonItem alloc] initWithTitle:@"Diag"
                                                   style:UIBarButtonItemStylePlain
                                                  target:self
                                                  action:@selector(showDiagnostics)];
    }
    self.navigationItem.rightBarButtonItems = @[refreshBtn, diagBtn];

    UITableView *tv = [self recordingsTableView];
    if (tv) {
        tv.allowsSelection = YES;
        tv.allowsMultipleSelectionDuringEditing = NO;
    }

    [self pingDaemons];
    [self loadRecordings];
}

- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                       (__bridge const void *)self,
                                       CRP_PREFS_PONG_NOTIFICATION,
                                       NULL);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self pingDaemons];
    [self loadRecordings];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopPlayback];
}

- (void)pingDaemons {
    self.pongCount = 0;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CRP_PREFS_PING_NOTIFICATION,
                                         NULL, NULL, true);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[self recordingsTableView] reloadData];
    });
}

- (NSTimeInterval)readWavDurationAtPath:(NSString *)path fileSize:(unsigned long long)fileSize {
    if (fileSize <= 44ULL) return 0.0;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return 0.0;
    NSData *hdr = [fh readDataOfLength:44];
    [fh closeFile];
    if (hdr.length < 44) return 0.0;

    const uint8_t *b = (const uint8_t *)hdr.bytes;
    if (memcmp(b, "RIFF", 4) != 0 || memcmp(b + 8, "WAVE", 4) != 0) {
        NSURL *url = [NSURL fileURLWithPath:path];
        AVAudioPlayer *tmp = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:nil];
        return tmp ? tmp.duration : 0.0;
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

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];

    for (NSString *dir in [self candidateDirectories]) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
            continue;
        }

        NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *file in files) {
            NSString *ext = [file pathExtension].lowercaseString;
            if (![ext isEqualToString:@"wav"] && ![ext isEqualToString:@"m4a"] && ![ext isEqualToString:@"caf"]) {
                continue;
            }

            NSString *fullPath = [[dir stringByAppendingPathComponent:file] stringByStandardizingPath];
            if ([seenPaths containsObject:fullPath]) {
                continue;
            }

            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
            if (size <= 44ULL) {
                continue;
            }

            [seenPaths addObject:fullPath];

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

#pragma mark - Diagnostics

- (NSString *)collectDiagnosticsReport {
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"Audio Daemons Responding: %ld\n", (long)self.pongCount];
    if (self.pongCount == 0) {
        [report appendString:@"⚠️ Note: No audio daemon replied to ping. In RootHide Manager / Bootstrap, make sure Tweak Injection is enabled for System Daemons (audiomxd, mediaserverd, callservicesd) or run Userspace Reboot.\n"];
    } else {
        [report appendString:@"✅ Audio daemon hook is active and ready.\n"];
    }

    [report appendString:@"\n--- Storage Paths ---\n"];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in [self candidateDirectories]) {
        BOOL exists = [fm fileExistsAtPath:dir];
        BOOL writable = [fm isWritableFileAtPath:dir];
        [report appendFormat:@"%@ [exists=%d, writable=%d]\n", dir, exists, writable];
    }

    [report appendString:@"\n--- Recent Logs ---\n"];
    BOOL foundLog = NO;
    for (NSString *dir in [self candidateDirectories]) {
        NSString *logPath = [dir stringByAppendingPathComponent:@"diagnostics.log"];
        if ([fm fileExistsAtPath:logPath]) {
            NSString *content = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
            if (content.length > 0) {
                foundLog = YES;
                if (content.length > 3000) {
                    content = [content substringFromIndex:(content.length - 3000)];
                }
                [report appendFormat:@"(%@)\n%@\n", dir.lastPathComponent, content];
            }
        }
    }
    if (!foundLog) {
        [report appendString:@"No diagnostic logs recorded yet. Start a call and tap the recorder button first.\n"];
    }

    return report;
}

- (void)showDiagnostics {
    [self pingDaemons];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *report = [self collectDiagnosticsReport];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"CallRecorder v1.1 Diagnostics"
                                                                       message:report
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Copy Log"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            [UIPasteboard generalPasteboard].string = report;
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Clear Log"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *action) {
            NSFileManager *fm = [NSFileManager defaultManager];
            for (NSString *dir in [self candidateDirectories]) {
                NSString *logPath = [dir stringByAppendingPathComponent:@"diagnostics.log"];
                [fm removeItemAtPath:logPath error:nil];
            }
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - Playback

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
                                                                       message:error.localizedDescription ?: @"Unable to play this recording."
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
    NSString *daemonState = self.pongCount > 0
        ? [NSString stringWithFormat:@"Audio Daemons Active (%ld)", (long)self.pongCount]
        : @"Audio Daemons: Waiting / Fallback Mode (Tap ⓘ above for Diagnostics)";
    return [NSString stringWithFormat:@"%@\nTap a recording to play/stop • Swipe left to delete • Tap share button to export.\nPrimary Storage: /var/mobile/Media/Recordings/CallRecordings", daemonState];
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
