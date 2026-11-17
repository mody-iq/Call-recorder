#import "CRPRootListController.h"
#include <roothide.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

#define CRP_PREFS_PING_NOTIFICATION CFSTR("com.relaxin.callrecorder/ping")
#define CRP_PREFS_PONG_NOTIFICATION CFSTR("com.relaxin.callrecorder/pong")
#define CRP_SUITE @"com.relaxin.callrecorder"

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
@property (nonatomic, copy) NSString *displayName;
@end
@implementation CRPRecordingItem
@end

@interface CRPRootListController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIVisualEffectView *playerBar;
@property (nonatomic, strong) UILabel *nowPlayingLabel;
@property (nonatomic, strong) UILabel *currentTimeLabel;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, strong) UISlider *progressSlider;
@property (nonatomic, strong) UIButton *playPauseBtn;
@property (nonatomic, strong) NSTimer *progressTimer;
@property (nonatomic, strong) NSMutableArray<CRPRecordingItem *> *recordings;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, copy) NSString *currentlyPlayingPath;
@property (nonatomic, assign) NSInteger pongCount;
@property (nonatomic, strong) UIView *emptyView;
@end

static __weak CRPRootListController *gWeakPrefsController=nil;
static void CRPPrefsPongCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    CRPRootListController *ctrl=gWeakPrefsController;
    if (ctrl) dispatch_async(dispatch_get_main_queue(), ^{ ctrl.pongCount+=1; [ctrl.tableView reloadData]; });
}

@implementation CRPRootListController
- (instancetype)init { self=[super init]; if (self) { _recordings=[NSMutableArray array]; _pongCount=0; } return self; }
- (void)reloadSpecifiers {}

- (NSArray<NSString *> *)candidateDirectories {
    NSMutableArray<NSString *> *dirs=[NSMutableArray array];
    NSString *jbPrimary=jbroot(@"/var/mobile/Library/CallRecordings");
    if (jbPrimary.length>0) [dirs addObject:jbPrimary];
    NSArray<NSString *> *ordered=@[@"/private/var/mobile/Library/CallRecordings",@"/private/var/mobile/Media/CallRecordings",@"/private/var/mobile/Media/Recordings/CallRecordings",@"/private/var/mobile/Media/DCIM/CallRecordings",@"/private/var/tmp/CallRecordings"];
    for (NSString *p in ordered) if (p.length>0 && ![dirs containsObject:p]) [dirs addObject:p];
    return dirs;
}
- (NSUserDefaults *)prefs { return [[NSUserDefaults alloc] initWithSuiteName:CRP_SUITE] ?: [NSUserDefaults standardUserDefaults]; }

#pragma mark - View lifecycle (smooth, auto-layout)

