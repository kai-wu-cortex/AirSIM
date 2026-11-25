# 纯云端来电：iPhone 接听即收起 Watch 响铃、不再空等局域网

日期：2026-11-25。基于 `develop` `0be80a0`（v0.9.8.27）。只修改 iOS／watchOS 与文档。

## 现象与证据

只有云端连接时（iPhone 在蜂窝网络，安卓在家），iPhone 点接听后久久接不通，Watch 一直响铃到通话结束。

2026-11-25 09:39 一通来电的安卓侧记录（Standalone 0.9.8.25，iPhone 为「自动」模式）：

- Telecom：09:39:27.99 振铃；09:39:43.87 AirSIM `REQUEST_ACCEPT`，距振铃 15.9 s；09:39:43.99 ACTIVE；09:40:29.21 AirSIM 挂断。
- 同期 Shizuku 未运行（设备重启后未启动），`pcm_probe_failed 127.0.0.1:7580 ConnectException` 持续出现。`StandaloneCloudMediaManager.runPCM` 连不上音频桥，安卓从未发出 `active`。
- 同期心跳返回 `Relay HTTP 500` 与 `503 relay_capacity_exhausted`（同 #37）。

Shizuku 未启动与 Relay 额度属于运行环境问题，本次不处理。下面两处代码行为与环境无关：它们会让任何环境故障都表现为「接不起来、手表一直响」，在一切正常时也拖慢接听。

## 原因

1. **Watch 收起响铃依赖 ACTIVE。** `WatchCallSession.receiveMirror` 只在 iPhone 镜像 `.active` 或 `.ended` 时收起。`monitorRingingCall` 只在保存了私网直连路线时才轮询，而纯云端时这条路线不可达，轮询起不了作用。iPhone 只在生命周期变为 `.active` 后发布 `.active`；云端接听要等 Relay 往返、安卓接听、PCM 桥连接并回传 `active`（`CallAnswerConfirmationPolicy` 只对 VoWLAN 立即确认）。冷启动时 `ColdLaunchCallKitHandler` 直接调用 `IPhoneCloudCallSession` 接听，完全不经过 AppModel，Watch 一个状态也收不到。用户点接听的那一刻，Watch 收不到任何信号；其中任何一步变慢或失败，Watch 就持续响铃。
2. **「自动」模式空等局域网。** `callKitAnswer(origin:)` 在非云端模式先调用 `waitForLocalIncomingRoute()`：20 次 × 400 ms，最多约 7.6 s 后才提交云端接听。iPhone 不在 Wi-Fi 时，Bonjour 不可能发现安卓，这段等待毫无作用。「自动」是默认模式。

## 修复

1. WatchConnectivity 镜像载荷新增可选字段 `answered_on_phone`，随 `.connecting` 发送。
   - **触发时机：** `CallKitActionHandling` 新增 `callKitAnswerAccepted(uuid:)`。`CallKitController.performAnswer` 在 `action.fulfill()` 之后、任何后端动作之前调用它。
   - **iPhone 侧的两个实现：**
     - AppModel：只对仍在振铃的这通电话发布，沿用推送身份映射。
     - 冷启动：`ColdLaunchWatchAnswerAnnouncer` 按当前推送发布；系统通话结束时，再为这通已宣告的电话发布 `.ended`。
   - **不发信号的接听：** App 内不经 CallKit 的接听失败后可能回到振铃，因此不发。当前 Watch 用 `watch_local_answer` → `answerOwnedCallFromWatch` 接听，同样不经 CallKit。旧版 Watch 的 WC `answer` 仍会经过 CallKit，但那块 Watch 正处于接听中，会忽略该信号。
   - **Watch 收到后：** 对未接听、也未在接听的来电以 `answeredElsewhere` 收起，并写入结束墓碑，迟到的 Watch VoIP 推送不会再响。同一通电话随后的 `.active` 仍可更新 Watch 显示（`WatchCallMirrorPolicy.acceptsPhoneOwnedProgress`）。Watch 自己正在接听或已接听时忽略该信号。
