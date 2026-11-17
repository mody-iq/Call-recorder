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
@property (nonatomic, strong) UIView *playerBar;
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

- (void)loadView {
    [super loadView];
    self.view.backgroundColor=[UIColor systemGroupedBackgroundColor];
    UITableView *tv=[[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    tv.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    tv.delegate=self; tv.dataSource=self; tv.allowsSelection=YES;
    self.tableView=tv; [self.view addSubview:tv];

    // شريط التشغيل السفلي - تصميم بسيط وواضح
    CGFloat barH=120;
    UIView *bar=[[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height-barH, self.view.bounds.size.width, barH)];
    bar.backgroundColor=[UIColor secondarySystemGroupedBackgroundColor];
    bar.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleTopMargin;
    bar.layer.shadowColor=[UIColor blackColor].CGColor; bar.layer.shadowOpacity=0.12; bar.layer.shadowRadius=8; bar.layer.shadowOffset=CGSizeMake(0,-2);
    bar.layer.cornerRadius=16; bar.layer.maskedCorners=kCALayerMinXMinYCorner|kCALayerMaxXMinYCorner; bar.clipsToBounds=NO; bar.hidden=YES;
    self.playerBar=bar;

    UILabel *nowLabel=[[UILabel alloc] initWithFrame:CGRectMake(12, 10, bar.bounds.size.width-24, 16)];
    nowLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightBold]; nowLabel.textColor=[UIColor labelColor]; nowLabel.textAlignment=NSTextAlignmentCenter; nowLabel.text=@"لم يتم اختيار تسجيل";
    nowLabel.autoresizingMask=UIViewAutoresizingFlexibleWidth; [bar addSubview:nowLabel]; self.nowPlayingLabel=nowLabel;

    UISlider *slider=[[UISlider alloc] initWithFrame:CGRectMake(50, 34, bar.bounds.size.width-100, 20)];
    slider.autoresizingMask=UIViewAutoresizingFlexibleWidth; slider.minimumTrackTintColor=[UIColor systemBlueColor];
    [slider addTarget:self action:@selector(sliderDragging:) forControlEvents:UIControlEventValueChanged];
    [slider addTarget:self action:@selector(sliderReleased:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside];
    [bar addSubview:slider]; self.progressSlider=slider;

    UILabel *cur=[[UILabel alloc] initWithFrame:CGRectMake(12, 34, 36, 20)]; cur.font=[UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium]; cur.textColor=[UIColor secondaryLabelColor]; cur.text=@"00:00"; [bar addSubview:cur]; self.currentTimeLabel=cur;
    UILabel *dur=[[UILabel alloc] initWithFrame:CGRectMake(bar.bounds.size.width-48, 34, 36, 20)]; dur.font=[UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium]; dur.textColor=[UIColor secondaryLabelColor]; dur.textAlignment=NSTextAlignmentRight; dur.text=@"00:00"; dur.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin; [bar addSubview:dur]; self.durationLabel=dur;

    UIButton *playBtn=[UIButton buttonWithType:UIButtonTypeSystem]; playBtn.frame=CGRectMake(bar.bounds.size.width/2-24, 62, 48, 48); playBtn.layer.cornerRadius=24; playBtn.backgroundColor=[UIColor systemBlueColor]; playBtn.tintColor=[UIColor whiteColor]; playBtn.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleRightMargin;
    [playBtn setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal]; [playBtn addTarget:self action:@selector(togglePlayPause) forControlEvents:UIControlEventTouchUpInside]; [bar addSubview:playBtn]; self.playPauseBtn=playBtn;

    UIButton *share=[UIButton buttonWithType:UIButtonTypeSystem]; share.frame=CGRectMake(24, 68, 36, 36); [share setImage:[UIImage systemImageNamed:@"square.and.arrow.up"] forState:UIControlStateNormal]; [share addTarget:self action:@selector(playerShareTapped) forControlEvents:UIControlEventTouchUpInside]; [bar addSubview:share];
    UIButton *del=[UIButton buttonWithType:UIButtonTypeSystem]; del.frame=CGRectMake(bar.bounds.size.width-60, 68, 36, 36); del.tintColor=[UIColor systemRedColor]; [del setImage:[UIImage systemImageNamed:@"trash"] forState:UIControlStateNormal]; [del addTarget:self action:@selector(playerDeleteTapped) forControlEvents:UIControlEventTouchUpInside]; [bar addSubview:del];

    [self.view addSubview:bar];
}

- (UIView *)buildHeaderView {
    UIView *container=[[UIView alloc] initWithFrame:CGRectMake(0,0,self.tableView.bounds.size.width,140)];
    UIView *card=[[UIView alloc] initWithFrame:CGRectMake(16,12,container.bounds.size.width-32,116)];
    card.backgroundColor=[UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius=16; card.layer.shadowColor=[UIColor blackColor].CGColor; card.layer.shadowOpacity=0.07; card.layer.shadowRadius=6; card.layer.shadowOffset=CGSizeMake(0,2);
    [container addSubview:card];

    UIImageView *icon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"phone.fill.badge.checkmark"]];
    icon.tintColor=[UIColor systemGreenColor]; icon.frame=CGRectMake(12,12,24,24); [card addSubview:icon];
    UILabel *title=[[UILabel alloc] initWithFrame:CGRectMake(44,12,200,18)]; title.text=@"مسجل المكالمات برو"; title.font=[UIFont systemFontOfSize:15 weight:UIFontWeightBold]; title.textColor=[UIColor labelColor]; [card addSubview:title];
    UILabel *subtitle=[[UILabel alloc] initWithFrame:CGRectMake(44,30,200,12)]; subtitle.text=@"تسجيل واضح بدون سبيكر • HQ"; subtitle.font=[UIFont systemFontOfSize:10 weight:UIFontWeightMedium]; subtitle.textColor=[UIColor secondaryLabelColor]; [card addSubview:subtitle];

    NSString *daemonText=self.pongCount>0 ? [NSString stringWithFormat:@"● نشط (%ld)",(long)self.pongCount] : @"○ انتظار";
    UILabel *state=[[UILabel alloc] initWithFrame:CGRectMake(card.bounds.size.width-100,14,88,14)]; state.text=daemonText; state.font=[UIFont systemFontOfSize:10 weight:UIFontWeightBold]; state.textAlignment=NSTextAlignmentRight; state.textColor=self.pongCount>0?[UIColor systemGreenColor]:[UIColor systemOrangeColor]; [card addSubview:state];

    NSUInteger totalCount=self.recordings.count; NSTimeInterval totalDur=0; unsigned long long totalSize=0;
    for (CRPRecordingItem *it in self.recordings) { totalDur+=it.duration; totalSize+=it.fileSize; }
    NSString *sizeStr= totalSize >= 1024*1024 ? [NSString stringWithFormat:@"%.1f ميجا",(double)totalSize/(1024*1024)] : [NSString stringWithFormat:@"%.0f كيلو",(double)totalSize/1024];
    NSString *durStr=[NSString stringWithFormat:@"%02ld:%02ld",(long)(totalDur/60),(long)((NSInteger)totalDur%60)];

    NSArray *stats=@[
        @{@"value": [NSString stringWithFormat:@"%lu",(unsigned long)totalCount], @"label": @"التسجيلات"},
        @{@"value": durStr, @"label": @"الوقت الكلي"},
        @{@"value": sizeStr, @"label": @"التخزين"}
    ];
    for (int i=0;i<3;i++) {
        CGFloat w=(card.bounds.size.width-24)/3; CGFloat x=12 + w*i;
        UILabel *val=[[UILabel alloc] initWithFrame:CGRectMake(x,58,w,20)]; val.text=stats[i][@"value"]; val.font=[UIFont systemFontOfSize:14 weight:UIFontWeightBold]; val.textAlignment=NSTextAlignmentCenter; val.textColor=[UIColor labelColor]; [card addSubview:val];
        UILabel *lab=[[UILabel alloc] initWithFrame:CGRectMake(x,80,w,12)]; lab.text=stats[i][@"label"]; lab.font=[UIFont systemFontOfSize:10 weight:UIFontWeightMedium]; lab.textAlignment=NSTextAlignmentCenter; lab.textColor=[UIColor secondaryLabelColor]; [card addSubview:lab];
        if (i<2) { UIView *sep=[[UIView alloc] initWithFrame:CGRectMake(x+w-0.5,60,0.5,26)]; sep.backgroundColor=[UIColor separatorColor]; [card addSubview:sep]; }
    }
    return container;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"مسجل المكالمات";
    gWeakPrefsController=self;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, CRPPrefsPongCallback, CRP_PREFS_PONG_NOTIFICATION, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    UIBarButtonItem *refresh=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(loadRecordings)];
    UIBarButtonItem *info=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"info.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(showDiagnostics)];
    UIBarButtonItem *settings=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"] style:UIBarButtonItemStylePlain target:self action:@selector(showSettings)];
    self.navigationItem.rightBarButtonItems=@[refresh, info, settings];
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"تعديل" style:UIBarButtonItemStylePlain target:self action:@selector(toggleEdit)];
    [self pingDaemons]; [self loadRecordings];
}
- (void)dealloc { CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, CRP_PREFS_PONG_NOTIFICATION, NULL); if (gWeakPrefsController==self) gWeakPrefsController=nil; [self stopPlayback]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self pingDaemons]; [self loadRecordings]; }
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [self stopPlayback]; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; CGFloat barH=120; self.playerBar.frame=CGRectMake(0, self.view.bounds.size.height-barH - self.view.safeAreaInsets.bottom, self.view.bounds.size.width, barH); self.tableView.contentInset=UIEdgeInsetsMake(0,0,self.playerBar.hidden?8:barH+8,0); }

