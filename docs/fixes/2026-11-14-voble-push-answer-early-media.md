# VoBLE：PushKit 接听路由与早期音频恢复

## 用户报告与证据范围

蓝牙模式收到 CallKit 来电时提示“本地链路不可达，云端语音中继已关闭”；拨出时听不到运营商接通前音频。截图证明错误提示和所选模式，不能证明已经通过云端执行接听。本次没有取得故障手机同步日志，也没有进行真实拨号。

源码确认了以下路径缺口：

- PushKit 先到、BLE 通话身份尚未恢复时，AppModel 的旧接听入口仅探测 VoWLAN，然后用 WLAN/Relay 策略选路。该策略对 Bluetooth 返回 nil，因而产生与蓝牙无关的云端错误。
- SwiftUI 尚未建立时的冷启动 CallKit handler 原来根据云端开关和推送中的 media URL 接听，没有先尊重 Bluetooth 模式。
- 蓝牙重新认证后的 `device_info` 原来不补发已经响铃的通话，错过初始事件便缺少可安全接听的通话身份。
- VoBLE 早期媒体只尝试一次。若 iOS 的媒体归属尚未完成，或安卓尚处于 CONNECTING / 选卡阶段，首次请求失败后不会恢复。安卓 TelecomStateMapper 把 CONNECTING、选卡和 DIALING 都映射为 dialing，而事件去重可能抑制后续同名状态；因此不能依赖另一个 dialing 事件恢复。

最后一项是源码和可控回归能复现的原因之一，不能据此认定所有机型无早期音频都由它导致。

## 修复行为

1. 显式 Bluetooth 模式下，PushKit 仍可负责唤醒/CallKit 展示，但接听控制与音频使用 BLE。不向 VoWLAN 或 Relay 回退接听。
2. 等待对应已配对安卓恢复认证，并读取当前来电；只接受认证 Agent ID、精确 Telecom call ID、BLE generation 和 transport epoch 均匹配且仍在响铃的事件。不按电话号码、时间或当前选中设备猜测。
3. 接管时保留推送的 CallKit UUID、展示 call ID 和 generation；BLE generation 独立校验，不能把 Relay generation 当作 BLE generation。
4. BLE 先到的来电也复用 Telecom UUID，与现有安卓 APNs UUID 对齐；另一设备的 UUID 冲突仍不复用。
5. 安卓在已认证的 `device_info` 请求中重放仍然 RINGING 的通话事件，保留已有 generation。不补发已结束通话，不接听、不拨号。
6. 早期音频只对“媒体归属尚未就绪”或明确 `early_media_not_ready` 进行有限重试：250 ms 间隔、最多 24 次重试。该错误仅在 PCM 尚未打开、同一未接通呼出仍在准备时返回。旧设备的 unavailable、不支持、超时等不自动重试。
7. 重试不调用 dial，不伪造 active，不提前计时；接收链路仍为 recvonly。挂断、接通或身份替换会使迟到响应失效。首次运营商音频到达时停止本地等待音，不停用共享音频会话。
8. 蓝牙未恢复时提示蓝牙服务/链路问题，去掉误导性的三星/云端接听提示。

## 协议与兼容性

- 本次 VoBLE 修复没有修改 HTTP POST API、Worker 或 AVF 协议。
- Android Standalone 的 BLE `start_early_media` 增加失败 code `early_media_not_ready`。成功仍必须是 `early_media_ready_v1`，音频仍使用现有 nonce 派生密钥和 recvonly PCM 握手。
- `device_info` 会补发现有格式 `call_state`，旧 iOS 能忽略或按原格式处理。
- 需要 iOS 与 Android Standalone 配套更新，才能完整覆盖冷启动恢复和准备阶段重试。旧安卓仍兼容，但不保证重连后补发状态。
- 不保证所有 ROM/基带提供运营商下行采集，也不保证运营商每次拒接都播放公告。AVF 后端仍需要其本身的早期媒体能力；本次没有伪装它已支持。
- 工作树另有独立的 Relay SIM 选卡修复，本次保留；该项的三端部署要求见同目录 relay-sim-selection 文档。

