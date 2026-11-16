#import "CRPRootListController.h"
#include <roothide.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

#define CRP_PREFS_PING_NOTIFICATION CFSTR("com.relaxin.callrecorder/ping")
#define CRP_PREFS_PONG_NOTIFICATION CFSTR("com.relaxin.callrecorder/pong")

// Forward declare helpers replicated from AudioRecorderEngine for prefs isolation
static uint32_t CRPGetPayloadSize(NSString *path) {
    if (path.length==0) return 0;
    const char *cPath=path.fileSystemRepresentation; if (!cPath) return 0;
    struct stat st; if (stat(cPath,&st)!=0) return 0; if (st.st_size<44) return 0;
    int fd=open(cPath,O_RDONLY); if (fd<0) return 0;
    uint8_t h[12]; if (read(fd,h,12)!=12) { close(fd); return 0; }
    if (memcmp(h,"RIFF",4)!=0 || memcmp(h+8,"WAVE",4)!=0) { close(fd); return (st.st_size>44)?(uint32_t)(st.st_size-44):0; }
    off_t off=12;
    while (off+8 <= st.st_size) {
        uint8_t ch[8]; if (lseek(fd,off,SEEK_SET)==(off_t)-1) break; if (read(fd,ch,8)!=8) break;
        uint32_t sz=0; memcpy(&sz,ch+4,4);
        if (memcmp(ch,"data",4)==0) { close(fd); return sz; }
        if (sz > (uint32_t)st.st_size) break;
        off += 8 + (off_t)sz + (sz & 1);
        if (off > st.st_size || off > 1024*1024) break;
    }
    close(fd); return 0;
}

@interface CRPRecordingItem : NSObject
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, strong) NSDate *creationDate;
@property (nonatomic, assign) unsigned long long fileSize;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) uint32_t payloadBytes;
@end
@implementation CRPRecordingItem
@end

@interface CRPRootListController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<CRPRecordingItem *> *recordings;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, copy) NSString *currentlyPlayingPath;
@property (nonatomic, assign) NSInteger pongCount;
@end

static __weak CRPRootListController *gWeakPrefsController = nil;

static void CRPPrefsPongCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    // Use weak static to avoid dangling bridge
    CRPRootListController *ctrl = gWeakPrefsController;
    if (ctrl) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ctrl.pongCount += 1;
        });
    }
}

@implementation CRPRootListController

- (instancetype)init {
    self=[super init];
    if (self) {
        _recordings=[NSMutableArray array];
        _pongCount=0;
    }
    return self;
}

- (void)reloadSpecifiers {
    // PSViewController has no specifiers - provide no-op to satisfy any legacy calls
}

- (NSArray<NSString *> *)candidateDirectories {
    NSMutableArray<NSString *> *dirs=[NSMutableArray array];
    NSString *jbPrimary=jbroot(@"/var/mobile/Library/CallRecordings");
    if (jbPrimary.length>0) [dirs addObject:jbPrimary];
    NSArray<NSString *> *ordered=@[
        @"/private/var/mobile/Library/CallRecordings",
        @"/private/var/mobile/Media/CallRecordings",
        @"/private/var/mobile/Media/Recordings/CallRecordings",
        @"/private/var/mobile/Media/DCIM/CallRecordings",
        @"/private/var/tmp/CallRecordings"
    ];
    for (NSString *p in ordered) if (p.length>0 && ![dirs containsObject:p]) [dirs addObject:p];
    return dirs;
}