- (void)pingDaemons { self.pongCount=0; CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CRP_PREFS_PING_NOTIFICATION, NULL, NULL, true); dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.35*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{ [self.tableView reloadData]; }); }
- (void)toggleEdit { [self.tableView setEditing:!self.tableView.isEditing animated:YES]; self.navigationItem.leftBarButtonItem.title=self.tableView.isEditing?@"تم":@"تعديل"; }

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
            // اسم العرض: حاول استخراج اسم المتصل من JSON إن وجد
            NSString *jsonPath=[[fullPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"];
            if ([fm fileExistsAtPath:jsonPath]) { NSData *d=[NSData dataWithContentsOfFile:jsonPath]; NSDictionary *j=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]; if (j[@"handle"]) { NSString *h=j[@"handle"]; if (h.length && ![h isEqualToString:@"Unknown"]) item.displayName=h; } if (j[@"contact"] && [j[@"contact"] length]) item.displayName=j[@"contact"]; }
            if (!item.displayName.length) {
                // من اسم الملف
                NSArray *parts=[file componentsSeparatedByString:@"_"];
                if (parts.count>=3) { NSString *maybe=parts[2]; maybe=[maybe stringByReplacingOccurrencesOfString:@".wav" withString:@""]; maybe=[maybe stringByReplacingOccurrencesOfString:@"-mediad" withString:@""]; if (maybe.length && ![maybe isEqualToString:@"Unknown"]) item.displayName=maybe; }
                if (!item.displayName.length) item.displayName=file;
            }
            [self.recordings addObject:item];
        }
    }
    [self.recordings sortUsingComparator:^NSComparisonResult(CRPRecordingItem *a, CRPRecordingItem *b){ return [b.creationDate compare:a.creationDate]; }];
    [self.tableView reloadData]; [self updateHeader];
}
- (void)updateHeader { self.tableView.tableHeaderView=[self buildHeaderView]; }

