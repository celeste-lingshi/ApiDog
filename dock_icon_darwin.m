#import <AppKit/AppKit.h>
#import <dispatch/dispatch.h>

void apidogRestoreDockIcon(void) {
    // 程序坞图标须在 macOS 的界面线程更新。
    dispatch_async(dispatch_get_main_queue(), ^{
        NSImage *icon = [NSBundle.mainBundle imageForResource:@"ApiDog"];
        if (icon != nil) {
            NSApp.applicationIconImage = icon;
        }
    });
}
