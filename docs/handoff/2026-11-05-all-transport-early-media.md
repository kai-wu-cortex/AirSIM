# 全连接模式早期媒体（接通前运营商下行音频）

本次工作位于 develop，目标是统一开放 VoWLAN、VoBLE、云端接通前音频；不按三星、Redmi 或芯片厂商拆包。开放协议不代表每个 ROM 都能提供蜂窝下行音频，实机需分别验收。

## 共同约束

- 仅属于当前已认证通话的呼出 DIALING 阶段；不伪造 ACTIVE，不提前开始通话计时。
- 接通前只接收真实运营商音频，不申请录音权限、不安装麦克风 tap、不创建 Android 上行 AudioTrack、不向蜂窝链路注入音频。
- Agent 必须核对通话身份；结束、主动挂断、换通话或失去授权后撤销。终态以后不延长已结束通话播放公告。
- 多通并存时无法证明全局电话采集源归属，因此禁用早期媒体。无能力时继续正常拨号等待；不重拨、不合成“暂时无法接通”公告。
- Android Standalone 改为 Telephony Rx / PCM 格式 / AudioRecord 初始化、首帧与实际路由检查，取消厂商/型号白名单。捕获源固定 VOICE_DOWNLINK。硬件上不存在或拒绝该路由，软件无法强制制造运营商下行。

## VoWLAN

保持现有签名 `/api/calls/early-media`、call/session/expiry 绑定和 AIRSIMEM1 握手。内层桥为 AIRSIMRX01。只扩大 Standalone 的设备准入，不改变已发布 v1 协议。

## VoBLE（新增，可选）

- 通过现有配对认证的控制链路发送 `start_early_media`，沿用 call_id + generation；number 字段携带每次媒体尝试新生成的 UUID nonce（不是电话号码）。
- Agent 必须确认该身份归属、独占 outgoing DIALING 和仍未接通；内部 `AIRSIMRX01\n` 握手成功后返回 detail=`early_media_ready_v1`。旧端返回不支持即回退等待音，绝不回退为双向媒体。
- 早期媒体 key = HMAC-SHA256(既有媒体 key, UTF-8("airsim-early-media-v1:" + nonce))。早期/接通后和不同早期尝试分离加密密钥，避免重置序号后复用 AES-GCM nonce。
- 接通后仍发送原 `start_media`，使用原双向格式；先关闭早期音频和旧队列。提前或迟到的 ACK 不得复活媒体。
- 早期流故障或撤销会发送认证控制事件 `early_media_stopped`（同 call_id/generation）；iOS 仅在同一尚未接通通话上消费，不影响已接通通话。两端均有 120 秒上限。
- 独立于模式名称，VoWLAN+VoBLE/自动模式按当前通话真正拥有的传输路径执行。

## 云端（新增，可选）

- 保持原 Relay WebSocket URL、token 鉴权和 `answer`（订阅/接受媒体）流程；客户端控制帧增加可选 `early_media_version: 1`，不改变电话拨号操作。旧客户端/旧 Agent 可以忽略该字段。
- Standalone Agent 仅收到协商字段、完整一致的 call_id/call_uuid/generation 且 outgoing DIALING 时打开 receive-only 桥。
- 真正完成 receive-only 握手后，Agent 在首个二进制帧前发送 `status: early_media_ready_v1`，必须带完整 call_id/call_uuid/generation。iOS 仅精确身份与 connecting 阶段接受此状态，不把它当作 ACTIVE。
- 失败可发送同身份 `status: early_media_unavailable`；不终止信令、不挂断电话。相同 WebSocket 的已确认 ACTIVE 状态禁止被迟到 early ACK 降级。
- Agent 仅 Telecom 实际 ACTIVE/HOLDING 后切换 `AIRSIMPCM1`，上报 active 并开启双向。PCM READY 本身不是电话接通证据。
- Agent 音频监听独立于可能缓慢的 Relay HTTP lifecycle POST，状态改变即关旧流；每帧发送前复查当前归属/状态。
- Worker 现有媒体转发保持附加字段、status 和二进制，不需要修改 POST 路由或部署 Worker。自托管服务若自行过滤未知字段，须保留 early_media_version 和上述 status。

## U30 Air / AVF 协同边界

