# F50 Wi-Fi 并发能力诊断工具

这些工具不参与正常构建、安装或自启动。只在所有者明确要求诊断时使用，先保留 USB ADB 恢复通道，确认当前没有通话或其他 Wi-Fi Direct 会话。正常酒店认证使用父目录服务。

## wiphy-capabilities.c

只发送 nl80211 查询，打印内核支持的接口类型和组合；不创建接口、不修改连接。可用 Android NDK 的 `aarch64-linux-android34-clang -Wall -Wextra -Werror` 编译，推送到设备临时目录后由 shell 运行。内核能力不代表 Android HAL 允许同样的组合，需结合 `cmd wifi query-interface 2000 com.android.shell DIRECT -new` 等实际接口查询判断。

## P2pProbe.java

独立的五分钟 Wi-Fi Direct Group Owner 试验，使用 shell 的系统上下文。需 SDK 35 的 android.jar 编译，再由 D8 转为 DEX，以 shell 的 app_process 运行。唯一参数是设备上权限 0600 的口令文件路径，文件内为所有者选定的临时 WPA2 口令；不要将口令放在命令行、源码或日志中。

工具拒绝已有 P2P 会话，不更改已保存的上游 Wi-Fi，创建固定测试名 `DIRECT-F5-ZTE-CN-Setup`。日志只输出组接口、是否为组主和客户端数量。正常到期会请求移除组，但意外杀死进程、系统重启或框架拒绝的清理结果仍须检查，不能将计时器存在当作已完成到期验收。

完成后删除本次临时 DEX、口令文件及二进制。不要在正式认证服务正在使用 P2P 热点时运行此工具。