## 验证

- `sh iOS/scripts/test-voble-recovery.sh`：运行真实 VoBLECallCoordinator 和身份匹配策略，Bluetooth、音频设备及诊断替换为测试桩。覆盖准备失败后成功、晚到媒体归属、旧端拒绝、超时不重试、重试上限、结束后迟到响应、接通时迟到早期响应；每种只拨号一次。
- `sh android-standalone/test.sh` 完整回归通过（退出码 0），包含实际 gateway 的准备阶段拒绝、响铃重放、早期媒体 TCP、拨号归属、纯本地出口和 APK 清单校验；不操作真实电话。日志 `/tmp/airsim-voble-android-all.log`。
- XCTest 新增 BLE Push 身份隔离、展示 UUID 保留、只选 BLE backend，以及早期媒体重试断言。
- iOS arm64 simulator build-for-testing 已通过，包含新增 XCTest 的编译；本次没有完成模拟器 XCTest 执行，不把编译成功记为执行成功。
- 生产协调器 7 组无模拟器回归与身份隔离检查已通过，日志 `/tmp/airsim-voble-recovery-tests.log`。网关定向测试通过，日志 `/tmp/airsim-voble-gateway-tests.log`。

## 真机待验收

1. 两端升级，选蓝牙，关闭云端语音中继但保留允许的来电通知。由用户拨入，锁屏 CallKit 接听应走 BLE，不出现云端错误。
2. 蓝牙暂时断开后恢复，来电仍在响铃时应能匹配原通话接听；另一手机、旧通话或已结束来电不能被接听。
3. 拨出后让对方拒接或等待运营商公告：有可采集公告时能听到，未接通前不计时、不上传麦克风；整个过程中只能产生一次拨号。
4. 公告期间对端真正接听，切换双向通话；用户挂断、对端挂断和扬声器/耳机路由不回归。
5. 旧版或不支持早期媒体设备仍正常接通，不能无限重试、自动重拨或伪造运营商提示音。

2026-11-14 已覆盖安装 Android Standalone Debug 到 Redmi 9（M2004J19C），保留应用数据，安装后已启动。版本仍为 0.9.8.24 / 135；设备 base.apk 与本地新包 SHA-256 一致：`ce6a3c5762e64385567f9f9c4384420ac262b608a57f30e9c4ecc332b7680312`。

2026-11-14 已将包含本次修复的 iOS Debug 覆盖安装到 iPhone Air，版本仍为 0.9.8 / 175，Bundle ID 为 `com.eric3u.airsim`，保留应用数据。真机构建和签名校验通过，devicectl 返回安装成功。

未部署或发布。两端均已安装修复包；真实声音和锁屏接听仍需用户验收。


## 追加：CallKit 冷启动恢复（2026-11-14）

实机持久化日志确认：15:33:42 开始接听，15:33:49 原 6 秒等待失败；
15:33:51 蓝牙连接尝试超时后重试，15:33:55 蓝牙连接成功，
15:33:57 才收到认证后的 ringing 状态。不能据此将原因简单归为“后台没有播放静音”；
原等待预算确实短于实际连接、认证和来电恢复过程。

本次 iOS 调整：

- 蓝牙控制器初始化期间保留已选配对目标；poweredOn 回调立即尝试恢复，
  不在 unknown/off 状态创建一个实际没有发送连接请求的 connecting 会话。
- 去掉 ensureConnected 中重复的连接调用，统一经 Hub 重连入口执行。
- 接听恢复采用单调时钟、最多 35 秒预算，覆盖连接重试和认证；就绪即继续，不固定等待 35 秒。
- 只在认证设备、通话 ID、BLE generation/epoch 与当前 PushKit 展示匹配后发送一次接听。
  挂断、终态、展示被替换、推送过期或任务取消后停止，不回退 Relay，不提前标记 active/开始计时。