U30Air 由独立线程维护，本线程不修改其补丁、不操作 USB。其现有 VoWLAN 早期媒体可继续工作。维护线程已回报：云端 v1 协商、完整身份检查、首帧确认和接通状态检查已写入其集成补丁，Agent/插件 race、vet 与 29 项 Node 测试通过；新协议尚未安装或联合实机验收。对应交接是 U30Air 仓库的 `docs/handoff/2026-11-05-cloud-early-media-v1.md`，这不代表既有 R21 发布包已经包含该改动。现有 AVF Agent 未提供新的蓝牙/云端 receive-only 能力时保持兼容，不把未知能力当已支持。

## 验证和未验收项

自动回归覆盖：不同厂商元数据不影响桥准入、只接收桥不创建上行、非法上行被丢弃、蓝牙密钥跨语言一致且不同阶段隔离、通话归属/终态、云端真实本机 TCP 合成 PCM 在 DIALING→ACTIVE 切换（不得仅因 READY 上报 active）。最终验证结果（2026-11-05，develop 未提交工作树）：

- iOS 构建成功；Duo iOS 27.2 模拟器 `AirSIMTests` 全量 **496 项通过，0 失败**，包含 7 项新增跨模式早期媒体测试。定向 66 项也通过。
- 首轮全量有两项 LocalDeviceDirectory 通话收尾测试在 2 秒等待处超时；未放宽断言或跳过用例。定向复核和最终全量均通过；测试服务曾启动挂起，重启模拟器 testmanagerd 后恢复。不能据此断言首轮超时的唯一根因。
- Android `phone-control-app/test.sh`、`test-cloud-call.sh` 与 `phone-audio-bridge/build.sh` 通过；最后的 Standalone Debug APK 构建成功。
- Relay 转发测试 64 项通过；Worker 生产代码未改动，不需为本功能部署 Worker。
- iOS 10 个 Mach-O 的 Date 比较运行时导入检查及 `git diff --check` 通过。
- 测试未读取真实麦克风、拨号或保存通话音频。构建产物仍为本地测试产物，未安装/提交/推送/发布。

可复查日志：`/tmp/airsim-early-ios-full-confirm.log`、`/tmp/airsim-early-ios-retry.log`、`/tmp/airsim-early-android-final.log`、`/tmp/airsim-early-cloud-final2.log`、`/tmp/airsim-early-apk-final2.log`、`/tmp/airsim-early-relay-test.log`。

仍需用户手动实机验证：各实际机型/ROM及运营商在三种传输下的公告、忙线/拒接/无人接听、普通双向通话、立即主动挂断、接通切换时无旧音频串入。没有实际下行的场景不能承诺听到公告；未安装、未发布、未替用户拨号或录音。

## 后续 iPhone 安装（2026-11-05）

用户授权后，已用当前 develop 工作树构建开发签名 **0.9.8（170）**，覆盖安装到 iPhone Air（`com.eric3u.airsim`），没有卸载或清除数据。`devicectl` 确认版本 170，启动命令成功；主 App、Widget、Watch 的构建版本一致，深度签名和 9 个 Mach-O 的 Date 导入检查通过。安装日志对应 `/tmp/airsim-170-device-build.log`，本地签名配置覆盖 build 号，仓库版本号未变。本次只安装 iPhone，安卓和 U30Air 未更新，三种链路运营商语音仍待配合新 Agent 手动验收；未提交、推送或发布。

## 170 实机反馈后的客户端兼容修复

用户反馈 U30Air 云端对方拒接后的运营商公告消失，并且扬声器切换无效。读取 iPhone 的诊断记录（仅状态，不读取/保存通话音频）确认：两次呼出收到 R21 `EARLY_MEDIA`，完整 call_id/call_uuid/generation 存在，但 170 只识别 `early_media_ready_v1`，未启动早期接收引擎。设备已发布 R21 与新源码协议不同，不能要求用户先升级尚未发布的 Agent 才恢复旧功能。

客户端现在同时识别 `early_media` 与 `early_media_ready_v1`，两者都要求当前呼出 connecting 和精确完整身份；迟到、错通话、已接通/结束状态一律不能授权早期流。无须修改 Relay 或 U30Air 已发布包。

