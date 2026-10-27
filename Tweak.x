// Doleo — 为 Sileo 增加"仅下载"与本地仓库功能
//
// 这里只负责把入口挂进 Sileo 的界面，业务逻辑全部在 Sources/*.swift 中。
// Swift 侧通过 @objc(DKBridge) 注册到运行时，这里用 objc_msgSend 调用，不需要桥接头文件。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static Class DKBridgeClass(void) {
    return NSClassFromString(@"DKBridge");
}

// 查找 Sileo 中的 Swift 类。先试 "Sileo.<Name>"，再扫描主程序里的类名，
// 兼容模块名不同的社区分支（运行时名可能是 "_TtC5Sileo21PackageViewController" 这类 mangled 形式）。
static Class DKFindSwiftClass(NSString *simpleName) {
    Class cls = NSClassFromString([@"Sileo." stringByAppendingString:simpleName]);
    if (cls) return cls;

    NSString *dotted = [@"." stringByAppendingString:simpleName];
    NSString *mangledSuffix = [NSString stringWithFormat:@"%lu%@", (unsigned long)simpleName.length, simpleName];
    const char *image = [[[NSBundle mainBundle] executablePath] fileSystemRepresentation];
    unsigned int count = 0;
    const char **names = objc_copyClassNamesForImage(image, &count);
    for (unsigned int i = 0; i < count && !cls; i++) {
        NSString *name = @(names[i]);
        if ([name hasSuffix:dotted] || ([name hasPrefix:@"_TtC"] && [name hasSuffix:mangledSuffix])) {
            cls = objc_getClass(names[i]);
        }
    }
    if (names) free(names);
    return cls;
}

%group PackageVCHooks
%hook DKPackageVC
- (void)viewDidLoad {
    %orig;
    Class bridge = DKBridgeClass();
    if (bridge) ((void (*)(id, SEL, UIViewController *))objc_msgSend)(bridge, @selector(installPackageButton:), self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    Class bridge = DKBridgeClass();
    if (bridge) ((void (*)(id, SEL, UIViewController *))objc_msgSend)(bridge, @selector(installPackageButton:), self);
}
%end
%end

%group PackageListHooks
%hook DKPackageListVC
- (void)viewDidLoad {
    %orig;
    Class bridge = DKBridgeClass();
    if (bridge) ((void (*)(id, SEL, UIViewController *))objc_msgSend)(bridge, @selector(installLibraryButton:), self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    Class bridge = DKBridgeClass();
    if (bridge) ((void (*)(id, SEL, UIViewController *))objc_msgSend)(bridge, @selector(installLibraryButton:), self);
}
%end
%end

%group PaymentSessionHooks
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion {
    Class bridge = DKBridgeClass();
    if (!bridge || !((BOOL (*)(id, SEL, NSURLRequest *))objc_msgSend)(bridge, @selector(shouldObservePaymentRequest:), request)) {
        return %orig;
    }
    NSURLRequest *snapshot = [request copy];
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        ((void (*)(id, SEL, NSURLRequest *, NSData *, NSURLResponse *, NSError *))objc_msgSend)(bridge,
            @selector(observePaymentRequest:data:response:error:), snapshot, data, response, error);
        if (completion) completion(data, response, error);
    };
    return %orig(request, wrapped);
}
%end
%end

%ctor {
    @autoreleasepool {
        %init(PaymentSessionHooks);
        Class packageVC = DKFindSwiftClass(@"PackageViewController");
        if (packageVC) {
            %init(PackageVCHooks, DKPackageVC = packageVC);
        } else {
            NSLog(@"[Doleo] 找不到 PackageViewController，此 Sileo 版本可能不兼容");
        }

        Class packageListVC = DKFindSwiftClass(@"PackageListViewController");
        if (packageListVC) {
            %init(PackageListHooks, DKPackageListVC = packageListVC);
        }

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            Class bridge = DKBridgeClass();
            if (bridge) ((void (*)(id, SEL))objc_msgSend)(bridge, @selector(didLaunch));
        }];

        // 装完/升级完回到 Sileo 时补存 DEB（不参与 APT 事务，只是事后扫描）
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            Class bridge = DKBridgeClass();
            if (bridge) ((void (*)(id, SEL))objc_msgSend)(bridge, @selector(didBecomeActive));
        }];
    }
}