- device_info 查询异步执行，每个认证 epoch 一次；查询本身不阻塞取消与总期限。
- 恢复期间显示“正在恢复蓝牙连接，请稍候…”，记录恢复耗时，便于下次实测定位。

验证：生产恢复等待代码的 5 个可执行回归通过（16 秒冷恢复、超时、身份失效、
已经就绪、取消），原 7 个生产 BLE 协调器场景与身份隔离回归通过。
新增 XCTest 覆盖 unknown→poweredOn 立即恢复指定设备及 stopped 后不被回调复活。
完整模拟器 XCTest 运行仍未验收，不能将上述纯逻辑回归视为真实蓝牙/CallKit 验收。

复测：App 关闭后由用户手动拨入，系统接听后等待蓝牙恢复；确认不再在第 6 秒报错、
只接听对应来电、双向声音正常；恢复中挂断后不得在蓝牙就绪时自动接听；安卓蓝牙关闭时
应有界失败。测试不自动发起电话。本次不需要 Android 或 Worker 协议变更。

安装记录：本次冷启动恢复修复已通过 iPhone Debug build-for-testing（包括新增 XCTest 的编译，
不是执行通过），签名校验通过，并覆盖安装到 iPhone Air，版本仍为 0.9.8 (175)。
安装 UUID 为 FA9746D2-3B8D-44A5-A8EF-63EA6038ED4B，保留配对数据。
此次真实关闭 App 后接听、恢复中取消的验收仍待用户手动执行；未发布 Release/TestFlight。


## 再次复测：仍然“模块连接中”（15:51）

读取 iPhone 持久化日志：15:51:14 开始 35 秒恢复；15:51:23、34、46 三次
connecting 超时，15:51:49 结束等待。此窗口没有 connected / authenticated / ringing
BLE 回调。35 秒上限实际生效，但未解决底层连接失败。扫描发现一台广告设备，现有日志
没有证明它是否匹配已保存的 peripheral，不能据此断言安卓服务正常或已连接。

新增修正与诊断：
- 通话页连接标识按当前来电归属设备的 BLE 认证状态显示；不再仅判断 VoWLAN/云端，
  也不拿另一个选中设备的在线状态冒充来电设备在线。
- BLE 冷启动不再因为 CallKit 已接受接听按钮就推断 active；等待设备实际通话状态。
- 记录发现设备是否为已知/当前目标（布尔值，不记录密钥或号码），辅助区分缓存地址与广播目标。

安卓现场仍待读取：旧无线 ADB 192.168.31.64:34047 返回 connection refused，mDNS
未发现设备；已请求用户提供新的连接端口。在取得安卓 GATT/广告日志并完成双方实测前，
不得宣称冷启动接听已经修好，也不得继续单纯延长等待预算。

本轮显示/诊断修正已通过 build-for-testing 编译与最终真机构建，并已覆盖安装 iPhone Air
0.9.8 (175)，安装 UUID C55E13BE-CCE7-4D81-8672-39EF8909D5BA。新增 XCTest 为编译通过，
未宣称执行通过。底层连接失败仍待安卓当前无线 ADB 地址和现场日志，尚未验收解决。


## 地址轮换调查与恢复协议

红米无线 ADB 实际地址 192.168.31.64:46355；安卓持久化日志显示 15:50:07 GATT
断开，之后没有新的连接成功回调，系统中 AirSIM GATT 服务仍注册。
iPhone 新增诊断在 15:57:46、16:00:38、16:08:23、16:15:30、16:23:03、16:30:34
不断发现 unknown / non-selected 广播目标；原 Hub 只连接记录中的固定 peripheral UUID，
无法恢复隐私地址变化后的设备。不能仅以同名或 RSSI 为依据自动绑定。