- (void)loadView {
    [super loadView];
    self.view.backgroundColor=[UIColor systemGroupedBackgroundColor];

    // Table
    UITableView *tv=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    tv.translatesAutoresizingMaskIntoConstraints=NO;
    tv.delegate=self; tv.dataSource=self; tv.allowsSelection=YES;
    tv.estimatedRowHeight=66; tv.rowHeight=UITableViewAutomaticDimension;
    tv.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:tv];
    self.tableView=tv;
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    // Empty state view (hidden by default)
    UIView *ev=[[UIView alloc] init]; ev.hidden=YES; ev.translatesAutoresizingMaskIntoConstraints=NO;
    UIImageView *evIcon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"phone.badge.checkmark"]];
    evIcon.tintColor=[UIColor systemGray2Color]; evIcon.translatesAutoresizingMaskIntoConstraints=NO; evIcon.contentMode=UIViewContentModeScaleAspectFit;
    evIcon.preferredSymbolConfiguration=[UIImageSymbolConfiguration configurationWithPointSize:48 weight:UIImageSymbolWeightLight];
    UILabel *evTitle=[[UILabel alloc] init]; evTitle.text=@"لا توجد تسجيلات بعد"; evTitle.font=[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; evTitle.textColor=[UIColor secondaryLabelColor]; evTitle.textAlignment=NSTextAlignmentCenter; evTitle.translatesAutoresizingMaskIntoConstraints=NO;
    UILabel *evSub=[[UILabel alloc] init]; evSub.text=@"ابدأ مكالمة واضغط زر التسجيل الأحمر داخل شاشة المكالمة"; evSub.font=[UIFont systemFontOfSize:13 weight:UIFontWeightRegular]; evSub.textColor=[UIColor tertiaryLabelColor]; evSub.textAlignment=NSTextAlignmentCenter; evSub.numberOfLines=0; evSub.translatesAutoresizingMaskIntoConstraints=NO;
    [ev addSubview:evIcon]; [ev addSubview:evTitle]; [ev addSubview:evSub];
    [NSLayoutConstraint activateConstraints:@[
        [evIcon.centerXAnchor constraintEqualToAnchor:ev.centerXAnchor], [evIcon.topAnchor constraintEqualToAnchor:ev.topAnchor constant:32], [evIcon.widthAnchor constraintEqualToConstant:64], [evIcon.heightAnchor constraintEqualToConstant:64],
        [evTitle.topAnchor constraintEqualToAnchor:evIcon.bottomAnchor constant:14], [evTitle.leadingAnchor constraintEqualToAnchor:ev.leadingAnchor constant:24], [evTitle.trailingAnchor constraintEqualToAnchor:ev.trailingAnchor constant:-24],
        [evSub.topAnchor constraintEqualToAnchor:evTitle.bottomAnchor constant:6], [evSub.leadingAnchor constraintEqualToAnchor:ev.leadingAnchor constant:24], [evSub.trailingAnchor constraintEqualToAnchor:ev.trailingAnchor constant:-24],
    ]];
    self.emptyView=ev;

    // Player bar – blur + controls (smooth)
    UIVisualEffectView *bar=[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    bar.translatesAutoresizingMaskIntoConstraints=NO; bar.hidden=YES; bar.layer.cornerRadius=16; bar.layer.maskedCorners=kCALayerMinXMinYCorner|kCALayerMaxXMinYCorner; bar.clipsToBounds=YES;
    bar.layer.shadowColor=[UIColor blackColor].CGColor; bar.layer.shadowOpacity=0.08; bar.layer.shadowRadius=10; bar.layer.shadowOffset=CGSizeMake(0,-3);
    [self.view addSubview:bar]; self.playerBar=bar;

    // Content inside bar
    UIView *content=bar.contentView;
    UILabel *nowLabel=[[UILabel alloc] init]; nowLabel.translatesAutoresizingMaskIntoConstraints=NO; nowLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]; nowLabel.textColor=[UIColor labelColor]; nowLabel.textAlignment=NSTextAlignmentCenter; nowLabel.text=@"لم يتم اختيار تسجيل"; nowLabel.numberOfLines=1;
    UISlider *slider=[[UISlider alloc] init]; slider.translatesAutoresizingMaskIntoConstraints=NO; slider.minimumTrackTintColor=[UIColor systemBlueColor];
    [slider addTarget:self action:@selector(sliderDragging:) forControlEvents:UIControlEventValueChanged];
    [slider addTarget:self action:@selector(sliderReleased:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchUpOutside];
    UILabel *cur=[[UILabel alloc] init]; cur.translatesAutoresizingMaskIntoConstraints=NO; cur.font=[UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium]; cur.textColor=[UIColor secondaryLabelColor]; cur.text=@"00:00";
    UILabel *dur=[[UILabel alloc] init]; dur.translatesAutoresizingMaskIntoConstraints=NO; dur.font=[UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium]; dur.textColor=[UIColor secondaryLabelColor]; dur.textAlignment=NSTextAlignmentRight; dur.text=@"00:00";
    UIButton *playBtn=[UIButton buttonWithType:UIButtonTypeSystem]; playBtn.translatesAutoresizingMaskIntoConstraints=NO; playBtn.backgroundColor=[UIColor systemBlueColor]; playBtn.tintColor=[UIColor whiteColor]; playBtn.layer.cornerRadius=22;
    [playBtn setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal]; [playBtn addTarget:self action:@selector(togglePlayPause) forControlEvents:UIControlEventTouchUpInside];
    UIButton *share=[UIButton buttonWithType:UIButtonTypeSystem]; share.translatesAutoresizingMaskIntoConstraints=NO; [share setImage:[UIImage systemImageNamed:@"square.and.arrow.up"] forState:UIControlStateNormal]; [share addTarget:self action:@selector(playerShareTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *del=[UIButton buttonWithType:UIButtonTypeSystem]; del.translatesAutoresizingMaskIntoConstraints=NO; del.tintColor=[UIColor systemRedColor]; [del setImage:[UIImage systemImageNamed:@"trash"] forState:UIControlStateNormal]; [del addTarget:self action:@selector(playerDeleteTapped) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:nowLabel]; [content addSubview:slider]; [content addSubview:cur]; [content addSubview:dur]; [content addSubview:playBtn]; [content addSubview:share]; [content addSubview:del];
    self.nowPlayingLabel=nowLabel; self.progressSlider=slider; self.currentTimeLabel=cur; self.durationLabel=dur; self.playPauseBtn=playBtn;

    // Layout
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [bar.heightAnchor constraintEqualToConstant:116],
        [nowLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:10],
        [nowLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [nowLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [cur.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [cur.centerYAnchor constraintEqualToAnchor:slider.centerYAnchor],
        [cur.widthAnchor constraintEqualToConstant:40],
        [dur.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [dur.centerYAnchor constraintEqualToAnchor:slider.centerYAnchor],
        [dur.widthAnchor constraintEqualToConstant:40],
        [slider.topAnchor constraintEqualToAnchor:nowLabel.bottomAnchor constant:6],
        [slider.leadingAnchor constraintEqualToAnchor:cur.trailingAnchor constant:8],
        [slider.trailingAnchor constraintEqualToAnchor:dur.leadingAnchor constant:-8],
        [playBtn.topAnchor constraintEqualToAnchor:slider.bottomAnchor constant:10],
        [playBtn.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [playBtn.widthAnchor constraintEqualToConstant:44], [playBtn.heightAnchor constraintEqualToConstant:44],
        [share.centerYAnchor constraintEqualToAnchor:playBtn.centerYAnchor],
        [share.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:28],
        [share.widthAnchor constraintEqualToConstant:32], [share.heightAnchor constraintEqualToConstant:32],
        [del.centerYAnchor constraintEqualToAnchor:playBtn.centerYAnchor],
        [del.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-28],
        [del.widthAnchor constraintEqualToConstant:32], [del.heightAnchor constraintEqualToConstant:32],
    ]];
}

- (UIView *)buildHeaderView {
    CGFloat w = self.tableView.bounds.size.width;
    if (w < 100) w = UIScreen.mainScreen.bounds.size.width;
    UIView *container=[[UIView alloc] initWithFrame:CGRectMake(0,0,w,150)];
    // Card
    UIView *card=[[UIView alloc] initWithFrame:CGRectMake(16,12,w-32,128)];
    card.backgroundColor=[UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius=20; card.layer.cornerCurve=kCACornerCurveContinuous;
    card.layer.shadowColor=[UIColor blackColor].CGColor; card.layer.shadowOpacity=0.06; card.layer.shadowRadius=10; card.layer.shadowOffset=CGSizeMake(0,4);
    [container addSubview:card];

    // Icon + title row
    UIImageView *icon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"waveform.circle.fill"]];
    icon.tintColor=[UIColor systemBlueColor]; icon.frame=CGRectMake(14,14,30,30);
    icon.preferredSymbolConfiguration=[UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightRegular];
    [card addSubview:icon];
    UILabel *title=[[UILabel alloc] initWithFrame:CGRectMake(50,14, w-120,20)];
    title.text=@"مسجل المكالمات"; title.font=[UIFont systemFontOfSize:16 weight:UIFontWeightBold]; title.textColor=[UIColor labelColor];
    [card addSubview:title];
    UILabel *subtitle=[[UILabel alloc] initWithFrame:CGRectMake(50,34, w-120,13)];
    subtitle.text=@"تسجيل تلقائي نقي — بدون سبيكر"; subtitle.font=[UIFont systemFontOfSize:11 weight:UIFontWeightMedium]; subtitle.textColor=[UIColor secondaryLabelColor];
    [card addSubview:subtitle];

    // Status pill
    BOOL active = self.pongCount>0;
    NSString *txt = active ? @"نشط" : @"بانتظار الخدمة";
    UIColor *pillColor = active ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
    UIView *pill=[[UIView alloc] initWithFrame:CGRectMake(card.bounds.size.width-70,16,58,22)];
    pill.backgroundColor=[pillColor colorWithAlphaComponent:0.12]; pill.layer.cornerRadius=11; pill.clipsToBounds=YES;
    UIView *dot=[[UIView alloc] initWithFrame:CGRectMake(8,7,8,8)]; dot.backgroundColor=pillColor; dot.layer.cornerRadius=4;
    [pill addSubview:dot];
    UILabel *pillLab=[[UILabel alloc] initWithFrame:CGRectMake(20,0,34,22)]; pillLab.text=txt; pillLab.font=[UIFont systemFontOfSize:10 weight:UIFontWeightBold]; pillLab.textColor=pillColor; pillLab.textAlignment=NSTextAlignmentCenter;
    [pill addSubview:pillLab]; [card addSubview:pill];
    if (!active) {
        CABasicAnimation *a=[CABasicAnimation animationWithKeyPath:@"opacity"]; a.fromValue=@1; a.toValue=@0.3; a.duration=0.9; a.autoreverses=YES; a.repeatCount=HUGE_VALF;
        [dot.layer addAnimation:a forKey:@"pulse"];
    }

    // Stats row – 3 boxes
    NSUInteger totalCount=self.recordings.count; NSTimeInterval totalDur=0; unsigned long long totalSize=0;
    for (CRPRecordingItem *it in self.recordings) { totalDur+=it.duration; totalSize+=it.fileSize; }
    NSString *sizeStr= totalSize >= 1024*1024 ? [NSString stringWithFormat:@"%.1f ميجا",(double)totalSize/(1024*1024)] : (totalSize>0?[NSString stringWithFormat:@"%.0f كيلو",(double)totalSize/1024]:@"—");
    NSString *durStr= totalDur>0 ? [NSString stringWithFormat:@"%02ld:%02ld",(long)(totalDur/60),(long)((NSInteger)totalDur%60)] : @"—";

    NSArray *stats=@[
        @{@"v": [NSString stringWithFormat:@"%lu",(unsigned long)totalCount], @"l": @"التسجيلات", @"i": @"number"},
        @{@"v": durStr, @"l": @"المدة", @"i": @"clock"},
        @{@"v": sizeStr, @"l": @"الحجم", @"i": @"internaldrive"},
    ];
    CGFloat boxW=(card.bounds.size.width-32)/3.0;
    for (int i=0;i<3;i++) {
        CGFloat x=8 + boxW*i + 4;
        UIView *box=[[UIView alloc] initWithFrame:CGRectMake(x,64,boxW-8,52)];
        box.backgroundColor=[UIColor tertiarySystemGroupedBackgroundColor]; box.layer.cornerRadius=12;
        [card addSubview:box];
        UILabel *v=[[UILabel alloc] initWithFrame:CGRectMake(0,10,box.bounds.size.width,18)]; v.text=stats[i][@"v"]; v.font=[UIFont systemFontOfSize:15 weight:UIFontWeightBold]; v.textAlignment=NSTextAlignmentCenter; v.textColor=[UIColor labelColor]; [box addSubview:v];
        UILabel *l=[[UILabel alloc] initWithFrame:CGRectMake(0,30,box.bounds.size.width,14)]; l.text=stats[i][@"l"]; l.font=[UIFont systemFontOfSize:10 weight:UIFontWeightMedium]; l.textAlignment=NSTextAlignmentCenter; l.textColor=[UIColor secondaryLabelColor]; [box addSubview:l];
    }
    return container;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"مسجل المكالمات";
    self.navigationController.navigationBar.prefersLargeTitles=YES;
    self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAlways;
    gWeakPrefsController=self;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, CRPPrefsPongCallback, CRP_PREFS_PONG_NOTIFICATION, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    UIBarButtonItem *refresh=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"] style:UIBarButtonItemStylePlain target:self action:@selector(loadRecordings)];
    UIBarButtonItem *more=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(showMoreMenu)];
    self.navigationItem.rightBarButtonItems=@[more, refresh];
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"تعديل" style:UIBarButtonItemStylePlain target:self action:@selector(toggleEdit)];
    [self pingDaemons]; [self loadRecordings];
}
- (void)dealloc { CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, CRP_PREFS_PONG_NOTIFICATION, NULL); if (gWeakPrefsController==self) gWeakPrefsController=nil; [self stopPlayback]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self pingDaemons]; [self loadRecordings]; }
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [self stopPlayback]; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; CGFloat inset = self.playerBar.hidden?0:116; self.tableView.contentInset=UIEdgeInsetsMake(0,0,inset,0); self.tableView.scrollIndicatorInsets=self.tableView.contentInset; }