输出路由修复：云端 CallKit 准备统一走共享音频控制器，避免提示音控制器未获知系统会话所有权、重新切换成 playback 类别；CallKit 激活时补记所有权。云端引擎开始/早期切双向时恢复用户扬声器选择，云端重新准备不再强制清除输出覆盖。扬声器重试任务添加独立代次，旧任务收尾不会清掉新任务；新增仅包含请求/实际路由、类别、错误码的诊断。日志未记录旧版按钮点击的路由失败原因，因此扬声器实机根因尚不能单凭上述代码缺陷完全确认。

新增测试验证旧/新状态、完整身份、通话阶段约束，以及假系统路由下的扬声器选择、重建恢复和回听筒；不调用真实拨号或录音。171 包构建与最终安装结果后续记录。

171 最终结果：9 项早期媒体定向测试及完整 **498 项 iOS 单元/集成测试通过，0 失败**（`/tmp/airsim171-full-retry.log`）。首次测试服务未启动用例，重启该模拟器 testmanagerd 后执行通过。设备构建、深度签名、9 个 Mach-O 的 Date 导入检查通过。已覆盖安装 iPhone Air 并成功启动 **0.9.8（171）**，保留应用数据；未部署 Worker、未更新 U30Air/安卓、未发布。运营商公告恢复和扬声器实机切换仍待用户手动复测。

## 171 后续扬声器反馈与 172 本机播放恢复

用户确认 U30Air 云端早期媒体已恢复，但扬声器按钮亮起后声音消失或仍未从扬声器播放。读取 171 真机状态日志可见：CallKit 激活、云端接收引擎从 Receiver 启动，随后 SPEAKER_REQUESTED → SPEAKER_CONFIRMED，实际端口为 Speaker，类别一直为 PlayAndRecord/VoiceChat。可确认系统接受了切换；该日志没有旧引擎停机采样，不能把“引擎停止”写成已经实机证实的唯一根因。

代码缺陷：云端 PCM 引擎没有响应 AVAudioEngineConfigurationChange 和输出路由/格式变化；播放图绑定建立时的硬件格式，停机后 drainPlayback 不再排队，而原播放窗口也可能仍保留失效缓冲计数。172 为此增加串行队列上的恢复：

- 合并路由与引擎配置通知，按新硬件格式重建本机音频图，清除旧播放窗口、抖动缓冲与捕获回调代次；不重连 WebSocket、不发送 answer/dial、不改写通话接通时间。
- 保留 receiveOnly 与静音意图。早期媒体重建仍不创建输入 tap、语音处理输入或上行定时器；只有已有双向阶段才恢复麦克风链路。
- 最多三次本地恢复（等待 150/350/750 ms）；CallKit 停用、挂断、阶段替换会使排队恢复失效。旧引擎通知不能影响新引擎。前台启动/健康重试若先恢复，也会清除旧图和旧恢复任务。
- 记录 route_recovered/route_recovery_failed、真实端口、receive_only、engine_running 和错误码；不采集音频。引擎运行不等于用户已经听到声音。
- 新增四项确定性调度测试覆盖通知去重、停用、阶段/通话替换、三次重试上限、瞬时失败恢复和取消待执行重试。

实机待验收：由用户手动在 U30Air 云端运营商公告期间及已接通双向通话期间切换“扬声器→听筒→扬声器”，检查下行持续、正常通话上行、主动挂断后不恢复播放。无需本次更新 U30Air 或 Worker。自动测试不代替此项真机声学验收。

172 验证：13 项定向测试通过；最终源码完整 **502 项 iOS 测试通过，0 失败**（`/tmp/airsim172-full-final.log`）。首轮全量的三项 UI 失败均是取不到 UIWindowScene，恢复测试宿主前台窗口后完整通过，未跳过测试或修改断言。真机构建成功（`/tmp/airsim-172-device-build.log`），主 App/Widget/Watch 均为 0.9.8（172），深度签名、9 个 Mach-O 的 Date 导入检查与 diff 空白检查通过。源码版本号仍未调整，本地 xcconfig 覆盖 build 号；未提交、推送或发布。

172 已覆盖安装到 iPhone Air，保留应用数据，启动成功；devicectl 查询实际安装版本为 0.9.8（172）。首次安装出现设备远程连接错误，重试成功。没有替用户拨号或录音，扬声器实际出声仍待用户复测。

2026-11-05 用户回报 172「实测通过」，确认本轮 U30Air 云端扬声器修复可用，并授权提交、推送、GitHub Release 和 TestFlight。此反馈不扩展为所有机型、所有运营商或全部传输组合已实测。
