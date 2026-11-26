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
- **仅限云端：** 只在云端开关打开、非「蓝牙」模式、推送带云端媒体、不是虚拟来电时显示（`CloudAnswerProgressPolicy.shows`）。推送即使在云端关闭时也带云端媒体，那时接听走 VoWLAN，不显示进度。「自动」模式最终走 VoWLAN 时，立即取消进度，这次不计入平均值。冷启动（`ColdLaunchCallKitHandler`）同样显示名字行进度，它的 VoWLAN 分支也会取消进度。
- **计时：** 显示的已等待秒数从 CallKit 接受接听时算起。阶段 1 的 10 秒时限从云端接听真正开始时算起：「自动」模式先等局域网的最多 7.6 秒不占用它。

## 失败处理

失败后，名字行显示「接听失败」2 秒，然后改写为号码，结束这通 CallKit 通话，并发本地通知「通话未接通」，正文为「<标题>：<建议>」。

| 失败 | 判定 | 标题／建议 | 让安卓端结束电话 |
|---|---|---|---|
| 无法连接云端 | 阶段 1 达 10 s；每次云端语音连接尝试 8 s 超时（原为系统默认 60 s） | 无法连接云端／检查 iPhone 的网络 | 尽力发送 |
| 云端暂时不可用 | 仍在阶段 1 时，Relay 返回 HTTP 429 或 5xx（新增 `CloudCallControlClientError.relayUnavailable`）。语音连接已有进展后，HTTP 早期接听迟到的失败不算 | 云端暂时不可用／稍后回拨对方 | 尽力发送 |
| 安卓端未上线 | 阶段 2 达 10 s | 安卓端未上线／检查安卓端的网络，确认 AirSIM 在运行 | 是：避免排队的接听之后接起一通没人的电话 |
| 安卓端没有响应 | 阶段 3 达 10 s | 安卓端没有响应／同上 | 是 |
| 安卓端无法传送语音 | `answer_unavailable` | 安卓端无法传送语音／在安卓端启动 Shizuku 后回拨 | 否：电话没有接起，继续在安卓端振铃 |
| 安卓端无法传送语音 | 阶段 4 达 15 s，或 `answer_ok` 之后收到 `action_error` | 同上 | 是：电话已接起，对方在听无声 |
| 安卓端未能接起电话 | `answer_ok` 之前收到 `action_error`，之后 5 s 内重试仍未接起，或阶段时限先到 | 安卓端未能接起电话／对方可能已挂断 | 是：这类错误的结果可能未知，电话之后仍可能被接起 |
| 已在其他设备接听 | `ownership_lost` | 已在其他设备接听 | 否，也不发通知 |

- **失败状态必须指明这通电话。** `action_error` 和 `answer_unavailable` 只有带完整的 call_id、call_uuid、generation，并且 `action` 为空或是 `answer` 时才算（`CloudPCMControlMessage.identifiesAnswer`）。独立 AVF Agent 收到 Relay 广播的 `peer_connected`／`owner_claimed` 时，会回一条不带通话身份的 `action_error`，它总是先于 `answer_ok` 到达，不能当作接听失败。AVF 的语音失败同样不带身份，由阶段 4 的 15 s 兜底。
- **接起前的 `action_error` 先等 5 s。** 安卓端的 `call_not_ready` 是瞬时的，3 s 后的重试可能成功；`answer_result_unknown` 的结果未知。
- **失败一判定就停止重发接听。** 否则在失败提示显示的 2 s 内，安卓端可能又把电话接起（例如 Shizuku 刚恢复）。
- **失败只结束它所属的那通电话**（`CloudAnswerProgressPolicy.mayEnd`）：失败提示显示的 2 s 里通话可能已经换了。
- **通知在 App 打开时也显示**（`event: cloud_answer_failed`）。App 内通话页在 2 s 后消失，原因和建议只留在通知里。

## 协议

- **新增媒体连接状态：** `{"status":"answer_unavailable","message":"audio_bridge_unavailable","call_id","call_uuid","generation"}`。
  - 安卓端（Standalone）在 `StandaloneAgentGateway.executeCloudAnswer` 确认来电仍在振铃之后、调用系统接听之前，对 127.0.0.1:7580 做 500 ms TCP 探测，最多 3 次、间隔 300 ms（语音服务的监听重启退避从 250 ms 起）。可用时第一次探测就返回。不可用时，不接起电话，返回 `error == "audio_bridge_unavailable"`。
  - 媒体连接把这个错误转成上面的状态。HTTP 命令通道与媒体连接共用同一判断。
  - 拒绝结果不缓存：Shizuku 恢复后，同一条排队的接听仍能正常接起。
