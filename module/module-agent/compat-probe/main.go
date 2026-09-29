package main

import (
	"fmt"
	"runtime"
	"time"
)

// 兼容探针验证 Go 运行时和系统时钟路径，不访问模块硬件或网络状态。
func main() {
	fmt.Printf("runtime-ok go=%s os=%s arch=%s\n", runtime.Version(), runtime.GOOS, runtime.GOARCH)
	// QDC507 使用 Linux 3.18，单独验证 time.Now 以排查旧 ARM vDSO 兼容性。
	fmt.Printf("time-ok unix_nano=%d\n", time.Now().UnixNano())
}
