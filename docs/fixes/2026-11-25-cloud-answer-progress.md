# 纯云端接听进度显示

日期：2026-11-25。基于 `contrib/cloud-answer-watch`（PR #52），依赖其中的 `CallKitActionHandling.callKitAnswerAccepted(uuid:)`。设计见 [cloud-answer-progress-design](../superpowers/specs/2026-11-25-cloud-answer-progress-design.md)。

## 原因

只有云端连接时，在 iPhone 上按下接听后要等几秒才能说话；失败时整段时间都没有反馈。例如安卓重启后 Shizuku 没启动，电话被接起却没有声音，约 45 秒后才结束（见 [#51](https://github.com/kai-wu-cortex/AirSIM/issues/51) 的现场记录）。用户希望看到进行到哪一步、等了多久，失败时尽快知道原因。

## 显示内容

| 阶段 | App 内标题 | App 内说明 | 名字行 | 时限 |
|---|---|---|---|---|
| 1 | 正在连接云端 | iPhone 正在连上云端 | 连接云端 N 秒 | 10 s |
| 2 | 正在等待安卓端响应 | 安卓端连上云端后会立即接听 | 等待安卓端 N 秒 | 10 s |
| 3 | 安卓端正在接听 | 接听指令已发给安卓端 | 安卓端接听中 N 秒 | 10 s |
| 4 | 正在接通语音 | 电话已接起，马上就能说话 | 接通语音中 N 秒 | 15 s |

- **名字行：** 系统通话界面的名字行接通前只显示进度，不显示联系人名字。CallKit 一旦写过名字行，就不能交还给 iOS 去匹配通讯录，所以接通、失败、结束时一律改写为号码，并且在报告结束之前完成，保证最近通话里是号码。
- **App 内通话页：** 显示四步进度（已完成打勾、当前步骤转圈、未到的步骤灰色）、说明，以及「已等待 N 秒 · 平均约 M 秒」。平均值取本机最近 10 次成功接通，至少 3 次才显示。
- **变慢提示：** 已等待超过平均值的 2 倍并且至少 5 秒时，说明换成「比平均慢，可能是网络较差」。
- **接通判定：** `active`、`pcm_first_frame` 或第一帧下行语音，以先到的为准。iPhone 语音连接断开重连时可能收不到 `active`，所以不能只认它。
- **仅限云端：** 只对带云端媒体的推送来电、非「蓝牙」模式显示。「自动」模式最终走 VoWLAN 时，立即取消进度，这次不计入平均值。冷启动（`ColdLaunchCallKitHandler`）同样显示名字行进度。

## 失败处理

失败后，名字行显示「接听失败」2 秒，然后改写为号码，结束这通 CallKit 通话，并发本地通知「通话未接通」，正文为「<标题>：<建议>」。

| 失败 | 判定 | 标题／建议 | 让安卓端结束电话 |
|---|---|---|---|
| 无法连接云端 | 阶段 1 达 10 s；每次云端语音连接尝试 8 s 超时（原为系统默认 60 s） | 无法连接云端／检查 iPhone 的网络 | 尽力发送 |
| 云端暂时不可用 | Relay 返回 HTTP 429 或 5xx（新增 `CloudCallControlClientError.relayUnavailable`） | 云端暂时不可用／稍后回拨对方 | 尽力发送 |
| 安卓端未上线 | 阶段 2 达 10 s | 安卓端未上线／检查安卓端的网络，确认 AirSIM 在运行 | 是：避免排队的接听之后接起一通没人的电话 |
| 安卓端没有响应 | 阶段 3 达 10 s | 安卓端没有响应／同上 | 是 |
| 安卓端无法传送语音 | `answer_unavailable` | 安卓端无法传送语音／在安卓端启动 Shizuku 后回拨 | 否：电话没有接起，继续在安卓端振铃 |
| 安卓端无法传送语音 | 阶段 4 达 15 s，或 `answer_ok` 之后收到 `action_error`（兼容独立 AVF Agent） | 同上 | 是：电话已接起，对方在听无声 |
| 安卓端未能接起电话 | `answer_ok` 之前收到 `action_error` | 安卓端未能接起电话／对方可能已挂断 | 否 |
| 已在其他设备接听 | `ownership_lost` | 已在其他设备接听 | 否，也不发通知 |

## 协议

- **新增媒体连接状态：** `{"status":"answer_unavailable","message":"audio_bridge_unavailable","call_id","call_uuid","generation"}`。
  - 安卓端（Standalone）在 `StandaloneAgentGateway.executeCloudAnswer` 确认来电仍在振铃之后、调用系统接听之前，对 127.0.0.1:7580 做 500 ms TCP 探测。不可用时，不接起电话，返回 `error == "audio_bridge_unavailable"`。
  - 媒体连接把这个错误转成上面的状态。HTTP 命令通道与媒体连接共用同一判断。
  - 拒绝结果不缓存：Shizuku 恢复后，同一条排队的接听仍能正常接起。
- **Relay `peer_connected` 事件：** iOS 现在解析其中的 `role` 字段；安卓端连上时（`role == "agent"`），等待中的进度前进到阶段 3。
- **兼容：**
  - 旧 iPhone 不认识 `answer_unavailable`，会忽略它，靠原有超时结束；
  - 新 iPhone 遇到旧安卓端，靠阶段 4 的 15 s 兜底；
  - Watch 自己经云端接听时，收到 `answer_unavailable` 会结束这次接听，并提示「安卓端无法传送语音」。
- 不修改 Relay，不新增 Relay 轮询，不修改独立 AVF Linux Agent。

## 自动化验证

- `sh iOS/scripts/test-cloud-answer-progress.sh`：62 项，直接编译生产文件 `CloudAnswerProgress.swift`，先红后绿。覆盖阶段前进、乱序、接通判定、各失败与时限、全部文案、等待与平均文案、平均值存储。
- 本机替代检查：在签名一致的替身中，原样编译 `CloudAnswerProgressCoordinator`（13 项场景）、`CloudPCMControlMessage` 与 `CloudCallControlClientError`（`role` 解析、429／5xx 区分）。
- `sh iOS/scripts/test-watch-reliability.sh`：362 项（新增 3 项）；`test-watch-mirror.sh` 8 项；`test-watch-transport.sh` 155 项。
- `sh android/phone-control-app/test-cloud-call.sh` 新增两项，先红后绿：音频桥不可用时不接起、拒绝不缓存；媒体连接回报 `answer_unavailable`。`./android/phone-control-app/test.sh` 与 `./android-standalone/test.sh` 全量通过。
- 新增 XCTest 已编写，**尚未运行**：
  - `testPeerConnectedCarriesItsRole`、`testRelayCapacityFailureIsDistinguishable`（`AirSIMTests`）；
  - `testAnswerProgressShowsOnlyProgressThenTheNumber`、`testEndingRestoresTheNumberFirst`、`testVoWLANWinCancelsProgress`、`testFailedAnswerShowsFailureThenEndsOnce`（`DeviceCallActionRouterTests`）。
- 提交者本机没有 Xcode，fork 上的 Actions 被 GitHub 停用，iOS／watchOS 目标**未经 Xcode 编译**。合并前需要在 Xcode 跑 `build-for-testing` 和上述测试。

## 待真机验收

1. 蜂窝网络、「自动」模式来电：名字行依次显示四个阶段，接通后显示号码，最近通话里是号码，而不是进度文字。
2. 在安卓端停掉 Shizuku 后来电：2 秒内显示「接听失败」并收到通知，对方听到的是继续振铃，而不是接通后无声。
3. 冷启动来电重复第 1 项。
4. App 内通话页的四步进度、平均值显示，以及失败时的红色原因。
5. 读屏（VoiceOver）开启时，名字行每秒更新不应造成反复播报；必要时再调低刷新频率。