#pragma mark - التشخيص والإعدادات
- (NSString *)collectReport {
    NSMutableString *r=[NSMutableString string]; [r appendString:@"مسجل المكالمات برو v1.3.1\n"];
    [r appendFormat:@"الخدمات النشطة: %ld %@\n", (long)self.pongCount, self.pongCount>0?@"✅ نشطة":@"⚠️ انتظار"];
    if (self.pongCount==0) [r appendString:@"نصيحة: فعّل حقن الأداة لـ audiomxd/mediaserverd/callservicesd في RootHide Manager ثم أعد تشغيل المستخدم.\n"];
    [r appendString:@"\nأماكن التخزين:\n"]; NSFileManager *fm=[NSFileManager defaultManager];
    for (NSString *dir in [self candidateDirectories]) { BOOL exists=[fm fileExistsAtPath:dir]; NSUInteger cnt=0; if (exists) { for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) if ([f.pathExtension.lowercaseString isEqualToString:@"wav"]) cnt++; } [r appendFormat:@"%@ [%@ عدد=%lu]\n", dir, exists?@"موجود":@"غير موجود", (unsigned long)cnt]; }
    [r appendFormat:@"\nالمسار الأساسي: %@\n", [self candidateDirectories].firstObject?:@"NONE"];
    [r appendString:@"\nالسجلات:\n"]; BOOL found=NO;
    for (NSString *dir in [self candidateDirectories]) { NSString *logPath=[dir stringByAppendingPathComponent:@"diagnostics.log"]; if ([fm fileExistsAtPath:logPath]) { NSString *c=[NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil]; if (c.length) { found=YES; if (c.length>3500) c=[c substringFromIndex:c.length-3500]; [r appendFormat:@"[%@]\n%@\n", dir.lastPathComponent, c]; } } }
    if (!found) [r appendString:@"لا توجد سجلات بعد.\n"];
    return r;
}
- (void)showDiagnostics {
    [self pingDaemons];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.3*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
        NSString *report=[self collectReport];
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"التشخيص" message:report preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"نسخ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [UIPasteboard generalPasteboard].string=report; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"مسح السجلات" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){ for (NSString *dir in [self candidateDirectories]) [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:@"diagnostics.log"] error:nil]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"إغلاق" style:UIAlertActionStyleCancel handler:nil]]; [self presentViewController:a animated:YES completion:nil];
    });
}
- (void)showSettings {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"إعدادات مسجل المكالمات" message:@"التسجيل يعمل تلقائياً بدون الحاجة للسبيكر. الصوت يتم تضخيمه تلقائياً بوضوح.\n\n• تضخيم الصوت: يكبّر صوت الطرف البعيد تلقائياً\n• التخزين: يتم حفظ التسجيلات في المسار الأساسي\n• الحذف: اسحب التسجيل لليسار للحذف أو المشاركة" preferredStyle:UIAlertControllerStyleActionSheet];
    BOOL gainOn=[[self prefs] boolForKey:@"CRPHQGainEnabled"]; if (![[self prefs] objectForKey:@"CRPHQGainEnabled"]) gainOn=YES;
    [a addAction:[UIAlertAction actionWithTitle:gainOn?@"إيقاف تضخيم الصوت":@"تفعيل تضخيم الصوت (مستحسن)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [[self prefs] setBool:!gainOn forKey:@"CRPHQGainEnabled"]; [[self prefs] synchronize]; [self.tableView reloadData]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"فتح مجلد التسجيلات في Filza" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ NSString *primary=[self candidateDirectories].firstObject?:@"/var/mobile/Library/CallRecordings"; UIPasteboard.generalPasteboard.string=primary; UIAlertController *c=[UIAlertController alertControllerWithTitle:@"تم النسخ" message:primary preferredStyle:UIAlertControllerStyleAlert]; [c addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:c animated:YES completion:nil]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"حذف جميع التسجيلات" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){ UIAlertController *confirm=[UIAlertController alertControllerWithTitle:@"حذف الكل؟" message:@"سيتم حذف جميع ملفات التسجيل نهائياً" preferredStyle:UIAlertControllerStyleAlert]; [confirm addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]]; [confirm addAction:[UIAlertAction actionWithTitle:@"حذف الكل" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *y){ for (CRPRecordingItem *it in self.recordings) [[NSFileManager defaultManager] removeItemAtPath:it.filePath error:nil]; [self loadRecordings]; [self hidePlayer]; }]]; [self presentViewController:confirm animated:YES completion:nil]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"نصائح للحصول على صوت نقي" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ UIAlertController *tips=[UIAlertController alertControllerWithTitle:@"نصائح" message:@"1. لا تحتاج لفتح السبيكر — التسجيل يلتقط الطرفين مباشرة.\n2. تأكد من تفعيل الحقن لـ audiomxd و mediaserverd و callservicesd في RootHide Manager ثم أعد تشغيل المستخدم.\n3. بعد التثبيت، افعل إعادة تشغيل المستخدم.\n4. تسجيل بلا صوت (19MB صمت) يعني الخدمات لم تكن نشطة — انظر التشخيص." preferredStyle:UIAlertControllerStyleAlert]; [tips addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:tips animated:YES completion:nil]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"إغلاق" style:UIAlertActionStyleCancel handler:nil]];
    if (a.popoverPresentationController) { a.popoverPresentationController.sourceView=self.view; a.popoverPresentationController.sourceRect=CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 1, 1); }
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - التشغيل
- (void)stopPlayback { if (self.progressTimer) { [self.progressTimer invalidate]; self.progressTimer=nil; } if (self.audioPlayer.isPlaying) [self.audioPlayer stop]; self.audioPlayer=nil; self.currentlyPlayingPath=nil; [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil]; [self.playPauseBtn setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal]; [self.tableView reloadData]; }
- (void)hidePlayer { [UIView animateWithDuration:0.25 animations:^{ self.playerBar.alpha=0; } completion:^(BOOL f){ self.playerBar.hidden=YES; self.playerBar.alpha=1; [self.view setNeedsLayout]; }]; [self stopPlayback]; }
- (void)showPlayerForItem:(CRPRecordingItem *)item {
    self.playerBar.hidden=NO; [self.view bringSubviewToFront:self.playerBar];
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
    if (!self.audioPlayer || err) { UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"خطأ في التشغيل" message:err.localizedDescription?:@"تعذر تشغيل التسجيل" preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:alert animated:YES completion:nil]; return; }
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

#pragma mark - الجدول
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { if (section==0) return 2; return (NSInteger)self.recordings.count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section { return section==0?@"الإعدادات": (self.recordings.count>0?[NSString stringWithFormat:@"التسجيلات (%lu)",(unsigned long)self.recordings.count]:@"لا توجد تسجيلات بعد"); }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section==0) return @"التسجيل يعمل بدون سبيكر. فعّل الحقن لـ audiomxd و mediaserverd و callservicesd في RootHide Manager.";
    NSString *primary=[self candidateDirectories].firstObject?:@"/var/mobile/Library/CallRecordings";
    NSString *daemonState=self.pongCount>0?[NSString stringWithFormat:@"الخدمات نشطة (%ld) ✅",(long)self.pongCount]:@"الخدمات: انتظار";
    return [NSString stringWithFormat:@"%@\nاضغط للتشغيل • اسحب لليسار للحذف/المشاركة • اضغط مطولاً لإعادة التسمية\n%@", daemonState, primary];
}
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return ip.section==0?44:66; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section==0) {
        static NSString *sid=@"SettingsCell"; UITableViewCell *cell=[tv dequeueReusableCellWithIdentifier:sid]; if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:sid];
        cell.accessoryType=UITableViewCellAccessoryNone; cell.selectionStyle=UITableViewCellSelectionStyleNone;
        if (ip.row==0) {
            cell.textLabel.text=@"تضخيم الصوت (AGC)"; cell.imageView.image=[UIImage systemImageNamed:@"waveform.path.badge.plus"]; cell.imageView.tintColor=[UIColor systemBlueColor];
            UISwitch *sw=[[UISwitch alloc] init]; sw.on=[[self prefs] boolForKey:@"CRPHQGainEnabled"]; if (![[self prefs] objectForKey:@"CRPHQGainEnabled"]) sw.on=YES; sw.onTintColor=[UIColor systemBlueColor]; [sw addTarget:self action:@selector(gainSwitchChanged:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView=sw;
            cell.detailTextLabel.text=sw.isOn?@"مفعل":@"متوقف";
        } else {
            cell.textLabel.text=@"جودة التسجيل"; cell.imageView.image=[UIImage systemImageNamed:@"music.note"]; cell.imageView.tintColor=[UIColor systemPurpleColor]; cell.detailTextLabel.text=@"HQ • 48kHz"; cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator; cell.accessoryView=nil;
        }
        return cell;
    }
    static NSString *kCell=@"Cell";
    UITableViewCell *cell=[tv dequeueReusableCellWithIdentifier:kCell]; if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kCell];
    CRPRecordingItem *item=self.recordings[ip.row]; BOOL isPlaying=[self.currentlyPlayingPath isEqualToString:item.filePath] && self.audioPlayer.isPlaying;
    cell.imageView.image=isPlaying?[UIImage systemImageNamed:@"waveform"]:[UIImage systemImageNamed:@"phone.fill"]; cell.imageView.tintColor=isPlaying?[UIColor systemBlueColor]:[UIColor systemGreenColor];
    NSString *title=item.displayName ?: item.fileName;
    cell.textLabel.text= isPlaying? [NSString stringWithFormat:@"⏸ %@", title] : [NSString stringWithFormat:@"▶ %@", title];
    cell.textLabel.font=[UIFont systemFontOfSize:13 weight:isPlaying?UIFontWeightBold:UIFontWeightSemibold]; cell.textLabel.textColor=isPlaying?[UIColor systemBlueColor]:[UIColor labelColor];
    NSDateFormatter *df=[[NSDateFormatter alloc] init]; df.dateStyle=NSDateFormatterShortStyle; df.timeStyle=NSDateFormatterShortStyle;
    NSString *dateStr=[df stringFromDate:item.creationDate];
    cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ • %@ • %@", dateStr, [self formattedDuration:item.duration], [self formattedSize:item.fileSize]];
    cell.detailTextLabel.textColor=[UIColor secondaryLabelColor]; cell.detailTextLabel.font=[UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    return cell;
}
- (void)gainSwitchChanged:(UISwitch *)sw { [[self prefs] setBool:sw.isOn forKey:@"CRPHQGainEnabled"]; [[self prefs] synchronize]; CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.relaxin.callrecorder/prefsChanged"), NULL, NULL, true); [self.tableView reloadData]; }
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip { [tv deselectRowAtIndexPath:ip animated:YES]; if (ip.section==0) { if (ip.row==1) [self showSettings]; return; } CRPRecordingItem *item=self.recordings[ip.row]; [self playRecordingAtPath:item.filePath item:item]; }
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section==1; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip { return ip.section==1?UITableViewCellEditingStyleDelete:UITableViewCellEditingStyleNone; }
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip { if (style==UITableViewCellEditingStyleDelete && ip.section==1) [self deleteRecordingAtIndexPath:ip inTableView:tv]; }
- (void)deleteRecordingAtIndexPath:(NSIndexPath *)ip inTableView:(UITableView *)tv { if (ip.section!=1 || ip.row<0 || ip.row>=(NSInteger)self.recordings.count) return; CRPRecordingItem *item=self.recordings[ip.row]; if ([self.currentlyPlayingPath isEqualToString:item.filePath]) [self hidePlayer]; [[NSFileManager defaultManager] removeItemAtPath:item.filePath error:nil]; NSString *json=[[item.filePath stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"]; [[NSFileManager defaultManager] removeItemAtPath:json error:nil]; [self.recordings removeObjectAtIndex:ip.row]; [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic]; [self updateHeader]; [tv reloadData]; }
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section!=1) return nil; __weak typeof(self) weakSelf=self;
    UIContextualAction *del=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"حذف" handler:^(UIContextualAction *a, UIView *v, void(^c)(BOOL)){ [weakSelf deleteRecordingAtIndexPath:ip inTableView:tv]; c(YES); }]; del.image=[UIImage systemImageNamed:@"trash"];
    UIContextualAction *share=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"مشاركة" handler:^(UIContextualAction *a, UIView *v, void(^c)(BOOL)){ CRPRecordingItem *item=weakSelf.recordings[ip.row]; NSURL *url=[NSURL fileURLWithPath:item.filePath]; UIActivityViewController *vc=[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil]; if (vc.popoverPresentationController) { vc.popoverPresentationController.sourceView=v; vc.popoverPresentationController.sourceRect=v.bounds; } [weakSelf presentViewController:vc animated:YES completion:nil]; c(YES); }]; share.backgroundColor=[UIColor systemBlueColor]; share.image=[UIImage systemImageNamed:@"square.and.arrow.up"];
    UIContextualAction *rename=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"إعادة تسمية" handler:^(UIContextualAction *a, UIView *v, void(^c)(BOOL)){ [weakSelf renameRecordingAtIndexPath:ip]; c(YES); }]; rename.backgroundColor=[UIColor systemOrangeColor]; rename.image=[UIImage systemImageNamed:@"pencil"];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, share, rename]];
}
- (void)renameRecordingAtIndexPath:(NSIndexPath *)ip { if (ip.section!=1) return; CRPRecordingItem *item=self.recordings[ip.row]; UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"إعادة تسمية التسجيل" message:item.fileName preferredStyle:UIAlertControllerStyleAlert]; [alert addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.text=[item.fileName stringByDeletingPathExtension]; tf.placeholder=@"اسم جديد"; }]; [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]]; [alert addAction:[UIAlertAction actionWithTitle:@"تأكيد" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ NSString *newName=[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]; if (newName.length==0) return; if (![newName.pathExtension.lowercaseString isEqualToString:@"wav"]) newName=[newName stringByAppendingPathExtension:@"wav"]; NSString *newPath=[[item.filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:newName]; NSError *err=nil; [[NSFileManager defaultManager] moveItemAtPath:item.filePath toPath:newPath error:&err]; if (!err) { NSString *oldJson=[[item.filePath stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"]; if ([[NSFileManager defaultManager] fileExistsAtPath:oldJson]) { NSString *newJson=[[newPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"]; [[NSFileManager defaultManager] moveItemAtPath:oldJson toPath:newJson error:nil]; } [self loadRecordings]; } }]]; [self presentViewController:alert animated:YES completion:nil]; }
@end
