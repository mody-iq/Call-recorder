#import "CRPRootListController.h"
#include <roothide.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#define CRP_PREFS_PING_NOTIFICATION CFSTR("com.relaxin.callrecorder/ping")
#define CRP_PREFS_PONG_NOTIFICATION CFSTR("com.relaxin.callrecorder/pong")
#define CRP_SUITE @"com.relaxin.callrecorder"
static uint32_t CRPGetPayloadSize(NSString *path){return 0;}
@interface CRPRecordingItem : NSObject
@property (nonatomic, copy) NSString *fileName;@end
@implementation CRPRecordingItem @end
@interface CRPRootListController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *recordings;
@property (nonatomic, assign) NSInteger pongCount;
@end
static __weak CRPRootListController *gWeakPrefsController=nil;
static void CRPPrefsPongCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo){}
@implementation CRPRootListController
- (instancetype)init{self=[super init]; if(self){_recordings=[NSMutableArray array];}return self;}
- (NSArray<NSString *> *)candidateDirectories{return @[];}
- (void)loadView{[super loadView]; self.view.backgroundColor=[UIColor systemGroupedBackgroundColor]; UITableView *tv=[[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped]; tv.delegate=self; tv.dataSource=self; [self.view addSubview:tv]; self.tableView=tv;}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv{return 1;}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s{return 1;}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip{UITableViewCell *c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"c"]; c.textLabel.text=@"test"; return c;}
@end
