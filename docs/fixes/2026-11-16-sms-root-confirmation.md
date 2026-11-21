# 短信发送前回退与 Root 系统回执修复

2026-11-16；基于 develop / 991162c 和已有未提交短信修复。对应 `docs/reviews/2026-11-16-sms-unconfirmed-regression.md`，保留 ANCS 撤回及其他工作树改动。

## 行为

1. 没有 Root、Root 拒绝或探测超时：尚未提交短信，允许沿既有发送链回退。仅 Shizuku 继续跳过 Root。保留 RootSMSPreflight 的发送前探测及启动前/后的错误分类。
2. Root 发送不再以 API 返回作为系统发送成功。逐段收到系统成功回执才返回成功；已知系统失败显示失败原因；缺少回执、部分回执或中断保持未知，不切换链路重发。
3. 提交阶段抛异常或 helper 输出丢失时，App 继续等待原发送尝试的回执。迟到成功可以确认原尝试，重复回执不能把缺失分段凑成成功。
4. 关闭 Root PCM supervisor 的旧 `send_sms` 入口，返回明确的发送前不支持结果。ShizukuBridgeManager 不再通过 Root socket 二次尝试短信。Root 统一走独立短信 helper，不占用 PCM supervisor 等待回执。
5. 回执的 45 秒预算包含 helper 启动/提交等待；Root 前置探测最多 5 秒、helper 等待最多 20 秒，正常有界调用总预算约 50 秒，留在现有 VoBLE 60 秒请求时限内。阻塞系统调用和设备调度不承诺严格实时界限。

系统发送回执与收件方送达回执不同，参见 [Android SmsManager](https://developer.android.com/reference/android/telephony/SmsManager)。本补丁不将发送回执描述为送达确认。

## Root 回执协议

- App 在 PrivilegedSmsConfirmation 中创建不可变、单次使用的逐段 sent PendingIntent，注册非导出接收器。
- RootSMSCallbackProvider 在 App 进程内保存短期回执列表，使用随机单次 token。最多 16 条待领取项，60 秒到期；claim 后立即移除，发送器结束时撤销尚未领取 token。
- 新 provider 分别使用 `<APK package>.root-sms-callbacks` authority。虽然为 Root 外部进程导出，但 `call` 明确检查 Binder 调用 UID 必须为 0，且只支持领取回执，不支持发短信、执行命令或读取消息。App、shell、system UID 均拒绝，其他 CRUD 不开放。
- token、目标 Android user/profile 与原有载荷一起放在 App 私有临时文件中，不放进 shell 命令，不打印 token、号码、正文。
- Root helper 通过已有 getContentProviderExternal 机制获取 App provider，以 API 29 / 30 / 31+ 相应 Binder call 形状领取 PendingIntent。按 App UID 选择 user/profile；finally 释放 provider lease。
- helper 验证回执数量等于短信分段数、无 null，然后只调用一次发送 API。领取失败/过期/计数不一致发生在发送前，可以安全回退；发送 API 调用后异常属于未知。
- Root helper 不注册自己的动态接收器。裸 app_process 在系统中没有常规 App 进程记录，不能假定能可靠接收广播；真实回执始终到 App。helper 返回标记后显式退出，避免 Binder 线程使进程滞留到超时。

无需修改 iPhone、Relay HTTP/VoBLE 协议或 U30Air 独立 Agent。需要更新 Android APK；发布标签 v0.9.8.25 不含这些修复。

## 验证

- `android/phone-control-app/test.sh` 全套通过，涵盖共用 executor、VoBLE 适配入口、前置探测、SIM、短信加密以及原有蓝牙/音频等回归。
- RootSMSCallbackStoreTests：Root UID、一次性领取、跨尝试隔离、撤销、到期、数量上限。
- RootSMSProviderCallTests：API29/30/31/36 的 Binder call 形状、目标 profile 10、异常也释放 lease、拒绝 shell。
- PrivilegedSmsConfirmationTests：API29/33/36 边界模拟、正常成功、提交后异常再收到迟到成功、重复/乱序分段、系统失败、缺失回执、预算耗尽、中断和资源清理。
- RootSMSCallbackProviderTests：运行实际 provider 方法，验证 App/shell/system UID 拒绝、只允许既定 method、一次性领取与撤销。
- Standalone Debug 编译、DEX、签名及旧 Android Java API 检查通过。包路径 `/tmp/airsim-sms-confirmed-standalone-build/AirSIM-Standalone-SMS-debug.apk`。未安装、未发布。

JVM 测试模拟 Android 边界，不是各 API/OEM 的真实系统验收。

## 待真机验收

此次没有代发真实短信。优先在无 Root + 自动模式验证原回归，再在有 Root 的设备验证跨进程领取 App PendingIntent 与系统真实回执。后者尚无实机证据；厂商隐藏 API、SELinux、Root 管理器与权限差异仍需实测。

分别使用 VoWLAN、VoBLE、云端：用户手动发一条短短信及一条多段短信，核对 iPhone 发信记录、收件方收到且没有重复。Root 未授权、系统失败、回执缺失时检查不会自动换卡/换通道重发。验证短信期间 PCM 控制仍正常。

故障用户版本和权限通道未知，不能宣称本补丁已解决该用户全部现象。已废弃的 ANCS 通知转发未恢复。