实现：
- Hub 对当前已配对、尚未就绪的目标，串行探测最多 3 个未知地址；通话/媒体运行时不探测。
- Android BLE pairing begin 增加可选 address_recovery_proof，用原配对密钥对
  domain=AirSIM/VoBLE/v1/address-recovery/ + challenge ID + 标准长度前缀 transcript
  做截断为 16 字节的 HMAC-SHA256。transcript 的 iPhone public/nonce 均为 32 字节零值，
  Android identity/public/nonce 使用该挑战真实值。
- iOS 恢复候选必须匹配指定 Agent，并用安全存储中的旧密钥验证 proof；再走原 reconnect_tag
  与 DH ready 确认流程。缺密钥、证明不匹配或旧端没有证明则拒绝，不进入 SAS 新配对流程。
- 认证成功后才保存新的 peripheral 映射、切换选中会话并停止旧地址重连。候选认证失败会断开，
  后台候选也受连接/认证超时限制。旧客户端忽略新字段；旧 Android 保持原地址连接兼容，
  跨地址恢复需要升级。
- 不改 HTTP/Relay API，不改 U30Air Agent；这是 Android BLE 握手的可选扩展。

验证：独立 Python HMAC 向量同时约束 Java/Swift；执行真实 Swift pairing worker，覆盖
有效证明、错误身份、缺失/伪造证明、nonce/challenge 改变、缺少密钥与旧显式配对兼容。
安卓 Standalone 全套测试通过并生成 APK；iOS build-for-testing 通过，含 Hub 地址迁移
和现有来电路由测试编译，未将其表述为 XCTest 实机运行通过。原 12 项生产 BLE 恢复/媒体
逻辑场景及身份隔离回归通过。

已覆盖安装两端，保留配对：iPhone 0.9.8 (175)，Android Standalone 0.9.8.24 (135)。
正在验收无需重新配对的连接恢复；尚未发起真实通话。

### 连接恢复实机核对（16:47–16:50）

用户解锁打开 App 后，两端日志已证实无需重新配对恢复：
- iPhone 16:47:35 发现未知 peripheral，16:47:36 CONNECTED，16:47:38
  ADDRESS_RECOVERY_AUTHENTICATED；Android 对应 08:47:35Z GATT connected、
  08:47:37Z begin、08:47:38Z confirm，未进入 prepare/SAS 新配对。
- 最终后台候选期限修正重新构建并覆盖安装，安装 UUID
  BAE704BA-48A2-43B1-A2C6-2DE0144F14D7，数据库序号 3520；启动成功。
- 最终包重启后，16:50:18 发现 known_peer=true，Android 08:50:21Z
  begin/confirm 完成，说明新地址映射和配对凭据已持久化并可复用。

这验证了蓝牙地址恢复与重启后认证，不等同于关闭 App 后 CallKit 接听、双向媒体、
恢复中取消均已验收。安装窗口出现 ringing 记录，不作为完整通话验收证据；
真实来电、接听与声音结果仍需用户在最终包上手动复测。本轮未主动拨打电话。

## 早期音频断续：16:57 实机日志与发送队列修正

用户反馈 VoBLE 早期媒体比接通后的语音明显卡顿。读取同一轮两端现有日志（未采集或保存音频）：
- iPhone 16:57:41 至 16:57:57 的 recvonly 统计 received 从 37 增至 322，
  concealed 从 0 增至 123，invalid/replay/late 均为 0。收到的有效帧数明显不足
  20 ms 音频帧的连续播放需求，且有序列缺口；这不是鉴权失败或单纯音量偏低。
- Android 同期 PCM 下行持续增长约 16000 bytes/s（8 kHz 单声道 PCM16），上行为 0。
  采集仍在持续工作，但不能据帧数证明每一帧的声音质量。
- 早期与接通后均使用 G.711 μ-law / 8 kHz，没有单独降低早期媒体编码质量。