- (void)loadView {
    [super loadView];
    self.view.backgroundColor=[UIColor systemGroupedBackgroundColor];
    UITableView *tv=[[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    tv.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    tv.delegate=self; tv.dataSource=self;
    tv.allowsSelection=YES; tv.allowsMultipleSelectionDuringEditing=NO;
    self.tableView=tv;
    [self.view addSubview:tv];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"Call Recorder";
    gWeakPrefsController=self;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, CRPPrefsPongCallback, CRP_PREFS_PONG_NOTIFICATION, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    UIBarButtonItem *refreshBtn=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(loadRecordings)];
    UIImage *diagIcon=[UIImage systemImageNamed:@"info.circle"] ?: [UIImage systemImageNamed:@"stethoscope"];
    UIBarButtonItem *diagBtn=nil;
    if (diagIcon) diagBtn=[[UIBarButtonItem alloc] initWithImage:diagIcon style:UIBarButtonItemStylePlain target:self action:@selector(showDiagnostics)];
    else diagBtn=[[UIBarButtonItem alloc] initWithTitle:@"Diag" style:UIBarButtonItemStylePlain target:self action:@selector(showDiagnostics)];
    self.navigationItem.rightBarButtonItems=@[refreshBtn, diagBtn];
    [self pingDaemons];
    [self loadRecordings];
}

- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, CRP_PREFS_PONG_NOTIFICATION, NULL);
    if (gWeakPrefsController==self) gWeakPrefsController=nil;
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
    self.pongCount=0;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CRP_PREFS_PING_NOTIFICATION, NULL, NULL, true);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.3*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{ [self.tableView reloadData]; });
}

- (NSTimeInterval)readWavDurationAtPath:(NSString *)path fileSize:(unsigned long long)fileSize payload:(uint32_t)payload {
    if (payload==0) {
        if (fileSize>44) {
            NSURL *url=[NSURL fileURLWithPath:path];
            AVAudioPlayer *tmp=[[AVAudioPlayer alloc] initWithContentsOfURL:url error:nil];
            if (tmp) return tmp.duration;
        }
        return 0.0;
    }
    NSFileHandle *fh=[NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return 0.0;
    NSData *hdr=[fh readDataOfLength:44]; [fh closeFile];
    if (hdr.length<44) return 0.0;
    const uint8_t *b=(const uint8_t*)hdr.bytes;
    if (memcmp(b,"RIFF",4)!=0 || memcmp(b+8,"WAVE",4)!=0) {
        NSURL *url=[NSURL fileURLWithPath:path]; AVAudioPlayer *tmp=[[AVAudioPlayer alloc] initWithContentsOfURL:url error:nil]; return tmp?tmp.duration:0.0;
    }
    uint32_t byteRate=0; memcpy(&byteRate,b+28,sizeof(uint32_t));
    if (byteRate==0) return 0.0;
    return (NSTimeInterval)payload / (NSTimeInterval)byteRate;
}

- (void)consolidateRecordingsIfNeeded {
    NSArray<NSString *> *dirs=[self candidateDirectories];
    if (dirs.count==0) return;
    NSString *primary=dirs.firstObject;
    if (primary.length==0) return;
    NSFileManager *fm=[NSFileManager defaultManager];
    BOOL isDir=NO;
    if (![fm fileExistsAtPath:primary isDirectory:&isDir]) {
        [fm createDirectoryAtPath:primary withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@(0777), NSFileProtectionKey: NSFileProtectionNone} error:nil];
        chmod(primary.fileSystemRepresentation,0777);
    }
    for (NSUInteger idx=1; idx<dirs.count; idx++) {
        NSString *fallback=dirs[idx];
        BOOL isDir2=NO; if (![fm fileExistsAtPath:fallback isDirectory:&isDir2] || !isDir2) continue;
        NSArray<NSString *> *files=[fm contentsOfDirectoryAtPath:fallback error:nil];
        for (NSString *file in files) {
            NSString *ext=file.pathExtension.lowercaseString;
            if (![ext isEqualToString:@"wav"] && ![ext isEqualToString:@"m4a"] && ![ext isEqualToString:@"caf"]) continue;
            NSString *src=[fallback stringByAppendingPathComponent:file];
            NSDictionary *attrs=[fm attributesOfItemAtPath:src error:nil]; unsigned long long sz=[attrs[NSFileSize] unsignedLongLongValue];
            if (sz<=44) continue;
            uint32_t payload=CRPGetPayloadSize(src);
            if (payload==0) {
                if (sz <= (44ULL+4096ULL)) { [fm removeItemAtPath:src error:nil]; continue; }
            }
            NSString *dst=[primary stringByAppendingPathComponent:file];
            if ([fm fileExistsAtPath:dst]) continue;
            NSError *err=nil; [fm copyItemAtPath:src toPath:dst error:&err];
            if (!err) chmod(dst.fileSystemRepresentation,0666);
        }
    }
}

