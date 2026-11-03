# Pure Local Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 设置顶部滑动开启纯本地；复用 VoWLAN+VoBLE，确认 Android/AVF 排空后禁止全链路 AirSIM Relay 请求，支持安全退出恢复。

**Architecture:** 独立持久策略优先于媒体/推送偏好；双端以修订号和幂等操作同步，通过已认证本地链路协商。所有 Relay I/O 使用可取消、代际隔离的统一出口；UI 从状态机派生，不能写出虚假的两端生效。

**Tech Stack:** Swift/SwiftUI/CryptoKit、Java/Android 现有加密依赖、Go 标准库；XCTest、Android JVM tests、Go tests。

**Spec:** `docs/superpowers/specs/2026-10-29-pure-local-mode-design.md`

## Global Constraints

- 用户已要求实现设计。先完成本计划评审与执行方式选择，再进入业务实现；本文件不是功能完成回执。
- 复用 `localDual`，显示名保持 `VoWLAN+VoBLE`，不更改已保存枚举值。首次进入保存快照，重复进入/重启不覆盖。
- “关闭云端推送后，锁屏来电提醒可能受限。”必须常驻；VoiceOver 可用；活动通话不切换。
- 两端确认后才显示已生效；旧 Android/AVF、不匹配身份、未知能力均不能视为成功。
- Tailscale 不查询 Relay，但本地配对认证、签名、防重放和控制/PCM 端口证明不减少。
- 原工作目录及隔离副本已有未提交的手动反馈/隧道恢复候选和显示名修改必须保留；不得把这些内容误纳入本任务提交。
- 不推送、合并、部署、发布、安装或变更设备权限，不上传真实反馈，不打真实电话/发短信。
- GitHub 更新偏好不变；不宣称系统、VPN 或运营商无外网通信。

## Review Focus

1. 开启时并发创建、重试或重定向的 HTTP/WebSocket 不得越过策略，也不得在退出后应用旧结果（Tasks 2–4）。
2. BLE 与 WLAN 配对身份不同，但同一 iPhone 应能跨链路控制自己的事务；其他配对设备不能伪造退出（Tasks 1–3）。
3. Android 本机退出、换绑、重装失去身份或旧 ACK 到达后，不得自动重新开启对端或伪报完成（Tasks 1、5）。
4. Android 可达而 AVF 不可达/旧版时不能宣称整条链路已停；持久化失败也不得 ACK（Tasks 2–3）。
5. 退出不能补发纯本地时段的过期来电/短信云事件、重复短信命令；迟到 PushKit 回调仍符合平台要求（Tasks 2–4、6）。

## 文件组织与提交边界

- 新建小型策略/协议/I/O gate 单元，保持既有 AppModel 与 Service 只承担接线，不做无关重构。
- 新 Swift 文件加入 `iOS/AirSIM.xcodeproj/project.pbxproj` 对应主 App/test target；Watch 使用共享策略快照，不把 iOS-only 控制器引入 watch target。
- Android 新类位于 `android/phone-control-app/src/com/airsim/phonecontrol/`，测试位于对应 `test/com/airsim/phonecontrol/`。Go 在 `module/module-agent/` 内分文件。
- 首次执行前保存当前 diff 清单/补丁到本任务忽略的 scratch，记录 HEAD `a68bf44` 与所有已有候选差异；共享文件以 hunks 区分任务变更，不能 `git add .`。

## 同步接口（Tasks 1–5 共同合同）

新增只允许认证本地访问的 `GET /api/local-mode`、`POST /api/local-mode`；BLE 使用 `local_mode_status`、`local_mode_set`，body 相同。不得通过云端命令入口调用。

请求字段：`version=1, agent_id, operation_id(UUID), enabled, expected_revision(UInt64), owner_public_key(base64 Ed25519), signature(base64)`。退出使用进入时相同 owner，快照留服务端而非由请求任意注入。服务端校验方法、字段、长度、当前 agent、当前 revision、认证来源，再做状态变更。错误区分 `401/403`、`409 revision_conflict/active_call/owner_mismatch`、`501 unsupported`、`503 agent_pending/draining`；任何错误都不清除已持久化的禁用策略。