- (void)pingDaemons { self.pongCount=0; CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CRP_PREFS_PING_NOTIFICATION, NULL, NULL, true); dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.35*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{ [self.tableView reloadData]; }); }
- (void)toggleEdit { BOOL ed=!self.tableView.isEditing; [self.tableView setEditing:ed animated:YES]; self.navigationItem.leftBarButtonItem.title=ed?@"تم":@"تعديل"; self.navigationItem.leftBarButtonItem.style=ed?UIBarButtonItemStyleDone:UIBarButtonItemStylePlain; }

#pragma mark - Helpers

- (NSTimeInterval)readWavDurationAtPath:(NSString *)path fileSize:(unsigned long long)fileSize payload:(uint32_t)payload {
    if (payload==0) { if (fileSize>44) { AVAudioPlayer *tmp=[[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil]; if (tmp) return tmp.duration; } return 0; }
    NSFileHandle *fh=[NSFileHandle fileHandleForReadingAtPath:path]; if (!fh) return 0;
    NSData *hdr=[fh readDataOfLength:44]; [fh closeFile]; if (hdr.length<44) return 0;
    const uint8_t *b=(const uint8_t*)hdr.bytes; if (memcmp(b,"RIFF",4)!=0||memcmp(b+8,"WAVE",4)!=0) { AVAudioPlayer *tmp=[[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil]; return tmp?tmp.duration:0; }
    uint32_t byteRate=0; memcpy(&byteRate,b+28,sizeof(uint32_t)); if (byteRate==0) return 0; return (NSTimeInterval)payload/(NSTimeInterval)byteRate;
}
- (void)consolidateIfNeeded {
    NSArray<NSString *> *dirs=[self candidateDirectories]; if (dirs.count==0) return;
    NSString *primary=dirs.firstObject; if (!primary.length) return;
    NSFileManager *fm=[NSFileManager defaultManager]; BOOL isDir=NO;
    if (![fm fileExistsAtPath:primary isDirectory:&isDir]) { [fm createDirectoryAtPath:primary withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@(0777), NSFileProtectionKey: NSFileProtectionNone} error:nil]; chmod(primary.fileSystemRepresentation,0777); }
    for (NSUInteger idx=1; idx<dirs.count; idx++) { NSString *fallback=dirs[idx]; BOOL isDir2=NO; if (![fm fileExistsAtPath:fallback isDirectory:&isDir2]||!isDir2) continue;
        NSArray<NSString *> *files=[fm contentsOfDirectoryAtPath:fallback error:nil];
        for (NSString *file in files) { NSString *ext=file.pathExtension.lowercaseString; if (![ext isEqualToString:@"wav"]&&![ext isEqualToString:@"m4a"]&&![ext isEqualToString:@"caf"]&&![ext isEqualToString:@"json"]) continue;
            NSString *src=[fallback stringByAppendingPathComponent:file]; NSDictionary *attrs=[fm attributesOfItemAtPath:src error:nil]; unsigned long long sz=[attrs[NSFileSize] unsignedLongLongValue]; if (sz<=44 && [ext isEqualToString:@"wav"]) continue;
            if ([ext isEqualToString:@"wav"]) { uint32_t payload=CRPGetPayloadSize(src); if (payload==0) { if (sz <= (44ULL+4096ULL)) { [fm removeItemAtPath:src error:nil]; continue; } } }
            NSString *dst=[primary stringByAppendingPathComponent:file]; if ([fm fileExistsAtPath:dst]) continue; NSError *err=nil; [fm copyItemAtPath:src toPath:dst error:&err]; if (!err) chmod(dst.fileSystemRepresentation,0666); } }
}
- (void)loadRecordings {
    if (!self.recordings) self.recordings=[NSMutableArray array]; [self.recordings removeAllObjects]; [self consolidateIfNeeded];
    NSFileManager *fm=[NSFileManager defaultManager]; NSMutableSet<NSString *> *seen=[NSMutableSet set];
    for (NSString *dir in [self candidateDirectories]) {
        BOOL isDir=NO; if (![fm fileExistsAtPath:dir isDirectory:&isDir]||!isDir) continue;
        NSArray<NSString *> *files=[fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *file in files) {
            NSString *ext=file.pathExtension.lowercaseString; if (![ext isEqualToString:@"wav"]&&![ext isEqualToString:@"m4a"]&&![ext isEqualToString:@"caf"]) continue;
            NSString *fullPath=[[dir stringByAppendingPathComponent:file] stringByStandardizingPath]; if ([seen containsObject:fullPath]) continue;
            NSDictionary *attrs=[fm attributesOfItemAtPath:fullPath error:nil]; unsigned long long size=[attrs[NSFileSize] unsignedLongLongValue]; if (size<=44) continue;
            uint32_t payload=0; if ([ext isEqualToString:@"wav"]) { payload=CRPGetPayloadSize(fullPath); if (payload==0) { if (size <= (44ULL+4096ULL)) { [fm removeItemAtPath:fullPath error:nil]; continue; } else continue; } if (payload<1024) continue; } else { if (size<1024) continue; payload=(uint32_t)size; }
            BOOL dup=NO; for (CRPRecordingItem *ex in self.recordings) if ([ex.fileName isEqualToString:file]) { dup=YES; break; } if (dup) continue;
            [seen addObject:fullPath];
            CRPRecordingItem *item=[[CRPRecordingItem alloc] init]; item.fileName=file; item.filePath=fullPath; item.creationDate=attrs[NSFileModificationDate]?: (attrs[NSFileCreationDate]?:[NSDate distantPast]); item.fileSize=size; item.payloadBytes=payload; item.duration=[self readWavDurationAtPath:fullPath fileSize:size payload:payload];
            NSString *jsonPath=[[fullPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"];
            if ([fm fileExistsAtPath:jsonPath]) { NSData *d=[NSData dataWithContentsOfFile:jsonPath]; NSDictionary *j=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]; if (j[@"handle"]) { NSString *h=j[@"handle"]; if (h.length && ![h isEqualToString:@"Unknown"]) item.displayName=h; } if (j[@"contact"] && [j[@"contact"] length]) item.displayName=j[@"contact"]; }
            if (!item.displayName.length) {
                NSArray *parts=[file componentsSeparatedByString:@"_"];
                if (parts.count>=3) { NSString *maybe=parts[2]; maybe=[maybe stringByReplacingOccurrencesOfString:@".wav" withString:@""]; maybe=[maybe stringByReplacingOccurrencesOfString:@"-mediad" withString:@""]; if (maybe.length && ![maybe isEqualToString:@"Unknown"]) item.displayName=maybe; }
                if (!item.displayName.length) item.displayName=file;
            }
            [self.recordings addObject:item];
        }
    }
    [self.recordings sortUsingComparator:^NSComparisonResult(CRPRecordingItem *a, CRPRecordingItem *b){ return [b.creationDate compare:a.creationDate]; }];
    [self updateHeader];
    [self.tableView reloadData];
    // Empty state handling
    if (self.recordings.count==0) {
        self.tableView.backgroundView=self.emptyView; self.emptyView.hidden=NO;
    } else {
        self.tableView.backgroundView=nil; self.emptyView.hidden=YES;
    }
}
- (void)updateHeader { self.tableView.tableHeaderView=[self buildHeaderView]; }

#pragma mark - Menus & Diagnostics (simple)

- (void)showMoreMenu {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"التشخيص" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self showDiagnostics]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"نصائح لصوت نقي" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self showTips]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"فتح مجلد التسجيلات" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        NSString *primary=[self candidateDirectories].firstObject?:@"/var/mobile/Library/CallRecordings";
        UIPasteboard.generalPasteboard.string=primary;
        UIAlertController *c=[UIAlertController alertControllerWithTitle:@"تم نسخ المسار" message:primary preferredStyle:UIAlertControllerStyleAlert];
        [c addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:c animated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"حذف كل التسجيلات" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){ [self confirmDeleteAll]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    if (a.popoverPresentationController) { a.popoverPresentationController.sourceView=self.view; a.popoverPresentationController.sourceRect=CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2,1,1); }
    [self presentViewController:a animated:YES completion:nil];
}