发现 GATT 音频入口只允许一个完整帧（含正在发送）存在。下一帧依赖 PCM producer
每 5 ms 重试入队，发送完成回调通常没有下一帧可立即发送。将此处改为最多 4 个完整帧
（80 ms 音频内容，非对实际传输延迟的承诺），保持一次仅一个平台通知在途，由
onNotificationSent 直接续发。按完整帧的末分片计数，避免低 MTU 时误把碎片算成音频帧。
不改媒体协议、加密、麦克风权限、通话 active/计时规则，不用发送麦克风音频维持早期链路。
停止时增加只读计数日志：receive_only/downlink_frames/uplink_frames/dropped_frames。

真实 GATT 实现配合平台回调 fixture 的定向测试已执行通过：有界突发、回调立即续发、
帧顺序、分片完整性、部分发送不释放槽位、发送失败传播与恢复。
这一修正消除了软件补队空档；是否还有无线连接间隔或设备栈吞吐瓶颈需后续实机复测，
不能将回归测试通过视为已验证主观清晰度或所有早期媒体丢帧均已解决。

本轮 `android-standalone/test.sh` 全套执行通过，`git diff --check` 通过。
确认红米两张卡 call/ringing/foreground state 均为 0 后覆盖安装成功，配对数据保留。
APK SHA-256：4ee441f89d878d83c952a99e5a164082b4b36458e2696032d85dfdcaf4fe581a。
本轮未改 iPhone 二进制或部署 Worker，未提交/发布；待用户手动验证早期公告连续性、
接通后双向声音、挂断后停止播放。若仍卡顿，应依据两端新增计数继续检查无线吞吐，
不能仅扩大 iPhone 缓冲来掩盖持续帧丢失。

## 第二次质量修正：协商音频通知合包，同一编解码/播放路径

17:03–17:04 用户新实测证实仅调整排队还不足：iPhone 早期音频仍累计 104 次补偿，
Android 收尾统计 downlink_frames=413、dropped_frames=126、uplink_frames=0。
因此不能把上一轮有界队列修正报告为已解决主观音质。

新增兼容扩展：
- iOS 在已认证的 start_early_media 和 start_media 请求正文中加入
  `audio_notification_batch_v1: true`；该字段包含在原控制消息认证范围内。
- Android 仅在通过原通话身份/代次和早期状态校验后启用合包；没有该字段的旧客户端
  使用原逐分片通知。断连/关闭清除协商状态。旧 Android 忽略字段并正常发送原格式。
- 不改变音频帧：G.711 μ-law / 8 kHz / 单声道 / 20 ms，以及每帧独立 AES-GCM
  sequence/timestamp/tag 均保留。仅合并队首相邻音频分片，受 MTU-3 与 512 字节双重限制。
  MTU 517 时能在一个 ATT 通知中携带两帧（388 字节）；MTU 247 时自动仍为单帧。
  不等待额外帧来凑包；控制 indication 不合入音频，平台同时只允许一个通知在途。
- iOS 先校验整个通知的长度和分片边界，再逐帧走原重组、AEAD、去重、抖动缓冲、
  G.711 解码与播放流程。一次通知内出现畸形尾部，整个通知拒绝；独立帧的坏 tag
  仍独立拒绝，不能绕过原鉴权。
- 接通前仍只读 Telephony Rx，不创建/发送麦克风上行、不伪造 active、不提前计时。
  接通切换保留原会话 epoch 与独立 early media key 隔离；迟到早期帧不能播放到正式通话。
- 统计新增 notifications / batched_notifications，便于分清合包是否在真机实际启用。

已执行的定向验证：
- 真实 Swift 媒体生产代码：相同测试语音经不同 early/active 密钥传输后，解码 PCM
  逐帧相同且无补偿；验证早期不发送上行、旧单帧格式、畸形/超长通知、逐帧 AEAD、
  接通切换后迟到帧隔离。脚本 iOS/scripts/test-voble-media-parity.sh。