- **Relay `peer_connected` 事件：** iOS 现在解析其中的 `role` 字段；安卓端连上时（`role == "agent"`），等待中的进度前进到阶段 3。
- **兼容：**
  - 旧 iPhone 不认识 `answer_unavailable`，会忽略它，靠原有超时结束；
  - 新 iPhone 遇到旧安卓端，靠阶段 4 的 15 s 兜底；
  - Watch 自己经云端接听时，收到 `answer_unavailable` 会结束这次接听，并提示「安卓端无法传送语音」。
- 不修改 Relay，不新增 Relay 轮询，不修改独立 AVF Linux Agent。AVF 没有接听前检查，也不发 `answer_unavailable`；iPhone 忽略它不带通话身份的 `action_error`，靠各阶段时限兜底。

## 自动化验证

- `sh iOS/scripts/test-cloud-answer-progress.sh`：86 项，直接编译生产文件 `CloudAnswerProgress.swift`，先红后绿。覆盖阶段前进、乱序、接通判定、各失败与时限、不带身份的错误、接起前错误的 5 s 宽限、阶段 1 计时起点、显示与结束的判定（`CloudAnswerProgressPolicy`）、全部文案、等待与平均文案、平均值存储。
- 本机替代检查：在签名一致的替身中，原样编译 `CloudAnswerProgressCoordinator` 与 `CloudAnswerFailureNotifier`（21 项场景）、`CloudPCMControlMessage` 与 `CloudCallControlClientError`（10 项：`role` 解析、429／5xx 区分、`identifiesAnswer`，其中一条用的是 AVF 实际回复的那条消息）。
- `sh iOS/scripts/test-watch-reliability.sh`：362 项（新增 3 项）；`test-watch-mirror.sh` 8 项；`test-watch-transport.sh` 155 项。
- `sh android/phone-control-app/test-cloud-call.sh` 新增三项，先红后绿：音频桥不可用时不接起、拒绝不缓存；媒体连接回报 `answer_unavailable`；探测在监听重启后恢复、可用时只探测一次。`./android/phone-control-app/test.sh` 与 `./android-standalone/test.sh` 全量通过。
- 新增 XCTest 已编写，**尚未运行**：
  - `testPeerConnectedCarriesItsRole`、`testRelayCapacityFailureIsDistinguishable`、`testOnlyErrorsNamingThisAnswerCanFailIt`、`testCloudAnswerFailureNotificationShowsWhileTheAppIsOpen`（`AirSIMTests`）；
  - `testAnswerProgressShowsOnlyProgressThenTheNumber`、`testEndingRestoresTheNumberFirst`、`testVoWLANWinCancelsProgress`、`testFailedAnswerShowsFailureThenEndsOnce`（`DeviceCallActionRouterTests`）。
- 提交者本机没有 Xcode（只有 Swift 5.9 命令行工具），fork 上的 Actions 被 GitHub 停用，iOS／watchOS 目标**未经 Xcode 编译**。合并前需要在 Xcode 跑 `build-for-testing` 和上述测试。没有编译验证的部分：`IPhoneCloudCallSession`、`AppModel`、`CallKitController`、`BackgroundStandbyController`、`PhoneViews` 里的接线。

## 待真机验收

1. 蜂窝网络、「自动」模式来电：名字行依次显示四个阶段，接通后显示号码，最近通话里是号码，而不是进度文字。
2. 在安卓端停掉 Shizuku 后来电：2 秒内显示「接听失败」并收到通知，对方听到的是继续振铃，而不是接通后无声。
3. 冷启动来电重复第 1 项。
4. App 内通话页的四步进度、平均值显示，以及失败时的红色原因。
5. 读屏（VoiceOver）开启时，名字行每秒更新不应造成反复播报；必要时再调低刷新频率。
6. 云端关闭（「VoWLAN」或「VoWLAN＋VoBLE」模式）、「云端通知」打开时，冷启动接听一通 VoWLAN 来电：不显示进度，通话 10 秒后不会被结束。
7. 「自动」模式连着非家用 Wi-Fi 时来电：先等局域网约 7.6 秒，之后云端仍有完整的 10 秒。
8. 独立 AVF Agent 设备上经云端接听：不会在 `answer_ok` 之前显示「接听失败」。提交者没有 AVF 设备，这一项只有代码层面的验证。
9. App 在前台时接听失败：能看到「通话未接通」的横幅。