- (NSString *)collectReport {
    NSMutableString *r=[NSMutableString string]; [r appendString:@"مسجل المكالمات v1.3.3 — 16kHz mono — تشخيص\n"];
    [r appendFormat:@"الخدمات: %ld %@\n", (long)self.pongCount, self.pongCount>0?@"✅ نشطة":@"⚠️ غير نشطة - فعّل الحقن في RootHide"];
    if (self.pongCount==0) [r appendString:@"→ الإعدادات > RootHide Manager > فعّل mediaserverd / audiomxd / callservicesd / avconferenced ثم Respring.\n"];
    [r appendString:@"\nالتخزين:\n"]; NSFileManager *fm=[NSFileManager defaultManager];
    for (NSString *dir in [self candidateDirectories]) { BOOL exists=[fm fileExistsAtPath:dir]; NSUInteger cnt=0; if (exists) { for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) if ([f.pathExtension.lowercaseString isEqualToString:@"wav"]) cnt++; } [r appendFormat:@"• %@ [%@ • %lu ملف]\n", dir, exists?@"✓":@"—", (unsigned long)cnt]; }
    [r appendFormat:@"\nالمسار الرئيسي: %@\n", [self candidateDirectories].firstObject?:@"NONE"];
    [r appendString:@"\nالسجلات (آخر 4KB):\n"]; BOOL found=NO;
    for (NSString *dir in [self candidateDirectories]) { NSString *logPath=[dir stringByAppendingPathComponent:@"diagnostics.log"]; if ([fm fileExistsAtPath:logPath]) { NSString *c=[NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil]; if (c.length) { found=YES; if (c.length>3800) c=[c substringFromIndex:c.length-3800]; [r appendFormat:@"[%@]\n%@\n", dir.lastPathComponent, c]; } } }
    if (!found) [r appendString:@"لا توجد سجلات بعد — ابدأ مكالمة ثم اضغط تسجيل.\n"];
    return r;
}
- (void)showDiagnostics {
    [self pingDaemons];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.4*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
        NSString *report=[self collectReport];
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"التشخيص" message:report preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"نسخ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [UIPasteboard generalPasteboard].string=report; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"مسح السجلات" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){ for (NSString *dir in [self candidateDirectories]) [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:@"diagnostics.log"] error:nil]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"إغلاق" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    });
}
- (void)showTips {
    UIAlertController *t=[UIAlertController alertControllerWithTitle:@"للحصول على صوت نقي" message:@"• لا تحتاج فتح السبيكر — التسجيل يلتقط الطرفين مباشرة\n• تأكد من تفعيل الحقن لـ audiomxd + mediaserverd + callservicesd في RootHide ثم Respring\n• بعد التثبيت اعمل Respring\n• الميك ON/OFF لم يعد يؤثر — التسجيل الآن أحادي 16kHz نقي بدون تشويش" preferredStyle:UIAlertControllerStyleAlert];
    [t addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:t animated:YES completion:nil];
}
- (void)confirmDeleteAll {
    if (self.recordings.count==0) return;
    UIAlertController *c=[UIAlertController alertControllerWithTitle:@"حذف كل التسجيلات؟" message:[NSString stringWithFormat:@"سيتم حذف %lu ملف نهائياً",(unsigned long)self.recordings.count] preferredStyle:UIAlertControllerStyleAlert];
    [c addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [c addAction:[UIAlertAction actionWithTitle:@"حذف الكل" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *y){ for (CRPRecordingItem *it in self.recordings) { [[NSFileManager defaultManager] removeItemAtPath:it.filePath error:nil]; NSString *json=[[it.filePath stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"]; [[NSFileManager defaultManager] removeItemAtPath:json error:nil]; } [self loadRecordings]; [self hidePlayer]; }]];
    [self presentViewController:c animated:YES completion:nil];
}

#pragma mark - Playback (smooth)

- (void)stopPlayback { if (self.progressTimer) { [self.progressTimer invalidate]; self.progressTimer=nil; } if (self.audioPlayer.isPlaying) [self.audioPlayer stop]; self.audioPlayer=nil; self.currentlyPlayingPath=nil; [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil]; [self.playPauseBtn setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal]; [self.tableView reloadData]; }
- (void)hidePlayer { if (self.playerBar.hidden) return; [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{ self.playerBar.alpha=0; } completion:^(BOOL f){ self.playerBar.hidden=YES; self.playerBar.alpha=1; [self.view setNeedsLayout]; [self.view layoutIfNeeded]; }]; [self stopPlayback]; }
- (void)showPlayerForItem:(CRPRecordingItem *)item {
    self.playerBar.hidden=NO; self.playerBar.alpha=1; [self.view bringSubviewToFront:self.playerBar];
    self.nowPlayingLabel.text=[NSString stringWithFormat:@"%@ • %@", item.displayName ?: item.fileName, [self formattedDuration:item.duration]];
    self.durationLabel.text=[self formattedDuration:item.duration]; self.currentTimeLabel.text=@"00:00"; self.progressSlider.value=0;
    [self.view setNeedsLayout];
}
- (void)playRecordingAtPath:(NSString *)path item:(CRPRecordingItem *)item {
    if ([self.currentlyPlayingPath isEqualToString:path] && self.audioPlayer.isPlaying) { [self pausePlayback]; return; }
    if ([self.currentlyPlayingPath isEqualToString:path] && self.audioPlayer && !self.audioPlayer.isPlaying) { [self resumePlayback]; return; }
    [self stopPlayback];
    AVAudioSession *session=[AVAudioSession sharedInstance]; [session setCategory:AVAudioSessionCategoryPlayback error:nil]; [session setActive:YES error:nil];
    NSURL *url=[NSURL fileURLWithPath:path]; NSError *err=nil;
    self.audioPlayer=[[AVAudioPlayer alloc] initWithContentsOfURL:url error:&err];
    if (!self.audioPlayer || err) { UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"تعذر التشغيل" message:err.localizedDescription?:@"الملف تالف" preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:alert animated:YES completion:nil]; return; }
    self.audioPlayer.delegate=self; [self.audioPlayer prepareToPlay];
    if ([self.audioPlayer play]) {
        self.currentlyPlayingPath=path; [self showPlayerForItem:item];
        [self.playPauseBtn setImage:[UIImage systemImageNamed:@"pause.fill"] forState:UIControlStateNormal];
        self.progressSlider.maximumValue=self.audioPlayer.duration; self.durationLabel.text=[self formattedDuration:self.audioPlayer.duration];
        self.progressTimer=[NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(updateProgress) userInfo:nil repeats:YES]; [[NSRunLoop mainRunLoop] addTimer:self.progressTimer forMode:NSRunLoopCommonModes];
        [self.tableView reloadData];
    }
}
- (void)pausePlayback { [self.audioPlayer pause]; [self.playPauseBtn setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal]; [self.progressTimer invalidate]; self.progressTimer=nil; }
- (void)resumePlayback { [self.audioPlayer play]; [self.playPauseBtn setImage:[UIImage systemImageNamed:@"pause.fill"] forState:UIControlStateNormal]; self.progressTimer=[NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(updateProgress) userInfo:nil repeats:YES]; [[NSRunLoop mainRunLoop] addTimer:self.progressTimer forMode:NSRunLoopCommonModes]; }
- (void)togglePlayPause { if (self.audioPlayer.isPlaying) [self pausePlayback]; else if (self.audioPlayer) [self resumePlayback]; }
- (void)updateProgress { if (!self.audioPlayer) return; self.progressSlider.value=self.audioPlayer.currentTime; self.currentTimeLabel.text=[self formattedDuration:self.audioPlayer.currentTime]; }
- (void)sliderDragging:(UISlider *)s { self.currentTimeLabel.text=[self formattedDuration:s.value]; }
- (void)sliderReleased:(UISlider *)s { self.audioPlayer.currentTime=s.value; if (!self.audioPlayer.isPlaying) [self.audioPlayer play]; [self.playPauseBtn setImage:[UIImage systemImageNamed:@"pause.fill"] forState:UIControlStateNormal]; if (!self.progressTimer) { self.progressTimer=[NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(updateProgress) userInfo:nil repeats:YES]; [[NSRunLoop mainRunLoop] addTimer:self.progressTimer forMode:NSRunLoopCommonModes]; } }
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)p successfully:(BOOL)f { [self.progressTimer invalidate]; self.progressTimer=nil; self.currentlyPlayingPath=nil; [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil]; [self.playPauseBtn setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal]; self.currentTimeLabel.text=[self formattedDuration:p.duration]; self.progressSlider.value=p.duration; [self.tableView reloadData]; }
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)p error:(NSError *)e { [self stopPlayback]; }
- (void)playerShareTapped { if (!self.currentlyPlayingPath) return; NSURL *url=[NSURL fileURLWithPath:self.currentlyPlayingPath]; UIActivityViewController *vc=[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil]; if (vc.popoverPresentationController) { vc.popoverPresentationController.sourceView=self.playerBar; vc.popoverPresentationController.sourceRect=CGRectMake(self.playerBar.bounds.size.width/2, 68, 1, 1); } [self presentViewController:vc animated:YES completion:nil]; }
- (void)playerDeleteTapped {
    if (!self.currentlyPlayingPath) return; NSString *path=self.currentlyPlayingPath;
    UIAlertController *confirm=[UIAlertController alertControllerWithTitle:@"حذف التسجيل؟" message:[path lastPathComponent] preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"حذف" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){ [[NSFileManager defaultManager] removeItemAtPath:path error:nil]; NSString *json=[[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"]; [[NSFileManager defaultManager] removeItemAtPath:json error:nil]; [self hidePlayer]; [self loadRecordings]; }]];
    [self presentViewController:confirm animated:YES completion:nil];
}
- (NSString *)formattedSize:(unsigned long long)bytes { if (bytes>=1024*1024) return [NSString stringWithFormat:@"%.1f ميجا",(double)bytes/(1024.0*1024)]; return [NSString stringWithFormat:@"%.0f كيلو",(double)bytes/1024.0]; }
- (NSString *)formattedDuration:(NSTimeInterval)s { NSInteger t=(NSInteger)(s+0.5); return [NSString stringWithFormat:@"%02ld:%02ld",(long)(t/60),(long)(t%60)]; }

#pragma mark - Table (clean, simple)

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { if (section==0) return 1; return (NSInteger)self.recordings.count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section { return section==0?@"الإعدادات السريعة": (self.recordings.count>0? [NSString stringWithFormat:@"التسجيلات — %lu",(unsigned long)self.recordings.count] : @"التسجيلات"); }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section==0) return @"التسجيل يعمل تلقائياً بدون سبيكر. فعّل الحقن لـ audiomxd / mediaserverd / callservicesd في RootHide Manager ثم Respring.";
    NSString *primary=[self candidateDirectories].firstObject?:@"/var/mobile/Library/CallRecordings";
    return [NSString stringWithFormat:@"اضغط للتشغيل • اسحب لليسار للحذف أو المشاركة • اضغط مطولاً لإعادة التسمية\n%@", primary];
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section==0) {
        static NSString *sid=@"SettingsCell"; UITableViewCell *cell=[tv dequeueReusableCellWithIdentifier:sid]; if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:sid];
        cell.textLabel.text=@"تحسين الصوت التلقائي"; cell.textLabel.font=[UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        cell.imageView.image=[UIImage systemImageNamed:@"waveform.path.ecg"]; cell.imageView.tintColor=[UIColor systemBlueColor];
        UISwitch *sw=[[UISwitch alloc] init]; sw.on=[[self prefs] boolForKey:@"CRPHQGainEnabled"]; if (![[self prefs] objectForKey:@"CRPHQGainEnabled"]) sw.on=YES; sw.onTintColor=[UIColor systemBlueColor]; [sw addTarget:self action:@selector(gainSwitchChanged:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView=sw;
        cell.detailTextLabel.text=sw.isOn?@"مفعّل":@"متوقف"; cell.selectionStyle=UITableViewCellSelectionStyleNone;
        return cell;
    }
    static NSString *kCell=@"RecCell";
    UITableViewCell *cell=[tv dequeueReusableCellWithIdentifier:kCell]; if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kCell];
    CRPRecordingItem *item=self.recordings[ip.row]; BOOL isPlaying=[self.currentlyPlayingPath isEqualToString:item.filePath] && self.audioPlayer.isPlaying;
    cell.imageView.image=isPlaying?[UIImage systemImageNamed:@"waveform"]:[UIImage systemImageNamed:@"phone.fill"];
    cell.imageView.tintColor=isPlaying?[UIColor systemBlueColor]:[UIColor systemGreenColor];
    NSString *title=item.displayName ?: item.fileName;
    cell.textLabel.text= isPlaying? [NSString stringWithFormat:@"⏸ %@", title] : title;
    cell.textLabel.font=[UIFont systemFontOfSize:14 weight:isPlaying?UIFontWeightBold:UIFontWeightSemibold]; cell.textLabel.textColor=isPlaying?[UIColor systemBlueColor]:[UIColor labelColor]; cell.textLabel.numberOfLines=1;
    NSDateFormatter *df=[[NSDateFormatter alloc] init]; df.dateStyle=NSDateFormatterShortStyle; df.timeStyle=NSDateFormatterShortStyle;
    NSString *dateStr=[df stringFromDate:item.creationDate];
    cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ • %@ • %@", dateStr, [self formattedDuration:item.duration], [self formattedSize:item.fileSize]];
    cell.detailTextLabel.textColor=[UIColor secondaryLabelColor]; cell.detailTextLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightRegular]; cell.detailTextLabel.numberOfLines=1;
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)gainSwitchChanged:(UISwitch *)sw { [[self prefs] setBool:sw.isOn forKey:@"CRPHQGainEnabled"]; [[self prefs] synchronize]; CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.relaxin.callrecorder/prefsChanged"), NULL, NULL, true); [self.tableView reloadData]; }
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip { [tv deselectRowAtIndexPath:ip animated:YES]; if (ip.section==0) return; CRPRecordingItem *item=self.recordings[ip.row]; [self playRecordingAtPath:item.filePath item:item]; }
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section==1; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip { return ip.section==1?UITableViewCellEditingStyleDelete:UITableViewCellEditingStyleNone; }
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip { if (style==UITableViewCellEditingStyleDelete && ip.section==1) [self deleteRecordingAtIndexPath:ip inTableView:tv]; }
- (void)deleteRecordingAtIndexPath:(NSIndexPath *)ip inTableView:(UITableView *)tv { if (ip.section!=1 || ip.row<0 || ip.row>=(NSInteger)self.recordings.count) return; CRPRecordingItem *item=self.recordings[ip.row]; if ([self.currentlyPlayingPath isEqualToString:item.filePath]) [self hidePlayer]; [[NSFileManager defaultManager] removeItemAtPath:item.filePath error:nil]; NSString *json=[[item.filePath stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"]; [[NSFileManager defaultManager] removeItemAtPath:json error:nil]; [self.recordings removeObjectAtIndex:ip.row]; [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic]; [self updateHeader]; if (self.recordings.count==0) { self.tableView.backgroundView=self.emptyView; self.emptyView.hidden=NO; } }
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section!=1) return nil; __weak typeof(self) weakSelf=self;
    UIContextualAction *del=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"حذف" handler:^(UIContextualAction *a, UIView *v, void(^c)(BOOL)){ [weakSelf deleteRecordingAtIndexPath:ip inTableView:tv]; c(YES); }]; del.image=[UIImage systemImageNamed:@"trash"];
    UIContextualAction *share=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"مشاركة" handler:^(UIContextualAction *a, UIView *v, void(^c)(BOOL)){ CRPRecordingItem *item=weakSelf.recordings[ip.row]; NSURL *url=[NSURL fileURLWithPath:item.filePath]; UIActivityViewController *vc=[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil]; if (vc.popoverPresentationController) { vc.popoverPresentationController.sourceView=v; vc.popoverPresentationController.sourceRect=v.bounds; } [weakSelf presentViewController:vc animated:YES completion:nil]; c(YES); }]; share.backgroundColor=[UIColor systemBlueColor]; share.image=[UIImage systemImageNamed:@"square.and.arrow.up"];
    UIContextualAction *rename=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"إعادة تسمية" handler:^(UIContextualAction *a, UIView *v, void(^c)(BOOL)){ [weakSelf renameRecordingAtIndexPath:ip]; c(YES); }]; rename.backgroundColor=[UIColor systemOrangeColor]; rename.image=[UIImage systemImageNamed:@"pencil"];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, share, rename]];
}
- (void)renameRecordingAtIndexPath:(NSIndexPath *)ip { if (ip.section!=1) return; CRPRecordingItem *item=self.recordings[ip.row]; UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"إعادة تسمية" message:item.fileName preferredStyle:UIAlertControllerStyleAlert]; [alert addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.text=[item.fileName stringByDeletingPathExtension]; tf.placeholder=@"الاسم الجديد"; }]; [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]]; [alert addAction:[UIAlertAction actionWithTitle:@"حفظ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ NSString *newName=[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]; if (newName.length==0) return; if (![newName.pathExtension.lowercaseString isEqualToString:@"wav"]) newName=[newName stringByAppendingPathExtension:@"wav"]; NSString *newPath=[[item.filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:newName]; NSError *err=nil; [[NSFileManager defaultManager] moveItemAtPath:item.filePath toPath:newPath error:&err]; if (!err) { NSString *oldJson=[[item.filePath stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"]; if ([[NSFileManager defaultManager] fileExistsAtPath:oldJson]) { NSString *newJson=[[newPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"]; [[NSFileManager defaultManager] moveItemAtPath:oldJson toPath:newJson error:nil]; } [self loadRecordings]; } }]]; [self presentViewController:alert animated:YES completion:nil]; }
@end