- 真实 Android GATT 实现配合平台 fixture：合包、旧客户端回退、低 MTU 回退、
  通知失败恢复、重连清除能力、控制 indication 边界；确定性 20 ms 音频生产/
  40 ms 通知完成的模型能无丢失传输 100 帧并减少通知数量。
- 上述是协议和软件调度验证，不代表真实 BLE 连接间隔、无线丢包或运营商源音质验收。

此扩展仅影响 Android/iOS BLE 媒体封装；HTTP/POST、Relay 和 U30Air Agent 接口未改变。

安装与完整检查记录：
- iOS 最终 build-for-testing 成功，codesign 校验通过；生产媒体 parity 脚本、原 12 项
  恢复/媒体协调回归和身份隔离均执行通过。XCTest 为编译通过，未声明模拟器执行通过。
- Android 套件首次在旧网关生命周期 fixture 处因空 JSON / 未提供 GATT 实例而中断；
  fixture 按真实协议补齐 `{}` 正文和 GATT 后，该项重跑通过。之前已通过的核心/音频桥/
  云端测试及 APK 构建，加上之后补跑通过的 owned-dial、pure-local、manifest 校验，
  覆盖完整原检查清单。新增 GATT 合包/吞吐/控制边界测试也执行通过。
- 确认安卓空闲后，iPhone 覆盖安装成功，安装 UUID
  29766ED6-72E1-44BA-88D0-EF89855ACF18，数据库序号 3528。
- 红米 Standalone Debug 覆盖安装成功；SHA-256
  409b9bf0d319ea28467ae61560c3499a9d7a4de958159e0460dd744621dd0049。
- 保留原配对；未发布 Release/TestFlight，未部署 Worker。接下来需用户手动复测，
  核对 batched_notifications、Android dropped_frames 与实际公告听感，不自动发起电话。

## 合包真机联测：2026-11-14 17:24:50–17:25:16（UTC+8）

用户手动呼出，双端同步读取持久化日志；没有录制音频。通话代次 9。
- Android 17:24:51.618：receive_only=true，notification_batch=true。
- iPhone 17:25:14.595 最后一个媒体样本：received=474，notifications=412，
  batched_notifications=62；因此协议协商与实际合包都已生效。
- 同一样本：replay=0，late=0，invalid=0，skipped=6，concealed=133，
  capture_buffers=0，input_format=recvonly。iPhone 自身 dropped_frames=0
  不能当作全链路没有缺帧；concealed 表明序列缺口仍需补偿。
- Android 17:25:15.284 收尾：downlink_frames=517，uplink_frames=0，
  dropped_frames=148。这里 dropped_frames 是应用发送队列在期限内未接受的帧计数，
  不是直接测量的蓝牙空口丢包率。iPhone 最后样本早于收尾，不能简单用两端总数相减
  来宣称剩余帧在无线链路丢失。
- iPhone 正常 ended/释放音频；本段没有 active，未提前接通或打开麦克风。

结论：合包实际生效，但没有解决早期媒体持续缺帧，不能宣称已达到正式接通后的质量。
下一步重点需测 Android 通知完成节奏、队列/回调状态和只下行连接参数；单纯扩大
iPhone 缓冲不能补回安卓已丢弃的样本。此窗口尚无正式接通媒体样本，不能作同时段
早期/接通质量的量化对比。
脱敏事件记录：/tmp/airsim-voble-livecheck/20261114-172308/events.jsonl。

## 发送瓶颈分项诊断（后续优化，尚待新实测）

前两次质量改动尚未消除持续丢帧。本轮先保持合包、队列容量和 100 ms 入队期限不变，
增加只读边界统计，避免在缺证据时继续扩大缓冲：
- attempts/accepted/queue_full/not_subscribed/previous_failure/send_rejected 区分拒绝位置。
- callbacks/callback_errors/last_status、回调平均/最大耗时及超过 40 ms 次数区分平台
  失败与慢回调；日志约每 2 秒一次，收尾有最终快照，不包含密钥、号码、音频内容。