- (void)loadRecordings {
    if (!self.recordings) self.recordings=[NSMutableArray array];
    [self.recordings removeAllObjects];
    [self consolidateRecordingsIfNeeded];
    NSFileManager *fm=[NSFileManager defaultManager];
    NSMutableSet<NSString *> *seen=[NSMutableSet set];
    for (NSString *dir in [self candidateDirectories]) {
        BOOL isDir=NO; if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
        NSArray<NSString *> *files=[fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *file in files) {
            NSString *ext=file.pathExtension.lowercaseString;
            if (![ext isEqualToString:@"wav"] && ![ext isEqualToString:@"m4a"] && ![ext isEqualToString:@"caf"]) continue;
            NSString *fullPath=[[dir stringByAppendingPathComponent:file] stringByStandardizingPath];
            if ([seen containsObject:fullPath]) continue;
            NSDictionary *attrs=[fm attributesOfItemAtPath:fullPath error:nil];
            unsigned long long size=[attrs[NSFileSize] unsignedLongLongValue];
            if (size <= 44ULL) continue;
            uint32_t payload=0;
            NSString *ext2=fullPath.pathExtension.lowercaseString;
            if ([ext2 isEqualToString:@"wav"]) {
                payload=CRPGetPayloadSize(fullPath);
                if (payload==0) {
                    // Empty FLLR stub - delete it invisibly
                    if (size <= (44ULL+4096ULL)) { [fm removeItemAtPath:fullPath error:nil]; continue; }
                    else continue;
                }
                if (payload < 1024) continue; // too short, likely stub
            } else {
                // m4a/caf - trust fileSize
                if (size < 1024) continue;
                payload=(uint32_t)size;
            }
            NSString *canonPath=fullPath;
            // Deduplicate by filename if consolidated
            BOOL duplicateName=NO;
            for (CRPRecordingItem *existing in self.recordings) if ([existing.fileName isEqualToString:file]) { duplicateName=YES; break; }
            if (duplicateName) continue;
            [seen addObject:canonPath];
            CRPRecordingItem *item=[[CRPRecordingItem alloc] init];
            item.fileName=file; item.filePath=canonPath;
            item.creationDate=attrs[NSFileModificationDate] ?: (attrs[NSFileCreationDate] ?: [NSDate distantPast]);
            item.fileSize=size; item.payloadBytes=payload;
            item.duration=[self readWavDurationAtPath:canonPath fileSize:size payload:payload];
            [self.recordings addObject:item];
        }
    }
    [self.recordings sortUsingComparator:^NSComparisonResult(CRPRecordingItem *a, CRPRecordingItem *b){ return [b.creationDate compare:a.creationDate]; }];
    [self.tableView reloadData];
}

#pragma mark - Diagnostics