设计者实施选择：现有 WLAN record ID 是 secret 指纹，BLE 使用独立 peer identity，不能直接等同。iPhone 在 Keychain 生成并持久保存专用 Ed25519 所有权密钥，原始私钥从不传输。签名内容固定 UTF-8：`airsim-pure-local-v1\n<agent_id>\n<operation_id>\n<0或1>\n<expected_revision>`。owner 为公钥 SHA-256。首次开启还必须通过原有配对认证，不能仅凭自签公钥进入；后续退出还要匹配保存 owner。这样两个已配对本地链路可使用相同所有权证明，不新增弱管理端口。不支持的加密实现必须失败，不退化成请求自报身份。

响应字段：`version, agent_id, enabled, revision, last_operation_id, owner_fingerprint, source(remote|android_local), drained, avf_required, avf_confirmed`。WLAN ACK 使用当前请求配对密钥对完整状态和请求 nonce 做 HMAC 证明，客户端验证后才接受；BLE 使用现有会话认证加密。不能将明文 HTTP 的任意 200/JSON 当作生效证明。AVF 经既有受认证 Android→Agent 通道执行同一带签名请求，限制可调用来源；不得信任客户端伪造的 owner header。

状态提交顺序：写盘禁用策略/快照 → 递增代际禁止新 I/O → 取消/等待旧 I/O 完成 → 丢弃云上传积压但保留本地记录 → 必要 AVF 确认 → ACK。若中途失败，保持禁用并提供 pending 状态；退出恢复也必须可在进程崩溃后继续。相同操作只能读回当前状态，不能复活已被 Android 本机更高 revision 取代的事务。

### Task 1: 纯策略、所有权与协议合同

**Files:** Create `iOS/AirSIM/PureLocalModePolicy.swift`, `iOS/AirSIM/PureLocalModeProtocol.swift`, `iOS/AirSIMTests/PureLocalModeTests.swift`; create `android/phone-control-app/src/com/airsim/phonecontrol/PureLocalModePolicy.java`, `PureLocalModeProof.java`, corresponding tests and `test-pure-local.sh`; create `module/module-agent/local_mode_protocol.go`, `local_mode_protocol_test.go`.

**Interfaces:** `PureLocalSnapshot` 保存本机进入前模式/通知和按 agent 分组的事务；`PureLocalCommand/Status` 对应上述 wire。Swift `PureLocalModePolicy.reduce(state:event:) -> State`，Java `PureLocalModePolicy.apply(State, Command, AuthenticatedPeer, boolean callActive) -> Transition`；Go 校验函数 `verifyLocalModeCommand(cmd localModeCommand, agentID string) error`。纯模型不启动网络。

- [ ] 写测试：首次保存/重复保留、离线 pending、过期 ACK、换绑保留 A 快照、Android 本机退出禁止自动重入、owner 错误、revision 错误、无效签名、活动通话拒绝、快照损坏保守禁用。跨语言使用相同固定 key/消息/签名向量，不使用真密钥。
- [ ] 运行新测试，确认因缺少行为失败；实现最小状态机、编码/验证及 Keychain adapter；私钥加载失败不能生成新身份假装原 owner。
- [ ] 验证：`sh android/phone-control-app/test-pure-local.sh`；`cd module/module-agent && go test ./...`；XCTest `PureLocalModeTests`。Expected: 全部通过，签名向量一致，重放拒绝。
- [ ] 仅提交本任务新增模型/测试/target 配置 hunks。

### Task 2: Android 持久策略与出口停机

**Files:** Create `PureLocalModeStore.java`, `RelayEgressGate.java`, `PureLocalModeCoordinator.java`, corresponding tests; modify `StandaloneAgentStore.java`, `StandaloneAgentService.java`, `StandaloneRelayClient.java`, `StandaloneWebSocket.java`, `StandaloneCloudMediaManager.java`, `StandaloneSMSStore.java`, `NotificationForwarder.java`, `FeedbackUploader.java`, `MainActivity.java`.

**Interfaces:** `PureLocalModeStore.read()/commit(State)` 必须同步确认持久化结果；`RelayEgressGate.acquire(Closeable cancellation) -> Lease`, `disableAndDrain(timeoutMillis) -> boolean`, `Lease.isCurrent()/close()`；`PureLocalModeCoordinator.status()/apply(command, authenticatedPeer)` 返回合同状态，Android 本机退出走单独本地入口。

