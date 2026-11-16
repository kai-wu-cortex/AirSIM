# VoBLE 断线恢复修复与 iPhone 耳机挂断分析

日期：2026-11-05。开发分支：`develop`；修改基于 `ead7bf8`。

本记录承接 [Issue #20 评审](issue20-voble-reconnect-review.md)。修复仅涉及 iOS/Android 客户端内部状态，不修改 Relay HTTP、U30Air 或 AVF 协议。

## 已实现

1. **P1 / 握手队列释放**：通过同步的握手结束通知释放 Hub 占用，不再依赖可能合并/跳过的异步 UI 状态。下一设备延后调度，避免断线回调内重入。首次扫描不算握手结束；其他设备的迟到事件不能释放当前设备占用。
2. **P1 / 阶段超时恢复**：前台普通连接 8 秒、服务发现与认证各 20 秒、系统自动重连前台等待 30 秒。超时先取消旧连接，等待真实断开后再发现；回前台重新开始观察。任务校验连接 revision、peripheral 与阶段，旧任务不能取消新连接。后台不强制计时，等待用户确认安全码时暂停；提交确认后重新计时。ready 通话不受此超时控制。
3. **P1 / GATT 生命周期清理**：Android close 主动清理所有认证所有者、订阅、队列，并通知服务释放会话与媒体。关闭异常不跳过清理；重复 close 不重复通知。旧回调由 generation 隔离，排队认证由 channel epoch 隔离，不能在关闭后恢复旧所有者。服务已销毁时不向终止的线程池提交断线清理。
4. **P2 / 广播失败恢复**：openGattServer 返回空/抛异常、addService 返回 false、服务添加回调失败和广播启动异常均通知原有有限次数退避调度。权限缺失、蓝牙关闭及服务销毁仍受原有约束；不引入无限重启。

## 自动化验证

- iOS 全部单元测试：506 项通过，日志 `/tmp/airsim-issue20-full-ios.log`。
- 完善同状态阶段重启后的超时重新挂载后，再运行定向回归 78 项，全部通过，日志 `/tmp/airsim-issue20-final-ios.log`。
- 新增 Hub 测试以 **B 已在 A 握手期间排队** 为复现条件，验证无错误断线、failed 紧接 scanning 都能推进 B，并验证 A 迟到事件不释放 B。相比评审时的临时测试，避免了“重新发现 A 先于 B，合法地开启新握手”的歧义。
- Android `phone-control-app/test.sh` 通过，包括 GATT 真实类与蓝牙桩的生命周期测试。
- Android `test-gateway-lifecycle.sh` 通过，包括失败 PCM 握手、销毁后迟到握手，以及销毁后断线回调无异常。
- Android Standalone Debug 构建与 pre-33 Java API 检查通过。未安装设备、未发起真实电话、未发布。

这些是模拟状态、合成 PCM 和构建验证，不等于真实 RF 链路长时间稳定性验收。

## iPhone 蓝牙耳机：目前能确认什么

用户已确认耳机连接在 iPhone。尚未确认挂断后系统蓝牙设置是否显示“未连接”，或只是通话音频路由退出。因此不能断言系统故障，也不能排除 App 的音频会话切换对该耳机的影响。

源码路径：

- `VoBLEAudioEngine.stop()` 停止音频引擎、清空媒体状态；只有 App 自己激活的会话才主动 setActive(false)。CallKit 管理的会话由系统停用。
- `VoBLEGATTMediaTransport.stop(identity:)` 只结束当前通话媒体，不请求断开耳机，也不停止整个蓝牙管理器。
- VoBLE 通话使用 HFP 输入/输出。结束通话后 HFP 路由退出与耳机设备断开不是同一件事。
- 若启用后台静音音频保活，挂断后 `BackgroundStandbyController.resumeAfterCall()` 可切到 playback/mixWithOthers。这个额外类别切换是需要实测对照的因素，当前没有证据证明它造成物理断连。
- 未发现 VoBLE 挂断路径调用耳机取消配对、关闭系统蓝牙或按耳机身份断开连接的代码。

Apple 文档说明 [allowBluetoothHFP](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetoothhfp) 使 HFP 设备可作为音频输入；[音频路由变化通知](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes) 提供变化原因与先前路由。路由通知本身不是系统蓝牙 ACL 连接状态的完整证据。

## 已补充的诊断

仅在现有 Verbose 开关开启时保存；没有新增自动上传或音频录制。

- `audio-route / route_changed`：在系统通知到达时快照前后输出端口类型、输入类型、原因码、category、mode、options，避免异步切换后才读取到另一条路由。
- `voble / audio_release`：释放时 App/CallKit 音频会话归属及输出端口类型。
- `bluetooth / handshake_timeout`：超时阶段与连接 revision。
- 不新增耳机名称、设备标识、MAC 或音频内容采集。

## 真机验收清单

1. 配对完成后空闲、锁屏、回前台；确认 VoBLE 能恢复，且不会长时间停在认证中。
2. 在服务发现/认证中让安卓离开范围再回来，或关闭再开启安卓蓝牙；确认恢复且不要求清除配对。
3. 已知设备 A 握手失败时，设备 B 仍能连接；A 的迟到事件不能影响 B。
4. iPhone 连接耳机后手动进行 VoBLE 通话，分别由本机和对端挂断；记录挂断时间，并检查 iOS 设置中的耳机连接状态。随后手动播放音乐，检查媒体是否仍走耳机。
5. 对比关闭/开启后台静音保活、前台/锁屏挂断。导出同一窗口的 Verbose 日志，关联 CallKit deactivated、audio_release、route_changed。
6. 若设置中确实变为“未连接”，进一步取得耳机型号、iOS 版本及系统蓝牙诊断；App 端的 oldDeviceUnavailable 不能单独判定物理断连根因。

当前结论：4 项源码缺陷已修复并完成自动化验证；耳机问题已定位到需要区分的会话/路由边界，尚未实机复现或确认根因。
