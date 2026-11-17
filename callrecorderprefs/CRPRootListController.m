#import "CRPRootListController.h"
#include <roothide.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#import <QuartzCore/QuartzCore.h>

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
@property (nonatomic, strong) UIView *headerContainer;
@end

static __weak CRPRootListController *gWeakPrefsController=nil;
static void CRPPrefsPongCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    CRPRootListController *ctrl=gWeakPrefsController;
    if (ctrl) dispatch_async(dispatch_get_main_queue(), ^{ ctrl.pongCount+=1; [ctrl.tableView performSelectorOnMainThread:@selector(reloadData) withObject:nil waitUntilDone:NO]; });
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

#pragma mark - View

- (void)loadView {
    [super loadView];
    self.view.backgroundColor=[UIColor systemGroupedBackgroundColor];
    self.view.semanticContentAttribute=UISemanticContentAttributeForceRightToLeft;

    UITableView *tv=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    tv.translatesAutoresizingMaskIntoConstraints=NO;
    tv.delegate=self; tv.dataSource=self; tv.allowsSelection=YES;
    tv.estimatedRowHeight=64; tv.rowHeight=UITableViewAutomaticDimension;
    tv.sectionHeaderHeight=UITableViewAutomaticDimension; tv.estimatedSectionHeaderHeight=32;
    tv.sectionFooterHeight=UITableViewAutomaticDimension; tv.estimatedSectionFooterHeight=28;
    tv.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;
    tv.semanticContentAttribute=UISemanticContentAttributeForceRightToLeft;
    [self.view addSubview:tv];
    self.tableView=tv;
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    // Empty view
    UIView *ev=[[UIView alloc] init]; ev.hidden=YES; ev.translatesAutoresizingMaskIntoConstraints=NO;
    UIImageView *evIcon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"phone.badge.checkmark"]];
    evIcon.tintColor=[UIColor systemGray2Color]; evIcon.translatesAutoresizingMaskIntoConstraints=NO; evIcon.contentMode=UIViewContentModeScaleAspectFit;
    evIcon.preferredSymbolConfiguration=[UIImageSymbolConfiguration configurationWithPointSize:56 weight:UIImageSymbolWeightUltraLight];
    UILabel *evTitle=[[UILabel alloc] init]; evTitle.text=@"لا توجد تسجيلات بعد"; evTitle.font=[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; evTitle.textColor=[UIColor secondaryLabelColor]; evTitle.textAlignment=NSTextAlignmentCenter; evTitle.translatesAutoresizingMaskIntoConstraints=NO;
    UILabel *evSub=[[UILabel alloc] init]; evSub.text=@"ابدأ مكالمة واضغط زر التسجيل الأحمر\nداخل شاشة المكالمة"; evSub.font=[UIFont systemFontOfSize:13 weight:UIFontWeightRegular]; evSub.textColor=[UIColor tertiaryLabelColor]; evSub.textAlignment=NSTextAlignmentCenter; evSub.numberOfLines=0; evSub.translatesAutoresizingMaskIntoConstraints=NO;
    [ev addSubview:evIcon]; [ev addSubview:evTitle]; [ev addSubview:evSub];
    [NSLayoutConstraint activateConstraints:@[
        [evIcon.centerXAnchor constraintEqualToAnchor:ev.centerXAnchor], [evIcon.topAnchor constraintEqualToAnchor:ev.topAnchor constant:40], [evIcon.widthAnchor constraintEqualToConstant:72], [evIcon.heightAnchor constraintEqualToConstant:72],
        [evTitle.topAnchor constraintEqualToAnchor:evIcon.bottomAnchor constant:16], [evTitle.leadingAnchor constraintEqualToAnchor:ev.leadingAnchor constant:24], [evTitle.trailingAnchor constraintEqualToAnchor:ev.trailingAnchor constant:-24],
        [evSub.topAnchor constraintEqualToAnchor:evTitle.bottomAnchor constant:8], [evSub.leadingAnchor constraintEqualToAnchor:ev.leadingAnchor constant:32], [evSub.trailingAnchor constraintEqualToAnchor:ev.trailingAnchor constant:-32], [evSub.bottomAnchor constraintEqualToAnchor:ev.bottomAnchor constant:-16],
    ]];
    self.emptyView=ev;

    // Player bar – ultra clean
    UIVisualEffect *effect=[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    UIVisualEffectView *bar=[[UIVisualEffectView alloc] initWithEffect:effect];
    bar.translatesAutoresizingMaskIntoConstraints=NO; bar.hidden=YES; bar.alpha=0;
    bar.layer.cornerRadius=18; bar.layer.maskedCorners=kCALayerMinXMinYCorner|kCALayerMaxXMinYCorner; bar.clipsToBounds=YES;
    bar.layer.shadowColor=[UIColor blackColor].CGColor; bar.layer.shadowOpacity=0.12; bar.layer.shadowRadius=14; bar.layer.shadowOffset=CGSizeMake(0,-4);
    [self.view addSubview:bar]; self.playerBar=bar;

    UIView *content=bar.contentView; content.translatesAutoresizingMaskIntoConstraints=NO;

    UILabel *nowLabel=[[UILabel alloc] init]; nowLabel.translatesAutoresizingMaskIntoConstraints=NO; nowLabel.font=[UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold]; nowLabel.textColor=[UIColor labelColor]; nowLabel.textAlignment=NSTextAlignmentCenter; nowLabel.text=@"لم يتم اختيار تسجيل"; nowLabel.numberOfLines=1; nowLabel.lineBreakMode=NSLineBreakByTruncatingMiddle;
    UISlider *slider=[[UISlider alloc] init]; slider.translatesAutoresizingMaskIntoConstraints=NO; slider.minimumTrackTintColor=[UIColor systemBlueColor]; slider.maximumTrackTintColor=[UIColor systemFillColor]; slider.thumbTintColor=[UIColor systemBlueColor];
    [slider addTarget:self action:@selector(sliderDragging:) forControlEvents:UIControlEventValueChanged];
    [slider addTarget:self action:@selector(sliderReleased:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
    UILabel *cur=[[UILabel alloc] init]; cur.translatesAutoresizingMaskIntoConstraints=NO; cur.font=[UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium]; cur.textColor=[UIColor secondaryLabelColor]; cur.text=@"00:00"; cur.textAlignment=NSTextAlignmentRight;
    UILabel *dur=[[UILabel alloc] init]; dur.translatesAutoresizingMaskIntoConstraints=NO; dur.font=[UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium]; dur.textColor=[UIColor secondaryLabelColor]; dur.textAlignment=NSTextAlignmentLeft; dur.text=@"00:00";
    UIButton *playBtn=[UIButton buttonWithType:UIButtonTypeSystem]; playBtn.translatesAutoresizingMaskIntoConstraints=NO; playBtn.backgroundColor=[UIColor systemBlueColor]; playBtn.tintColor=[UIColor whiteColor]; playBtn.layer.cornerRadius=22; playBtn.layer.shadowColor=[UIColor systemBlueColor].CGColor; playBtn.layer.shadowOpacity=0.25; playBtn.layer.shadowRadius=6; playBtn.layer.shadowOffset=CGSizeMake(0,3);
    [playBtn setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal]; [playBtn addTarget:self action:@selector(togglePlayPause) forControlEvents:UIControlEventTouchUpInside];
    UIButton *share=[UIButton buttonWithType:UIButtonTypeSystem]; share.translatesAutoresizingMaskIntoConstraints=NO; share.tintColor=[UIColor secondaryLabelColor]; [share setImage:[UIImage systemImageNamed:@"square.and.arrow.up" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightMedium]] forState:UIControlStateNormal]; share.backgroundColor=[UIColor tertiarySystemFillColor]; share.layer.cornerRadius=16; [share addTarget:self action:@selector(playerShareTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *del=[UIButton buttonWithType:UIButtonTypeSystem]; del.translatesAutoresizingMaskIntoConstraints=NO; del.tintColor=[UIColor systemRedColor]; [del setImage:[UIImage systemImageNamed:@"trash" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightMedium]] forState:UIControlStateNormal]; del.backgroundColor=[UIColor systemRedColor].colorWithAlphaComponent?[[UIColor systemRedColor] colorWithAlphaComponent:0.10]:[UIColor tertiarySystemFillColor]; del.layer.cornerRadius=16; [del addTarget:self action:@selector(playerDeleteTapped) forControlEvents:UIControlEventTouchUpInside];

    [content addSubview:nowLabel]; [content addSubview:slider]; [content addSubview:cur]; [content addSubview:dur]; [content addSubview:playBtn]; [content addSubview:share]; [content addSubview:del];
    self.nowPlayingLabel=nowLabel; self.progressSlider=slider; self.currentTimeLabel=cur; self.durationLabel=dur; self.playPauseBtn=playBtn;

    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [bar.heightAnchor constraintEqualToConstant:122],

        [nowLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [nowLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [nowLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],

        [slider.topAnchor constraintEqualToAnchor:nowLabel.bottomAnchor constant:8],
        [slider.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:56],
        [slider.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-56],
        [slider.heightAnchor constraintEqualToConstant:20],

        [cur.centerYAnchor constraintEqualToAnchor:slider.centerYAnchor],
        [cur.trailingAnchor constraintEqualToAnchor:slider.leadingAnchor constant:-8],
        [cur.widthAnchor constraintEqualToConstant:38],

        [dur.centerYAnchor constraintEqualToAnchor:slider.centerYAnchor],
        [dur.leadingAnchor constraintEqualToAnchor:slider.trailingAnchor constant:8],
        [dur.widthAnchor constraintEqualToConstant:38],

        [playBtn.topAnchor constraintEqualToAnchor:slider.bottomAnchor constant:10],
        [playBtn.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [playBtn.widthAnchor constraintEqualToConstant:44], [playBtn.heightAnchor constraintEqualToConstant:44],

        [share.centerYAnchor constraintEqualToAnchor:playBtn.centerYAnchor],
        [share.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:22],
        [share.widthAnchor constraintEqualToConstant:38], [share.heightAnchor constraintEqualToConstant:38],

        [del.centerYAnchor constraintEqualToAnchor:playBtn.centerYAnchor],
        [del.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-22],
        [del.widthAnchor constraintEqualToConstant:38], [del.heightAnchor constraintEqualToConstant:38],
    ]];
}

// Build header with Auto Layout – fixes broken frame layout in screenshot
- (UIView *)buildHeaderView {
    UIView *container=[[UIView alloc] init];
    container.backgroundColor=[UIColor clearColor];
    container.preservesSuperviewLayoutMargins=NO;

    // Card
    UIView *card=[[UIView alloc] init]; card.translatesAutoresizingMaskIntoConstraints=NO;
    card.backgroundColor=[UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius=18; card.layer.cornerCurve=kCACornerCurveContinuous;
    card.layer.shadowColor=[UIColor blackColor].CGColor; card.layer.shadowOpacity=0.07; card.layer.shadowRadius=12; card.layer.shadowOffset=CGSizeMake(0,5);
    card.layer.masksToBounds=NO;
    [container addSubview:card];

    // Top row: icon + texts + pill
    UIImageView *icon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"waveform.circle.fill"]];
    icon.translatesAutoresizingMaskIntoConstraints=NO; icon.tintColor=[UIColor systemBlueColor]; icon.contentMode=UIViewContentModeScaleAspectFit;
    icon.preferredSymbolConfiguration=[UIImageSymbolConfiguration configurationWithPointSize:32 weight:UIImageSymbolWeightRegular];
    icon.layer.shadowColor=[UIColor systemBlueColor].CGColor; icon.layer.shadowOpacity=0.18; icon.layer.shadowRadius=8;

    UILabel *title=[[UILabel alloc] init]; title.translatesAutoresizingMaskIntoConstraints=NO;
    title.text=@"مسجل المكالمات"; title.font=[UIFont systemFontOfSize:18 weight:UIFontWeightBold]; title.textColor=[UIColor labelColor]; title.textAlignment=NSTextAlignmentRight;
    UILabel *subtitle=[[UILabel alloc] init]; subtitle.translatesAutoresizingMaskIntoConstraints=NO;
    subtitle.text=@"تسجيل نقي — بدون سبيكر • يعمل تلقائياً"; subtitle.font=[UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium]; subtitle.textColor=[UIColor secondaryLabelColor]; subtitle.textAlignment=NSTextAlignmentRight; subtitle.numberOfLines=1;

    UIStackView *textStack=[[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    textStack.translatesAutoresizingMaskIntoConstraints=NO; textStack.axis=UILayoutConstraintAxisVertical; textStack.spacing=2; textStack.alignment=UIStackViewAlignmentTrailing;

    // Pill
    BOOL active=self.pongCount>0;
    UIColor *pillColor= active ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
    NSString *pillText= active ? @"نشط" : @"بانتظار الخدمة";
    UIView *pill=[[UIView alloc] init]; pill.translatesAutoresizingMaskIntoConstraints=NO;
    pill.backgroundColor=[pillColor colorWithAlphaComponent:0.13]; pill.layer.cornerRadius=11; pill.clipsToBounds=YES;
    UIView *dot=[[UIView alloc] init]; dot.translatesAutoresizingMaskIntoConstraints=NO; dot.backgroundColor=pillColor; dot.layer.cornerRadius=4;
    UILabel *pillLab=[[UILabel alloc] init]; pillLab.translatesAutoresizingMaskIntoConstraints=NO; pillLab.text=pillText; pillLab.font=[UIFont systemFontOfSize:11 weight:UIFontWeightBold]; pillLab.textColor=pillColor; pillLab.textAlignment=NSTextAlignmentCenter;
    [pill addSubview:dot]; [pill addSubview:pillLab];
    [NSLayoutConstraint activateConstraints:@[
        [pill.widthAnchor constraintGreaterThanOrEqualToConstant:78],
        [pill.heightAnchor constraintEqualToConstant:24],
        [dot.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:8],
        [dot.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
        [dot.widthAnchor constraintEqualToConstant:8], [dot.heightAnchor constraintEqualToConstant:8],
        [pillLab.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:5],
        [pillLab.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-8],
        [pillLab.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
    ]];
    if (!active) {
        CABasicAnimation *a=[CABasicAnimation animationWithKeyPath:@"opacity"]; a.fromValue=@1; a.toValue=@0.35; a.duration=1.0; a.autoreverses=YES; a.repeatCount=HUGE_VALF; a.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [dot.layer addAnimation:a forKey:@"pulse"];
    }

    UIStackView *topRow=[[UIStackView alloc] initWithArrangedSubviews:@[icon, textStack]];
    topRow.translatesAutoresizingMaskIntoConstraints=NO; topRow.axis=UILayoutConstraintAxisHorizontal; topRow.spacing=10; topRow.alignment=UIStackViewAlignmentCenter;
    // We need topRow + pill on same line: wrap in another stack
    UIStackView *headerRow=[[UIStackView alloc] initWithArrangedSubviews:@[topRow, pill]];
    headerRow.translatesAutoresizingMaskIntoConstraints=NO; headerRow.axis=UILayoutConstraintAxisHorizontal; headerRow.spacing=8; headerRow.alignment=UIStackViewAlignmentCenter; headerRow.distribution=UIStackViewDistributionEqualSpacing;

    // Stats row
    NSUInteger totalCount=self.recordings.count; NSTimeInterval totalDur=0; unsigned long long totalSize=0;
    for (CRPRecordingItem *it in self.recordings) { totalDur+=it.duration; totalSize+=it.fileSize; }
    NSString *sizeStr;
    if (totalSize==0) sizeStr=@"—";
    else if (totalSize >= 1024*1024) sizeStr=[NSString stringWithFormat:@"%.1f MB", (double)totalSize/(1024.0*1024.0)];
    else sizeStr=[NSString stringWithFormat:@"%.0f KB", (double)totalSize/1024.0];
    NSString *durStr;
    if (totalDur < 1) durStr=@"—";
    else {
        NSInteger m=(NSInteger)(totalDur/60), s=(NSInteger)totalDur % 60, h=(NSInteger)(totalDur/3600);
        if (h>0) durStr=[NSString stringWithFormat:@"%ld:%02ld:%02ld",(long)h,(long)(m%60),(long)s];
        else durStr=[NSString stringWithFormat:@"%02ld:%02ld",(long)m,(long)s];
    }

    UIView *statsRow=[[UIView alloc] init]; statsRow.translatesAutoresizingMaskIntoConstraints=NO;
    UIStackView *statsStack=[[UIStackView alloc] init]; statsStack.translatesAutoresizingMaskIntoConstraints=NO; statsStack.axis=UILayoutConstraintAxisHorizontal; statsStack.distribution=UIStackViewDistributionFillEqually; statsStack.spacing=10;
    [statsRow addSubview:statsStack];
    [NSLayoutConstraint activateConstraints:@[
        [statsStack.topAnchor constraintEqualToAnchor:statsRow.topAnchor],
        [statsStack.bottomAnchor constraintEqualToAnchor:statsRow.bottomAnchor],
        [statsStack.leadingAnchor constraintEqualToAnchor:statsRow.leadingAnchor],
        [statsStack.trailingAnchor constraintEqualToAnchor:statsRow.trailingAnchor],
        [statsRow.heightAnchor constraintEqualToConstant:64],
    ]];

    NSArray *stats=@[
        @{@"v": [NSString stringWithFormat:@"%lu",(unsigned long)totalCount], @"l": @"التسجيلات", @"ico": @"waveform.badge.magnifyingglass"},
        @{@"v": durStr, @"l": @"المدة", @"ico": @"clock"},
        @{@"v": sizeStr, @"l": @"الحجم", @"ico": @"internaldrive"},
    ];
    for (int i=0;i<3;i++) {
        UIView *box=[[UIView alloc] init]; box.backgroundColor=[UIColor tertiarySystemGroupedBackgroundColor]; box.layer.cornerRadius=13; box.layer.cornerCurve=kCACornerCurveContinuous; box.clipsToBounds=YES;
        UIImageView *iv=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:stats[i][@"ico"]]];
        iv.translatesAutoresizingMaskIntoConstraints=NO; iv.tintColor=[UIColor systemBlueColor]; iv.contentMode=UIViewContentModeScaleAspectFit;
        iv.preferredSymbolConfiguration=[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightMedium];
        UILabel *v=[[UILabel alloc] init]; v.translatesAutoresizingMaskIntoConstraints=NO; v.text=stats[i][@"v"]; v.font=[UIFont systemFontOfSize:15 weight:UIFontWeightBold]; v.textAlignment=NSTextAlignmentCenter; v.textColor=[UIColor labelColor]; v.adjustsFontSizeToFitWidth=YES; v.minimumScaleFactor=0.6;
        UILabel *l=[[UILabel alloc] init]; l.translatesAutoresizingMaskIntoConstraints=NO; l.text=stats[i][@"l"]; l.font=[UIFont systemFontOfSize:10 weight:UIFontWeightMedium]; l.textAlignment=NSTextAlignmentCenter; l.textColor=[UIColor secondaryLabelColor];
        [box addSubview:iv]; [box addSubview:v]; [box addSubview:l];
        [NSLayoutConstraint activateConstraints:@[
            [iv.topAnchor constraintEqualToAnchor:box.topAnchor constant:7],
            [iv.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
            [iv.widthAnchor constraintEqualToConstant:16], [iv.heightAnchor constraintEqualToConstant:16],
            [v.topAnchor constraintEqualToAnchor:iv.bottomAnchor constant:3],
            [v.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:4],
            [v.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-4],
            [l.topAnchor constraintEqualToAnchor:v.bottomAnchor constant:1],
            [l.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:2],
            [l.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-2],
        ]];
        [statsStack addArrangedSubview:box];
    }

    // Assemble card content
    UIStackView *cardStack=[[UIStackView alloc] initWithArrangedSubviews:@[headerRow, statsRow]];
    cardStack.translatesAutoresizingMaskIntoConstraints=NO; cardStack.axis=UILayoutConstraintAxisVertical; cardStack.spacing=14;
    [card addSubview:cardStack];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:container.topAnchor constant:12],
        [card.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [card.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-10],

        [cardStack.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [cardStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [cardStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [cardStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],

        [icon.widthAnchor constraintEqualToConstant:34], [icon.heightAnchor constraintEqualToConstant:34],
    ]];

    CGSize fitting=[container systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    if (fitting.height < 120) fitting.height=138;
    container.frame=CGRectMake(0,0, self.tableView ? self.tableView.bounds.size.width : 390, fitting.height);

    // Ensure RTL
    container.semanticContentAttribute=UISemanticContentAttributeForceRightToLeft;
    card.semanticContentAttribute=UISemanticContentAttributeForceRightToLeft;

    return container;
}

// Helper to refresh header with auto-layout sizing
- (void)refreshHeader {
    UIView *hdr=[self buildHeaderView];
    // Use auto layout height: calculate via systemLayoutSizeFitting
    CGFloat w = self.tableView.bounds.size.width;
    if (w < 200) {
        UIWindow *win = self.view.window;
        if (!win) win = UIApplication.sharedApplication.keyWindow;
        w = win ? win.bounds.size.width : 390;
    }
    hdr.frame=CGRectMake(0,0,w, hdr.frame.size.height);
    // Force layout to get correct height
    [hdr setNeedsLayout]; [hdr layoutIfNeeded];
    CGSize sz=[hdr systemLayoutSizeFittingSize:CGSizeMake(w, UILayoutFittingCompressedSize.height) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    if (sz.height < 100) sz.height=140;
    CGRect f=hdr.frame; f.size.height=sz.height; f.size.width=w; hdr.frame=f;
    self.tableView.tableHeaderView=hdr;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"مسجل المكالمات";
    if (@available(iOS 11.0, *)) {
        self.navigationController.navigationBar.prefersLargeTitles=YES;
        self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAlways;
    }
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
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; CGFloat inset = self.playerBar.hidden?0:122; self.tableView.contentInset=UIEdgeInsetsMake(0,0,inset,0); self.tableView.scrollIndicatorInsets=self.tableView.contentInset; // keep header width in sync
    if (self.headerContainer && fabs(self.headerContainer.frame.size.width - self.tableView.bounds.size.width) > 1) { [self refreshHeader]; }
}
- (void)traitCollectionDidChange:(UITraitCollection *)prev { [super traitCollectionDidChange:prev]; [self refreshHeader]; }

- (void)pingDaemons { self.pongCount=0; CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CRP_PREFS_PING_NOTIFICATION, NULL, NULL, true); dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.4*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{ [self.tableView reloadData]; [self refreshHeader]; }); }
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
    [self refreshHeader];
    [self.tableView reloadData];
    if (self.recordings.count==0) {
        self.tableView.backgroundView=self.emptyView; self.emptyView.hidden=NO;
    } else {
        self.tableView.backgroundView=nil; self.emptyView.hidden=YES;
    }
}

#pragma mark - Menus & Diagnostics

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
    NSMutableString *r=[NSMutableString string]; [r appendString:@"مسجل المكالمات v1.3.4 — Native Rate — تشخيص\n"];
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.45*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
        NSString *report=[self collectReport];
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"التشخيص" message:report preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"نسخ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [UIPasteboard generalPasteboard].string=report; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"مسح السجلات" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){ for (NSString *dir in [self candidateDirectories]) [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:@"diagnostics.log"] error:nil]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"إغلاق" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    });
}
- (void)showTips {
    UIAlertController *t=[UIAlertController alertControllerWithTitle:@"للحصول على صوت نقي" message:@"• لا تحتاج فتح السبيكر — التسجيل يلتقط الطرفين مباشرة\n• تأكد من تفعيل الحقن لـ audiomxd + mediaserverd + callservicesd في RootHide ثم Respring\n• بعد التثبيت اعمل Respring\n• الميك ON/OFF لم يعد يسبب تشويش — التسجيل يحفظ بالمعدل الأصلي بدون تسريع" preferredStyle:UIAlertControllerStyleAlert];
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

#pragma mark - Playback

- (void)stopPlayback { if (self.progressTimer) { [self.progressTimer invalidate]; self.progressTimer=nil; } if (self.audioPlayer.isPlaying) [self.audioPlayer stop]; self.audioPlayer=nil; self.currentlyPlayingPath=nil; [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil]; [self.playPauseBtn setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal]; [self.tableView reloadData]; }
- (void)hidePlayer { if (self.playerBar.hidden) return; [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{ self.playerBar.alpha=0; } completion:^(BOOL f){ self.playerBar.hidden=YES; self.playerBar.alpha=1; [self.view setNeedsLayout]; [self.view layoutIfNeeded]; }]; [self stopPlayback]; }
- (void)showPlayerForItem:(CRPRecordingItem *)item {
    self.playerBar.hidden=NO;
    self.nowPlayingLabel.text=[NSString stringWithFormat:@"%@ • %@", item.displayName ?: item.fileName, [self formattedDuration:item.duration]];
    self.durationLabel.text=[self formattedDuration:item.duration]; self.currentTimeLabel.text=@"00:00"; self.progressSlider.value=0;
    [self.view bringSubviewToFront:self.playerBar];
    [UIView animateWithDuration:0.28 animations:^{ self.playerBar.alpha=1; }];
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
- (NSString *)formattedSize:(unsigned long long)bytes { if (bytes>=1024*1024) return [NSString stringWithFormat:@"%.1f MB",(double)bytes/(1024.0*1024)]; return [NSString stringWithFormat:@"%.0f KB",(double)bytes/1024.0]; }
- (NSString *)formattedDuration:(NSTimeInterval)s { NSInteger t=(NSInteger)(s+0.5); if (t>=3600) return [NSString stringWithFormat:@"%02ld:%02ld:%02ld",(long)(t/3600),(long)((t%3600)/60),(long)(t%60)]; return [NSString stringWithFormat:@"%02ld:%02ld",(long)(t/60),(long)(t%60)]; }

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { if (section==0) return 2; return (NSInteger)self.recordings.count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section { return section==0?@"الإعدادات" : (self.recordings.count>0? [NSString stringWithFormat:@"التسجيلات — %lu",(unsigned long)self.recordings.count] : @"التسجيلات"); }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section==0) {
        NSString *primary=[self candidateDirectories].firstObject?:@"/var/mobile/Library/CallRecordings";
        return [NSString stringWithFormat:@"التخزين: %@\nاضغط مطولاً على المسار للنسخ — التسجيل يعمل بدون سبيكر", primary];
    }
    if (self.recordings.count==0) return nil;
    return @"اضغط للتشغيل • اسحب لليسار للحذف أو المشاركة • اضغط مطولاً لإعادة التسمية";
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section==0) {
        if (ip.row==0) {
            static NSString *sid=@"SettingsCell0"; UITableViewCell *cell=[tv dequeueReusableCellWithIdentifier:sid]; if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:sid];
            cell.textLabel.text=@"تحسين الصوت التلقائي"; cell.textLabel.font=[UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
            cell.imageView.image=[UIImage systemImageNamed:@"waveform.path.ecg"]; cell.imageView.tintColor=[UIColor systemBlueColor];
            UISwitch *sw=[[UISwitch alloc] init]; sw.on=[[self prefs] boolForKey:@"CRPHQGainEnabled"]; if (![[self prefs] objectForKey:@"CRPHQGainEnabled"]) sw.on=YES; sw.onTintColor=[UIColor systemBlueColor]; [sw addTarget:self action:@selector(gainSwitchChanged:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView=sw;
            cell.detailTextLabel.text=sw.isOn?@"مفعّل":@"متوقف"; cell.selectionStyle=UITableViewCellSelectionStyleNone;
            return cell;
        } else {
            static NSString *sid2=@"PathCell"; UITableViewCell *cell=[tv dequeueReusableCellWithIdentifier:sid2]; if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:sid2];
            NSString *primary=[self candidateDirectories].firstObject?:@"/var/mobile/Library/CallRecordings";
            cell.textLabel.text=@"مجلد التسجيلات"; cell.textLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]; cell.textLabel.textColor=[UIColor secondaryLabelColor];
            cell.detailTextLabel.text=primary; cell.detailTextLabel.font=[UIFont systemFontOfSize:11 weight:UIFontWeightRegular]; cell.detailTextLabel.textColor=[UIColor tertiaryLabelColor]; cell.detailTextLabel.numberOfLines=0; cell.detailTextLabel.lineBreakMode=NSLineBreakByCharWrapping;
            cell.imageView.image=[UIImage systemImageNamed:@"folder"]; cell.imageView.tintColor=[UIColor systemOrangeColor];
            cell.accessoryType=UITableViewCellAccessoryNone;
            cell.selectionStyle=UITableViewCellSelectionStyleDefault;
            return cell;
        }
    }
    static NSString *kCell=@"RecCell";
    UITableViewCell *cell=[tv dequeueReusableCellWithIdentifier:kCell]; if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kCell];
    CRPRecordingItem *item=self.recordings[ip.row]; BOOL isPlaying=[self.currentlyPlayingPath isEqualToString:item.filePath] && self.audioPlayer.isPlaying;
    cell.imageView.image=isPlaying?[UIImage systemImageNamed:@"waveform"]:[UIImage systemImageNamed:@"phone.fill"];
    cell.imageView.tintColor=isPlaying?[UIColor systemBlueColor]:[UIColor systemGreenColor];
    NSString *title=item.displayName ?: item.fileName;
    cell.textLabel.text= isPlaying? [NSString stringWithFormat:@"⏸ %@", title] : title;
    cell.textLabel.font=[UIFont systemFontOfSize:14 weight:isPlaying?UIFontWeightBold:UIFontWeightSemibold]; cell.textLabel.textColor=isPlaying?[UIColor systemBlueColor]:[UIColor labelColor]; cell.textLabel.numberOfLines=1;
    NSDateFormatter *df=[[NSDateFormatter alloc] init]; df.dateStyle=NSDateFormatterShortStyle; df.timeStyle=NSDateFormatterShortStyle; df.locale=[NSLocale localeWithLocaleIdentifier:@"ar_IQ"];
    NSString *dateStr=[df stringFromDate:item.creationDate];
    cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ • %@ • %@", dateStr, [self formattedDuration:item.duration], [self formattedSize:item.fileSize]];
    cell.detailTextLabel.textColor=[UIColor secondaryLabelColor]; cell.detailTextLabel.font=[UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular]; cell.detailTextLabel.numberOfLines=1;
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)gainSwitchChanged:(UISwitch *)sw { [[self prefs] setBool:sw.isOn forKey:@"CRPHQGainEnabled"]; [[self prefs] synchronize]; CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.relaxin.callrecorder/prefsChanged"), NULL, NULL, true); [self.tableView reloadData]; }
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section==0) {
        if (ip.row==1) {
            NSString *primary=[self candidateDirectories].firstObject?:@"/var/mobile/Library/CallRecordings";
            UIPasteboard.generalPasteboard.string=primary;
            UIAlertController *c=[UIAlertController alertControllerWithTitle:@"تم نسخ المسار" message:primary preferredStyle:UIAlertControllerStyleAlert];
            [c addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:c animated:YES completion:nil];
        }
        return;
    }
    CRPRecordingItem *item=self.recordings[ip.row]; [self playRecordingAtPath:item.filePath item:item];
}
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section==1; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip { return ip.section==1?UITableViewCellEditingStyleDelete:UITableViewCellEditingStyleNone; }
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip { if (style==UITableViewCellEditingStyleDelete && ip.section==1) [self deleteRecordingAtIndexPath:ip inTableView:tv]; }
- (void)deleteRecordingAtIndexPath:(NSIndexPath *)ip inTableView:(UITableView *)tv { if (ip.section!=1 || ip.row<0 || ip.row>=(NSInteger)self.recordings.count) return; CRPRecordingItem *item=self.recordings[ip.row]; if ([self.currentlyPlayingPath isEqualToString:item.filePath]) [self hidePlayer]; [[NSFileManager defaultManager] removeItemAtPath:item.filePath error:nil]; NSString *json=[[item.filePath stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"]; [[NSFileManager defaultManager] removeItemAtPath:json error:nil]; [self.recordings removeObjectAtIndex:ip.row]; [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic]; [self refreshHeader]; if (self.recordings.count==0) { self.tableView.backgroundView=self.emptyView; self.emptyView.hidden=NO; } }
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section!=1) return nil; __weak typeof(self) weakSelf=self;
    UIContextualAction *del=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"حذف" handler:^(UIContextualAction *a, UIView *v, void(^c)(BOOL)){ [weakSelf deleteRecordingAtIndexPath:ip inTableView:tv]; c(YES); }]; del.image=[UIImage systemImageNamed:@"trash"];
    UIContextualAction *share=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"مشاركة" handler:^(UIContextualAction *a, UIView *v, void(^c)(BOOL)){ CRPRecordingItem *item=weakSelf.recordings[ip.row]; NSURL *url=[NSURL fileURLWithPath:item.filePath]; UIActivityViewController *vc=[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil]; if (vc.popoverPresentationController) { vc.popoverPresentationController.sourceView=v; vc.popoverPresentationController.sourceRect=v.bounds; } [weakSelf presentViewController:vc animated:YES completion:nil]; c(YES); }]; share.backgroundColor=[UIColor systemBlueColor]; share.image=[UIImage systemImageNamed:@"square.and.arrow.up"];
    UIContextualAction *rename=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"إعادة تسمية" handler:^(UIContextualAction *a, UIView *v, void(^c)(BOOL)){ [weakSelf renameRecordingAtIndexPath:ip]; c(YES); }]; rename.backgroundColor=[UIColor systemOrangeColor]; rename.image=[UIImage systemImageNamed:@"pencil"];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, share, rename]];
}
- (void)renameRecordingAtIndexPath:(NSIndexPath *)ip { if (ip.section!=1) return; CRPRecordingItem *item=self.recordings[ip.row]; UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"إعادة تسمية" message:item.fileName preferredStyle:UIAlertControllerStyleAlert]; [alert addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.text=[item.fileName stringByDeletingPathExtension]; tf.placeholder=@"الاسم الجديد"; }]; [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]]; [alert addAction:[UIAlertAction actionWithTitle:@"حفظ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ NSString *newName=[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]; if (newName.length==0) return; if (![newName.pathExtension.lowercaseString isEqualToString:@"wav"]) newName=[newName stringByAppendingPathExtension:@"wav"]; NSString *newPath=[[item.filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:newName]; NSError *err=nil; [[NSFileManager defaultManager] moveItemAtPath:item.filePath toPath:newPath error:&err]; if (!err) { NSString *oldJson=[[item.filePath stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"]; if ([[NSFileManager defaultManager] fileExistsAtPath:oldJson]) { NSString *newJson=[[newPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"]; [[NSFileManager defaultManager] moveItemAtPath:oldJson toPath:newJson error:nil]; } [self loadRecordings]; } }]]; [self presentViewController:alert animated:YES completion:nil]; }
@end