- [ ] 先写计数传输与受控阻塞 I/O 测试：禁用后请求计数为零；在途被取消、未排空不 ACK；旧服务重启/注册不能解除；禁用短信仍入本地收件箱但不入云队列；退出不补发；Android 本机退出 revision 胜过旧重试。
- [ ] 观察 RED；实现持久策略及可取消 gate。检查所有 `openConnection`/Socket/Relay 调用，禁止自动重定向泄漏；连接在 gate 内登记后才能发送，所有 finally 释放 lease。启动从磁盘初始化后才允许网络。
- [ ] 在 Android 页面显示当前模式和本机确认退出入口；禁用云端开关/反馈上传而非只隐藏；不停止本地网关和 Shizuku/Telecom。
- [ ] 验证 `sh android/phone-control-app/test-pure-local.sh && ./android-standalone/test.sh`。Expected: 新测试和 #12/#13 回归均通过；提交仅此任务变更。

### Task 3: 本地协商和 AVF 完整确认

**Files:** Modify `VoWLANControlPolicy.java`, `VoWLANControlGateway.java`, `AgentClient.java`, `StandaloneAgentGateway.java`, `PairingServer.java`, `voble/VoBLEGatewayService.java`; create Go `local_mode.go`, `local_mode_test.go`, `relay_egress.go`, tests; modify Go `main.go`, `push.go` 及实际云命令/媒体发送入口（实施先列出 I/O 清单）。

**Interfaces:** WLAN 使用 `matched` 配对记录构造 `AuthenticatedPeer`，BLE 使用解密后的已认证会话；不可从请求字段推导认证事实。Android coordinator 调用 AgentClient 的 `localModeStatus()/setLocalMode(Command)`；Go handler `(*agent).localMode(http.ResponseWriter,*http.Request)`，以原有认证/准入中间件保护。

- [ ] 写测试：未认证/签名错误/重放拒绝、WLAN↔BLE 相同 owner 可退出、不同 owner 拒绝；ACK 状态被修改/nonce 不符拒绝；AVF 不在线/旧版只能 pending；首次纯本地配对无需 Relay/APNs；AVF 进程重启不恢复云任务。
- [ ] 观察 RED；接入策略 API 与 BLE 控制命令，不污染通话 session。AVF 持久化与 gate 同样覆盖所有 Relay 请求，应用层云开关不得覆盖。
- [ ] 验证 `./android-standalone/test.sh`，`cd module/module-agent && go test ./...` 及 `go test -race ./...`。Expected: 通过，Agent 无网络副作用；提交。

### Task 4: iOS 全 Relay 出口约束与安全取消

**Files:** Create `iOS/AirSIM/RelayEgressGate.swift`, `iOS/AirSIMTests/RelayEgressGateTests.swift`; modify `ConnectionModePreference.swift`, `VoIPPushController.swift`, `BackgroundStandbyController.swift`, `IPhoneCloudCallSession.swift`, `WatchCallCoordinator.swift`, `LiveActivityController.swift`, `AgentVerboseTrace.swift` 和检索发现的其他直接 Relay 发送入口。

**Interfaces:** `RelayEgressGate.shared` 用持久策略在初始化时决定是否禁用；`send(_ request: URLRequest) async throws -> (Data, URLResponse)`、受控 WebSocket factory、`disableAndDrain() async -> Bool`、`enableAfterRestore()`，所有任务带 epoch。`CloudSignalingPreference.isEnabled` 和路由策略返回受纯本地约束的有效值，保留 raw 偏好供恢复。

- [ ] 写 URLProtocol/受控 socket 测试，覆盖注册、token、云自检、云控制、轮询、反馈、Watch/Live Activity；每个入口禁用后实际发送计数 0，本地 API 不受影响。取消/重定向/旧响应在退出后不能复活。
- [ ] 观察 RED；将直接 URLSession/Socket 收敛到 gate。进入时注销相关订阅、取消任务，不发送注销 Relay 请求；处理遗留 PushKit 的平台回调与现有合法 CallKit 路径，不访问 Relay、不执行旧命令。
- [ ] 验证 XCTest `RelayEgressGateTests`、既有 PushKit/CallKit/路由测试及 iOS 全量测试；Expected: 通过，敏感日志无新增。提交。