- GATT 定向测试验证队列满与回调错误不会混淆；网关生命周期回归通过，Standalone
  构建通过，确认红米空闲后已覆盖安装并启动。iPhone 未变更。
- 新一轮抓取：/tmp/airsim-voble-livecheck/20261114-181613/events.jsonl。

实现继续遵循 Android 官方 onNotificationSent 约束：收到上一通知的完成回调后再发送
下一通知，不能用无界并发通知来掩盖吞吐瓶颈。
参考：https://developer.android.com/reference/android/bluetooth/BluetoothGattServerCallback#onNotificationSent(android.bluetooth.BluetoothDevice,int)
本轮尚未得出新的根因结论或声称听感改善；需要用户在诊断版上手动复现。

## 诊断实测：18:16:56–18:17:19（UTC+8）与下一轮定向实验

用户手动测试，通话代次 11；上节“尚待新实测”状态在本节更新。
- Android 协商 receive_only=true、notification_batch=true。
- 最终 attempts=2271、accepted=382、queue_full=1889；not_subscribed、
  previous_failure、send_rejected、callback_errors 均为 0。
- callbacks=336，平均 39 ms，最长 519 ms，超过 40 ms 共 26 次；过程中
  反复出现约 500 ms 停顿。收尾 downlink_frames=382、dropped_frames=97、uplink_frames=0。
- iPhone 最后样本 received=292、notifications=258、batched_notifications=34、
  concealed=70、skipped=1，replay/late/invalid 均为 0，capture_buffers=0。
  该样本早于安卓收尾，不能按两端总量相减推断空口丢帧。
- 证据定位到通知完成回调停顿/队列阻塞，未观察到平台拒发。尚不能区分控制器调度、
  无线环境或系统省电机制；更不能仅凭该日志认定某个厂商实现有问题。

下一轮只验证“纯下行时缺少双向活动导致调度停顿”的假设，不扩大音频缓冲：
- 已认证 start_early_media 请求可带 early_media_keepalive_v1=true；安卓通过
  原通话身份/代次、DIALING、早期能力检查后才返回 early_media_ready_keepalive_v1。
- iPhone 仅在该响应下启用 20 ms 空载加密保活，使用现有 AUDIO_UPLINK 特征、
  streamID=2、AES-GCM、早期 nonce 派生的通话密钥、单调 sequence/timestamp。
  空 plaintext + 16 字节认证 tag，不包含音频，也不是 PCM 静音帧。
- 安卓只有协商过的 receive-only 会话才接受该流；先校验调用身份、捕获许可、
  AEAD 和重放，再确认 streamID=2 且 plaintext 为空。不会解码、加入 PCM 队列或
  写入音频桥，不增加 uplink_frames。单独统计 early_keepalives。
- iPhone 保留接通前禁止 enqueueCapturedPCM；加密在串行媒体工作队列执行。
  流控未就绪时跳过，不积攒保活；最多一个在处理/待发送包。旧任务受会话 epoch
  隔离，挂断/接通/替换会话取消，最多 120 秒（不延长原早期媒体权限）。
- 新 iPhone + 旧安卓：收到 early_media_ready_v1，继续原接收行为，不发保活。
  旧 iPhone + 新安卓：无协商字段，继续原响应，不接受早期上行。
- 保持音频编码、批量通知、队列容量、接通状态和计时规则不变；没有 HTTP/POST、
  Worker 或 U30Air 接口变化。

回归：Swift 真实媒体代码先在“negotiated early keepalive never sent”失败后通过；
Java CoreTests 先在协商后有效保活被拒绝处失败，再通过。覆盖协商缺失、错误身份、
坏 tag、重放、非空/PCM 包拒绝、无桥上行、挂断停止、流控有界和正式通话隔离。
协调器同时验证旧 v1 与新协商响应。此项仍需新一轮真机测试回调节奏、丢弃/补偿计数
及主观听感；自动化通过不等于已消除卡顿。