2. 等待循环改为 `IncomingLocalRouteWait.run`，每轮先取已就绪路线，再由 `IncomingLocalRouteWaitPolicy` 判断是否继续等待。
   - **停止等待，直接走云端：** 必须同时满足「自动」模式、推送带云端媒体、NWPath 已报告无 Wi-Fi，并且不存在离开 Wi-Fi 仍可达的候选。
   - **离开 Wi-Fi 仍可达的候选：** TLS 自建域名、100.64/10 tailnet、用户追加网段内的地址，以及曾在无 Wi-Fi 时通过签名健康检查的私网地址。最后一类即 VPN 直连，由 `VoWLANOffWiFiRouteStore` 在 `.verified` 时记录，最多保留 32 个。
   - **保持原等待：** Wi-Fi 状态未知（首个 NWPath 回调前）、存在候选、显式 VoWLAN 或 VoWLAN+VoBLE 模式、推送不带云端媒体。

## 兼容与边界

- 新字段可选：旧 Watch 忽略未知键，旧 iPhone 不发送时 Watch 行为不变。Android、Worker 和 Relay 报文均未修改。
- WatchConnectivity 在 Watch App 不在前台时，可能经 applicationContext／transferUserInfo 延迟投递。冷启动时，WCSession 激活完成后会补发最新状态。实际收起时延需要真机测量。
- 信号发出后若 CallKit 接听失败，系统通话随之结束，iPhone 会发布 `.ended` 收敛。这与系统 iPhone／Watch 的行为一致：一处接听后，其他设备不再响铃。
- 通过 WireGuard、ZeroTier 等 VPN 访问的私网地址，要先在无 Wi-Fi 状态下验证成功一次（例如离开 Wi-Fi 时的自动探测），之后才算候选。在那之前，离开 Wi-Fi 的接听会直接走云端。
- 本次不解决 Shizuku 重启后需手动启动、Relay 额度耗尽这两类问题。在这些情况下纯云端仍会失败，但 Watch 不再陪着响铃。

## 自动化验证

- `sh iOS/scripts/test-watch-reliability.sh`：359 项，新增 18 项，覆盖载荷往返、旧格式兼容、去重、收起判定真值表和显示放行。
- `sh iOS/scripts/test-watch-mirror.sh`：8 项；`sh iOS/scripts/test-watch-transport.sh`：155 项。
- 新增 XCTest（已编写，**尚未运行**）：
  - `testSystemAnswerRetiresWatchRingingBeforeMediaIsReady`
  - `testAnswerThatBypassesCallKitSendsNoWatchSignal`
  - `testColdLaunchAnswerSignalsTheWatchAndEndsOnlyTheAnnouncedCall`
  - `testAutomaticAnswerSkipsLocalWaitOnlyWhenNoLocalRouteCanAppear`
  - `testOffWiFiCandidatesKeepTheLocalWait`
  - `testOffWiFiVerifiedHostsAreRememberedOnceAndBounded`
  - `testWiFiPathStatusIsUnknownUntilTheMonitorReports`
  - `testIncomingLocalRouteWaitStopsAsSoonAsWaitingCannotHelp`
- 提交者本机只有 Command Line Tools、没有 Xcode，fork 上的 Actions 也被 GitHub 停用，因此 iOS／watchOS 目标**未经 Xcode 编译**，XCTest 也未运行，需要在 Xcode 中执行 `build-for-testing` 和 AirSIMTests。
- 本机已做的替代检查：
  - 等待策略、协调器与 VPN 地址记录：用 `swiftc` 抽取生产声明后跑 27 项断言，先红后绿。
  - `AppModel` 里的 `waitForLocalIncomingRoute` 与 `hasOffWiFiLocalRouteCandidate`：原文抽出，在签名一致的替身类中按 Swift 5 模式编译运行。无 Wi-Fi、无候选时只探测一次，不再休眠。
- 未在真机上安装或验收。

## 待真机验收

1. iPhone 在蜂窝网络并佩戴 Watch，「自动」模式来电：iPhone 点接听后 Watch 立即停止响铃，通话出声时间不再包含约 7.6 s 的局域网等待。
2. 冷启动场景（App 被系统回收或手机重启后来电）重复第 1 项，并确认挂断后 Watch 回到空闲。
3. iPhone 锁屏、Watch App 不在前台时，测量 Watch 的收起时延。
4. Watch 先点接听：iPhone 的信号不得打断 Watch 接听。
5. 在家同一 Wi-Fi：仍走 VoWLAN，接听前的等待行为不变。
6. 配置了 Tailscale、自建域名或已验证过的 VPN 私网地址时，离开 Wi-Fi 后仍会先尝试直连。