### Task 5: iOS 两端事务协调与首次配对

**Files:** Create `iOS/AirSIM/PureLocalModeController.swift`, `iOS/AirSIMTests/PureLocalModeControllerTests.swift`; modify `AirSIMAPI.swift`, `APIModels.swift`, `VoBLECentralController.swift`, `VoBLEDeviceHub.swift`, `AppModel.swift`, `SamsungPairingView.swift`, `VoBLEPairingView.swift`。

**Interfaces:** `@MainActor PureLocalModeController` 暴露可观察 `state`、`enter() async`、`requestExit() async`、`resynchronize() async`、`refreshPeerStatus() async`；输入本机 prefs、当前绑定身份、本地 transport、call-active predicate 与 Task 4 gate。`AirSIMAPI.localModeStatus()/setLocalMode(_:)` 验证 ACK，BLE 返回等价状态。

- [ ] 写测试：先持久化/停本机再同步；断连待确认；重启继续进入/退出；旧端需升级；换绑不拿 A 的 ACK 给 B；Android 本机退出后取消自动重入；首次未配对可开启并完成本地配对；A→B→退出不后台改 A；本地 API 失败不调用云 fallback。
- [ ] 观察 RED；实现 coordinator，仅首次保存快照，绑定改变使当前 ACK 失效。退出必须先远端确认再解除本机 gate；权限/所有权失败保留可解释状态。
- [ ] 模式有效值强制 `localDual`，原始选择和通知偏好保持可恢复；配对成功回调也不得绕过纯本地重新启用云端。
- [ ] 验证 XCTest `PureLocalModeControllerTests` 加现有 `VoWLANNetworkRecoveryTests`、`DeviceCallActionRouterTests`、`VoBLEMultiDeviceTests`。Expected: 全部通过；提交。

### Task 6: 设置顶部滑块及跨端集成验收

**Files:** Create `iOS/AirSIM/PureLocalModeSection.swift`, `iOS/AirSIMTests/PureLocalModePresentationTests.swift`; modify `AirSIMSetupView.swift`, iOS target entries、Android测试 runner、相关 README 和设计状态；新增 `docs/pure-local-mode-verification.md`。

**Interfaces:** `PureLocalModeSection(controller: PureLocalModeController, callActive: Bool)`，仅委托 coordinator 不直接写联网偏好；拖动至轨道末端触发一次，回退/取消零次；无障碍按钮走同一 action。状态文案映射来自 spec。

- [ ] 写 UI 状态/交互测试：滑动完成一次、拖动中断、VoiceOver、活动通话禁用、退出确认取消、pending/不兼容/已生效/对端退出、云自检与上传入口禁用。
- [ ] 观察 RED；实现设置 Form 最前 Section，随后保留原运行模式区和 `VoWLAN+VoBLE` 名称，不误称两个端点已在线。
- [ ] 最终验证：`./android-standalone/test.sh`，`cd module/module-agent && go test ./...`，iOS `xcodebuild ... test` 全量，`git diff --check`；iOS generic device 与 Android release-free debug 构建验证。模拟器选择可用设备后将准确 destination 写入验证记录，不安装真机。
- [ ] 按 spec 做一次全分支独立审查；重要问题以 RED→GREEN 修复，再全量测试。记录全部未覆盖设备/系统条件和既有基线失败，不把测试替代真机抓包。
- [ ] 文档记录实际通过的命令、代码版本、请求计数测试范围、未完成的真机清单；只本地提交，不推送或发布。

## 计划自检

- 设计章节 1–2 → Tasks 1、4、6；3–5 → Tasks 1–5；6 → Tasks 2–5；7–9 → Task 6 与各任务测试。
- 全部跨端接口共用 version 1 / agent identity / operation ID / revision / ownership proof；localDual raw value 不变。
- ACK 除功能状态还要求身份与内容完整性，尤其不能将 HTTP 200 当作全链路生效。
- 现有模式 owner 身份跨 WLAN/BLE 不同是实际代码确认的约束，新增签名所有权证明是本计划的实现选择，需在计划评审确认。
- 执行方式建议 Native：跨任务状态机和 I/O gate 耦合较高，由同一上下文实现，再做一次独立整体审查。
