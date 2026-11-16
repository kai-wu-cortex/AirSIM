# PR #34 前台服务启动整合

2026-11-10，目标 develop。原 PR head：51fbd09b82813342e5168a4ffecc33a6bf8c189a。

## 保留与调整

- 保留三个服务的并发启动去重、Standalone 提前提升前台，以及测试注解桩。
- 统一 ServiceStartGate，区分 RUNNING / PENDING / REQUESTED / REJECTED。
  启动返回 null 或抛异常解除 pending；服务销毁可重启；迟到的旧实例销毁不会清除新实例。
  门控是进程内请求去重，不代表 Android 原来会创建多个 Service 实例。
- 已运行 VoBLE 再次 start 时，在主线程合并广播恢复请求。复用 GATT.start 的幂等语义，
  重置重试预算，不关闭 GATT、认证会话或媒体。销毁/实例替换后排队回调失效。
- 启动使用 BridgeNotification.startup，只有基础渠道、图标、标题与状态，无偏好设置读取、
  SIM 查询或切卡操作构建；后续常规状态更新继续提供完整通知。
- 撤销 PR 的发布版本递增，仍为 0.9.8.24 / 135。版本号留到下一次正式发布统一更新。
- 不改 HTTP/POST 协议、Go Agent、Worker、iOS 或 U30Air；无需通知设备线程同步协议。

## 验证

- `sh android-standalone/test.sh` 完整通过，包含 Android JVM 回归、音频桥测试和 DEX 构建、
  Standalone Debug APK 构建、云端通话、网关生命周期、拨号所有权、纯本地出口及 Manifest 校验。
- 新增 ServiceStartupTests 13 项检查：16 路并发请求、等待创建、重复启动、空返回、平台拒绝、
  销毁重启、迟到销毁、恢复请求合并、延迟执行、销毁后丢弃与 Handler 拒绝后可重试。
- 新增实际 VoBLEGatewayService 方法回归：已有服务的 start 恢复广播重试预算，不请求新的
  OS 服务启动，并保留正在进行的媒体身份。`test-gateway-lifecycle.sh` 再次通过。
- PR #35 的 CaptureAuditCompatTests 16 项检查继续通过；`git diff --check` 通过。

## 验收边界

宿主测试不模拟 Android 系统的前台服务时限或真实蓝牙射频。仍需在贡献者报告的 Motorola / Pixel
和现有三星、Redmi 上复测冷启动、反复配对/注册、广播重试耗尽后的回前台恢复、权限变化、
服务重建及通话中回前台。未自动安装、拨打电话、部署或发布。

本改动减少启动关键路径工作量，不保证解决所有 ForegroundServiceDidNotStartInTimeException：
Application 初始化、系统调度与 ROM 行为仍可能影响时限。pending 只在系统明确拒绝或生命周期
确认后解除，不用超时无条件重复发起前台服务请求。