- (NSString *)collectDiagnosticsReport {
    NSMutableString *r=[NSMutableString string];
    [r appendFormat:@"Audio Daemons Responding: %ld\n", (long)self.pongCount];
    if (self.pongCount==0) [r appendString:@"⚠️ No audio daemon replied. In RootHide Manager ensure Tweak Injection enabled for audiomxd, mediaserverd, callservicesd, avconferenced or run Userspace Reboot.\n"];
    else [r appendString:@"✅ Audio daemon hook active.\n"];
    [r appendString:@"\n--- Storage Paths ---\n"];
    NSFileManager *fm=[NSFileManager defaultManager];
    for (NSString *dir in [self candidateDirectories]) {
        BOOL exists=[fm fileExistsAtPath:dir]; BOOL writable=[fm isWritableFileAtPath:dir];
        struct stat st; uint32_t cnt=0; if (exists) { NSArray *files=[fm contentsOfDirectoryAtPath:dir error:nil]; for (NSString *f in files) if ([f.pathExtension.lowercaseString isEqualToString:@"wav"]) cnt++; }
        [r appendFormat:@"%@ [exists=%d writable=%d wavCount=%u]\n", dir, exists, writable, cnt];
    }
    NSString *primary=[self candidateDirectories].firstObject;
    [r appendFormat:@"\nPrimary Target: %@\n", primary ?: @"NONE"];
    [r appendString:@"\n--- Recent Logs ---\n"];
    BOOL found=NO;
    for (NSString *dir in [self candidateDirectories]) {
        NSString *logPath=[dir stringByAppendingPathComponent:@"diagnostics.log"];
        if ([fm fileExistsAtPath:logPath]) {
            NSString *content=[NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
            if (content.length>0) { found=YES; if (content.length>3000) content=[content substringFromIndex:content.length-3000]; [r appendFormat:@"(%@)\n%@\n", dir.lastPathComponent, content]; }
        }
    }
    if (!found) [r appendString:@"No diagnostics yet. Start a call and tap the recorder button.\n"];
    return r;
}

- (void)showDiagnostics {
    [self pingDaemons];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.25*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
        NSString *report=[self collectDiagnosticsReport];
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"CallRecorder v1.2 Diagnostics" message:report preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Copy Log" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [UIPasteboard generalPasteboard].string=report; }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Clear Log" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){ NSFileManager *fm=[NSFileManager defaultManager]; for (NSString *dir in [self candidateDirectories]) { NSString *logPath=[dir stringByAppendingPathComponent:@"diagnostics.log"]; [fm removeItemAtPath:logPath error:nil]; } }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - Playback

- (void)stopPlayback {
    if (self.audioPlayer.isPlaying) [self.audioPlayer stop];
    self.audioPlayer=nil; self.currentlyPlayingPath=nil;
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    [self.tableView reloadData];
}

- (void)playRecordingAtPath:(NSString *)path {
    if ([self.currentlyPlayingPath isEqualToString:path] && self.audioPlayer.isPlaying) { [self stopPlayback]; return; }
    [self stopPlayback];
    AVAudioSession *session=[AVAudioSession sharedInstance]; [session setCategory:AVAudioSessionCategoryPlayback error:nil]; [session setActive:YES error:nil];
    NSURL *url=[NSURL fileURLWithPath:path]; NSError *err=nil;
    self.audioPlayer=[[AVAudioPlayer alloc] initWithContentsOfURL:url error:&err];
    if (!self.audioPlayer || err) {
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Playback Error" message:err.localizedDescription?:@"Unable to play this recording." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:alert animated:YES completion:nil]; return;
    }
    self.audioPlayer.delegate=self; [self.audioPlayer prepareToPlay];
    if ([self.audioPlayer play]) { self.currentlyPlayingPath=path; [self.tableView reloadData]; }
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag { self.currentlyPlayingPath=nil; [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil]; [self.tableView reloadData]; }
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error { [self stopPlayback]; }

#pragma mark - Formatting

- (NSString *)formattedSize:(unsigned long long)bytes { if (bytes>=1024ULL*1024ULL) return [NSString stringWithFormat:@"%.2f MB",(double)bytes/(1024.0*1024.0)]; return [NSString stringWithFormat:@"%.1f KB",(double)bytes/1024.0]; }
- (NSString *)formattedDuration:(NSTimeInterval)s { NSInteger t=(NSInteger)(s+0.5); return [NSString stringWithFormat:@"%02ld:%02ld",(long)(t/60),(long)(t%60)]; }

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)self.recordings.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return self.recordings.count>0 ? [NSString stringWithFormat:@"Recorded Calls (%lu)",(unsigned long)self.recordings.count] : @"No Recorded Calls Yet"; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSString *daemonState=self.pongCount>0?[NSString stringWithFormat:@"Audio Daemons Active (%ld)",(long)self.pongCount]:@"Audio Daemons: Waiting / Fallback Mode (Tap ⓘ for Diagnostics)";
    NSString *primary=[self candidateDirectories].firstObject ?: @"/var/mobile/Library/CallRecordings";
    return [NSString stringWithFormat:@"%@\nTap to play/stop • Swipe left to delete/share • Primary Storage: %@\nClean FLLR stubs auto-removed.", daemonState, primary];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *kCell=@"CRPRecordingCell";
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:kCell];
    if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kCell];
    CRPRecordingItem *item=self.recordings[indexPath.row];
    BOOL isPlaying=[self.currentlyPlayingPath isEqualToString:item.filePath] && self.audioPlayer.isPlaying;
    cell.textLabel.text=isPlaying?[NSString stringWithFormat:@"⏹ %@",item.fileName]:[NSString stringWithFormat:@"▶ %@",item.fileName];
    cell.textLabel.font=[UIFont systemFontOfSize:15.0 weight:isPlaying?UIFontWeightSemibold:UIFontWeightRegular];
    cell.textLabel.textColor=isPlaying?[UIColor systemRedColor]:[UIColor labelColor];
    NSDateFormatter *df=[[NSDateFormatter alloc] init]; df.dateStyle=NSDateFormatterMediumStyle; df.timeStyle=NSDateFormatterShortStyle;
    NSString *dateStr=[df stringFromDate:item.creationDate];
    cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ • %@ • %@ • %u bytes PCM", dateStr, [self formattedDuration:item.duration], [self formattedSize:item.fileSize], item.payloadBytes];
    cell.detailTextLabel.textColor=[UIColor secondaryLabelColor]; cell.detailTextLabel.adjustsFontSizeToFitWidth=YES;
    UIButton *shareBtn=[UIButton buttonWithType:UIButtonTypeSystem]; UIImage *shareIcon=[UIImage systemImageNamed:@"square.and.arrow.up"];
    if (shareIcon) [shareBtn setImage:shareIcon forState:UIControlStateNormal]; else [shareBtn setTitle:@"Share" forState:UIControlStateNormal];
    shareBtn.frame=CGRectMake(0,0,38,38); shareBtn.tag=indexPath.row; [shareBtn addTarget:self action:@selector(shareButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    cell.accessoryView=shareBtn; cell.selectionStyle=UITableViewCellSelectionStyleDefault;
    return cell;
}

#pragma mark - UITableViewDelegate

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath { return 64.0; }
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row<0 || indexPath.row>=(NSInteger)self.recordings.count) return;
    [self playRecordingAtPath:self.recordings[indexPath.row].filePath];
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath { return UITableViewCellEditingStyleDelete; }
- (void)deleteRecordingAtIndexPath:(NSIndexPath *)indexPath inTableView:(UITableView *)tableView {
    if (indexPath.row<0 || indexPath.row>=(NSInteger)self.recordings.count) return;
    CRPRecordingItem *item=self.recordings[indexPath.row];
    if ([self.currentlyPlayingPath isEqualToString:item.filePath]) [self stopPlayback];
    NSError *err=nil; [[NSFileManager defaultManager] removeItemAtPath:item.filePath error:&err];
    if (!err || ![[NSFileManager defaultManager] fileExistsAtPath:item.filePath]) { [self.recordings removeObjectAtIndex:indexPath.row]; [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic]; [tableView reloadData]; }
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath { if (editingStyle==UITableViewCellEditingStyleDelete) [self deleteRecordingAtIndexPath:indexPath inTableView:tableView]; }
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    __weak typeof(self) weakSelf=self;
    UIContextualAction *del=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(UIContextualAction *a, UIView *v, void(^c)(BOOL)){ [weakSelf deleteRecordingAtIndexPath:indexPath inTableView:tableView]; c(YES); }];
    UIContextualAction *share=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Share" handler:^(UIContextualAction *a, UIView *v, void(^c)(BOOL)){ [weakSelf presentShareSheetForRow:indexPath.row sourceView:v]; c(YES); }];
    share.backgroundColor=[UIColor systemBlueColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, share]];
}

#pragma mark - Share

- (void)shareButtonTapped:(UIButton *)sender { [self presentShareSheetForRow:sender.tag sourceView:sender]; }
- (void)presentShareSheetForRow:(NSInteger)row sourceView:(UIView *)sourceView {
    if (row<0 || row>=(NSInteger)self.recordings.count) return;
    CRPRecordingItem *item=self.recordings[row]; NSURL *url=[NSURL fileURLWithPath:item.filePath];
    UIActivityViewController *vc=[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    if (vc.popoverPresentationController) { UIView *anchor=sourceView?:self.view; vc.popoverPresentationController.sourceView=anchor; vc.popoverPresentationController.sourceRect=anchor.bounds; }
    [self presentViewController:vc animated:YES completion:nil];
}

@end
