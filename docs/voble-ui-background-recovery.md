# VoBLE 界面阻塞与锁屏恢复（iOS 候选 88）

## 代码证据

- CoreBluetooth 回调队列原为主队列。仅扫描回调在主队列并不足以解释卡顿；此前配对还直接执行 Curve25519/HKDF 和同步 Keychain 操作，媒体层又通过串行编解码队列的 `sync` 等待。
- 从 HTTP 模式切到蓝牙后，`eventStreamSupported` 可能仍为 true。BLE 分支没有 HTTP 长轮询的实际等待，却沿用 100 毫秒循环，每次重复写 Published 状态并请求刷新实时活动。
- 系统恢复传回的 CBPeripheral 被丢弃；连接没有开启 iOS 17+ 自动重连。原生重连仍套用 8 秒前台超时，休眠后可能取消系统仍在等待的连接。

这些是代码与回归测试证明的缺口，不是完整 Instruments 真机前后对比结论。

## 修复边界

- CoreBluetooth 对象继续由 MainActor 管理，避免跨队列访问及现有主线程隔离断言。配对密钥协商和 Keychain 读写由独立 actor 执行；配对消息有序且最多 16 个待处理，连接 revision 阻止晚到结果修改新连接。删除与保存使用同一 actor，避免旧保存覆盖删除。
- 编解码、加解密不再同步阻塞主线程；诊断读取缓存、播放最多预取 3 帧。上行待编码与待发合计最多 8 帧，下行最多 64 个待处理分片，各类工作保持单任务在途，并按会话 epoch 丢弃旧完成回调。
- 显式蓝牙模式不再运行 HTTP Agent 轮询，由蓝牙事件更新展示；自动模式走 BLE 时丢弃旧 HTTP 轮询标志，避免无等待的高频循环。重复状态赋值去重。
- iOS 17+ 请求系统自动重连；后台与原生重连不触发前台连接超时。恢复采用系统实际传回的对象，重新发现服务、订阅、认证、读取当前设备信息，不以历史 SIM 信息或旧在线缓存当作验证。
- 已授权的后台启动可以重新创建相同 restoration identifier 的中央管理器，不在后台触发首次授权。没有增加静音音频保活、Relay 依赖或修改 BLE 协议及密钥格式。

## 验证与限制

- iOS 完整测试 156/156 通过，含 5 个真实媒体编解码回归、后台超时、显式 BLE 事件驱动及配对凭据 I/O 不占主线程测试。
- 媒体回归先复现旧实现阻塞主线程、无限编码排队、旧会话音频进入新会话，再验证修复。阻塞编解码队列时，生命周期及播放读取仍可立即返回。
- 独立代码审查发现的凭据保存/删除竞态已修复并复审。
- iOS 0.9.7（88）签名 Release 构建成功，已保留数据覆盖到用户 iPhone Air。设备应用列表确认 build 88，主 App 与实时活动扩展启动后进程均存在；这只证明安装和启动，不等同于锁屏蓝牙验收。
- 锁屏长时间连接与切换页面流畅度仍需同一真机实测。系统强制退出应用、蓝牙关闭、越出无线范围不属于后台恢复保证。
- Android 重连协议存在“安卓先提交新密钥，而 iOS 尚未收到 ready 确认”的潜在失步窗口；本轮未改变协议，需要单独设计兼容提交/恢复机制，不能宣称所有重连风险均已消除。
- 三星 VoWLAN 听筒仍有声的问题尚未解决，见 [独立验收记录](samsung-cellular-output-mute.md)。本轮不将策略回读成功当作物理静音成功。

参考：[Apple 蓝牙后台与状态恢复](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)、[系统自动重连选项](https://developer.apple.com/documentation/corebluetooth/cbconnectperipheraloptionenableautoreconnect)。
