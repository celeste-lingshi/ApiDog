package main

/*
// Wails 在 macOS 上的文件类型识别需要这个系统框架。
#cgo LDFLAGS: -framework UniformTypeIdentifiers -framework AppKit
void apidogRestoreDockIcon(void);
*/
import "C"

func restoreDockIcon() {
	C.apidogRestoreDockIcon()
}