保活实验版安装（18:26 UTC+8）：
- Android Standalone 完整 test.sh 退出成功，包括 Core、GATT、音频桥、云端通话、
  网关生命周期、纯本地和最终 APK manifest；存在 JDK 原有 native/final-field 警告。
- iOS 真实媒体 parity、8 项协调器场景、5 项来电恢复及身份隔离通过；
  build-for-testing 和 codesign 校验成功，未执行完整 XCTest/界面测试。
- 确认安卓 Telecom 空闲后，两端覆盖安装成功并启动，保留配对。
  iOS 安装 UUID 6272C8A1-0DB8-4AEC-9DE5-39B8A93F0B3F，数据库序号 3536。
  APK SHA-256 a9d358587f3e04e68cd16f6df1e7d84fd79d7c9bce48093973b0f404cf6b1f97。
- 新抓取目录 /tmp/airsim-voble-livecheck/20261114-182616；等待用户手动测试。

## 保活真机结果：18:28:11–18:29:37（UTC+8）

用户回复“ok”；已采集到通话代次 13 的完整媒体启动/收尾窗口，主观听感尚待确认。
- Android: receive_only=true、notification_batch=true、early_keepalive=true；
  最终接受 early_keepalives=3911，证明两端协商与认证接收均实际生效。
- 音频约 18:29:02 才开始产生；此前 received=0 不应当作网络丢帧。
- 最终 downlink_frames=1625、dropped_frames=77、uplink_frames=0。
  应用发送端丢弃占已处理帧约 4.52%（77 / (1625+77)），上轮约 20.25%
  （97 / (382+97)）。这是不同时长/通话样本的观察，非受控 A/B 因果证明。
- 回调平均 15 ms、最大 367 ms，超过 40 ms 共 65 次；平台拒发和错误回调为 0。
  初始约 6 秒音频的回调最大 13 ms，之后仍出现 193–367 ms 停顿。
- iPhone 最后媒体样本 received=1619、notifications=1442、batched_notifications=177、
  concealed=76、skipped=6、replay/late/invalid=0、capture_buffers=0、input_format=recvonly。
  Android 最终采样与 iPhone 最终采样时间不同，不能相减得出无线丢失数量。
- 未出现 active；18:29:36 正常释放音频。保持未接通、不采集麦克风。

结论：本次观测有明显改善，但未消除停顿，不能宣称已经达到正式接通音质。
前三轮队列、合包和保活改动不足以完成验收，后续应转向实时路径/调度边界分析，
不再凭猜测继续扩大缓冲或发送并发。
代码审查发现 GATT onCharacteristicWriteRequest 在 GATT monitor 内对每个上行包
调用 BridgeLog.info；开启 debug 时还会同步获取日志锁并打开/写入/关闭文件。
这构成可验证的阻塞风险，但当前统计在 onNotificationSent 获取 monitor 后才计时，
无法区分平台晚回调与应用锁等待。下一步应先分离 callback entry、monitor 等待、
notify API 耗时，再决定是否从实时锁内移除/聚合诊断 I/O。不能仅据源码把它认定为
本轮 367 ms 停顿的根因。

### 用户听感验收补充

2026-11-14，用户针对上述保活实验版明确反馈：“已经听起来流畅”。
因此本轮 Redmi 9 ↔ iPhone Air 的 VoBLE 呼出运营商早期语音，主观流畅度验收通过。
保留客观边界：本次日志仍有发送端丢弃/播放补偿与最长 367 ms 回调停顿，不能报告
零丢帧；未以此证明所有机型、后台/锁屏、长通话或弱信号场景均通过，也没有用该
早期媒体窗口替代正式接通双向通话的回归验收。本次确认不触发发布或额外安装。
