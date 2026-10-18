# VoBLE 真机测试矩阵

本文记录 `VoBLE` 分支的可复现验证证据。状态只表示表中明确执行过的项目；未连接的设备和未发生的真实电话不会被记为通过。

## 验证基线

- 日期：2026-10-13（Asia/Shanghai）
- 基线提交：`45ef904`，文档提交以本文最终提交为准
- Xcode：27.0（27A266a）
- iPhone Air：iPhone18,4，iOS 27.0（24A437），开发者模式已启用，经局域网配对连接
- Android：本轮检查 `adb devices -l` 为空，三星与小米均未连接
- Apple Watch：两台已知设备均显示 unavailable
- 隐私：记录中不包含电话号码、短信内容、配对密钥、nonce、认证 tag、Push token 或 PCM

## 自动化与构建

| 范围 | 命令 | 结果 | 产物或说明 |
| --- | --- | --- | --- |
| Android Bridge JVM | `./android/phone-control-app/test.sh` | 通过 | core、NotificationUpdateGate、call repository 均通过；覆盖 VoBLE 协议、认证和 PCM 队列 |
| Android Standalone 集成 | `./android-standalone/test.sh` | 通过 | `BridgeUnitTests checks=47`，随后完成 Standalone Bridge 构建/签名检查 |
| Android AVF Bridge APK | `./android/phone-control-app/build.sh` | 通过 | `android/phone-control-app/build/android/AirSIM-Phone-Bridge-debug.apk`，APK v3 签名验证通过 |
| Android Standalone APK | `./android-standalone/build.sh` | 通过 | `android-standalone/build/android/AirSIM-Android-Standalone-debug.apk`，APK v3 签名验证通过 |
| iOS 编译测试 | `xcodebuild build-for-testing ... generic/platform=iOS Simulator CODE_SIGNING_ALLOWED=NO` | 通过 | App 与 XCTest bundle 均成功编译 |
| iOS 运行时 XCTest | `xcodebuild test ... iPhone Air,OS=27.0` | 未形成完整最终结果 | 新增生命周期用例在运行中通过；CoreSimulator runner 随后消失/重启，不能据此宣称整套通过。此前 Task 6 基线曾完成 58 项通过 |
| iPhoneOS unsigned build | `xcodebuild build ... generic/platform=iOS CODE_SIGNING_ALLOWED=NO` | 通过 | arm64 App、Live Activity 与 Watch 目标编译成功；这是本地重签输入，不等同正式签名验收 |

## 真机安装与功能矩阵

| 设备/场景 | 状态 | 证据或阻塞原因 |
| --- | --- | --- |
| iPhone Air 覆盖安装（保留数据） | 通过 | 使用开发描述文件重签并覆盖 `AirSIM Diag`；`devicectl` 安装、启动成功，主进程与 Live Activity 扩展均存活；未清除 App 数据 |
| 三星 Standalone 覆盖安装 | 阻塞 | 本轮 `adb devices -l` 无设备，未执行安装或真实电话 |
| 三星 AVF Bridge + AVF PCM | 阻塞 | 三星未连接；未验证 AVF 地址变化后的下一会话解析 |
| 小米 HyperOS Standalone | 阻塞 | 小米未连接 |
| Apple Watch 镜像来电/停止响铃 | 阻塞 | Watch unavailable |
| Wi-Fi 关闭的 VoBLE 拨出/呼入 | 未执行 | 需要 Android 与 iPhone 同时在线并发生真实运营商电话 |
| 双向首包音频、静音、扬声器、DTMF | 未执行 | 同上 |
| 三秒内同 generation 恢复 | 自动化通过，真机未执行 | reducer/协调器覆盖；仍需真实 BLE 射频环境验证 |
| 超过三秒终止、错误密钥、撤销配对 | 自动化通过，真机未执行 | 仍需真机 UI 与系统行为验收 |
| 30 分钟队列/内存稳定性 | 未执行 | 需要持续真实通话，禁止用模拟结果代替 |

## 真机验收步骤

### Standalone

1. 用 `adb install -r android-standalone/build/android/AirSIM-Android-Standalone-debug.apk` 覆盖安装，禁止清除数据。
2. 确认默认电话角色、附近设备、通知、Shizuku 和 PCM 桥均正常。
3. iPhone 选择“蓝牙直连”，两端核对短码并确认。
4. 关闭两端 Wi-Fi，Relay 保持不可用；分别执行拨出和呼入。
5. 记录拨号响应、接听到首个音频帧、双向音频、静音、扬声器、DTMF、Android/iPhone 两端挂断，以及 Watch 是否停止响铃。
6. 通话中短断蓝牙少于三秒，只允许同 `call_id`/generation 恢复；再断开超过三秒，应结束媒体并清理 CallKit/实时活动。
7. 连续运行 30 分钟，观察 GATT 待发送队列、丢包、jitter、内存和电量；日志不得出现号码或密钥。

### AVF PCM

1. 覆盖安装 AVF Bridge，确认它与 Standalone 不同时持有默认电话角色。
2. 完成一通 VoBLE 双向电话并记录 AVF PCM 端点。
3. 结束电话后重启 AVF，使私网地址变化；下一通电话必须解析新地址。
4. 活跃通话期间不得原地切换端点；地址变化只作用于下一媒体会话。

### 小米与失败场景

在 HyperOS 上逐项检查后台限制、锁屏、错误密钥、撤销配对、Relay 不可用、VPN 开/关、Wi-Fi 关闭、iOS 强制退出后提示，以及蓝牙权限被撤销。VoBLE 模式不得因为 Relay/PushKit token 不可用而拒绝本地配对或拨号。

## 2026-10-13 晚间蓝牙音频复现与修复

- 三星 SM-F766U 已通过无线 ADB `192.168.31.203:38137` 接入，Standalone 前台服务正常；iPhone Air 使用保留数据的 `AirSIM Diag`。
- 修复前真实蓝牙呼出已到达 Android Telecom 的 `active`。PCM 下行持续增长，上行仅短暂出现静音帧；此证据不能算作双向语音通过。
- Android `STREAM_VOICE_CALL` 为静音，音频 HAL 收到 `setVoiceVolume(0.0)` 和 `l_volume_voice=0.0`，因此不能仅凭 App 的静音请求日志判断实际听感。
- iOS 临时呼出 ID 不再绑定 CallKit 后端身份，只在 Android 权威通话 ID 到达后同步。拨号响应晚于 Telecom 事件时，不再回写临时 ID 或把已接通电话降回连接中。
- BLE 音频会话现在区分 CallKit 与 App 自行激活，后者在麦克风授权后启用 `playAndRecord/voiceChat`；权限弹窗返回后重新读取 CallKit 的实际激活状态。
- 76 项 iOS XCTest 全部通过，iPhoneOS 构建成功；修复版已覆盖安装，主进程与实时活动扩展存活。调试日志新增引擎运行状态、采音/播放/丢帧计数，不记录号码、密钥或音频内容。
- 修复后的双向听感、三星实际静音、真实呼入和锁屏场景仍需真机复测，尚未记为通过。

## 2026-10-13 双向音频后的强干扰复测

- 用户真实呼出确认两端有声音，但干扰巨大，不能记为音频验收通过。
- iPhone 日志证明采音与播放引擎持续运行；约 36 秒内采集 1820 帧、调度播放 1650 帧、丢弃 1639 帧。播放计数包含补偿帧，不等于收到正常语音。
- 新增回归用例分别复现空缓冲持续推进序号、满缓冲拒绝新语音、长缺口重复旧语音；三项在旧实现均失败。
- 播放改为音频缓冲播放完成回调补帧，最多预排 60 ms；计时任务只负责启动或缺帧后恢复，不再作为 20 ms 音频时钟。停止/新通话时使旧完成回调失效。
- 空缓冲停止推进序号并重新缓冲；溢出保留最近八帧，较长缺口跳过过时语音，重放检测集合有界。79 项 iOS XCTest 全部通过。
- 诊断分别记录收到、重放、迟到、无效、跳过、补偿帧数；Android 增加 AudioTrack 实际输出设备类型日志。Samsung VOICE_TX 标签可用仍不能单独证明声音只送入蜂窝上行。
- iPhoneOS 编译、重签验证、iPhone Air 保留数据覆盖安装及启动通过；主 App 与实时活动扩展进程存活。三星 Standalone 覆盖安装通过，Shizuku 用户服务与 PCM 桥已换成新进程并监听 localhost。
- Android 核心、通知、通话仓库、47 项 PCM 桥检查与 Standalone 测试通过；首次并行构建因本机临时磁盘不足中断，iPhone 构建结束后串行重跑通过（现有 SDK/JDK 弃用警告仍在）。
- 新版的听感、实际输出路由和三星本机静音仍需真实电话复测；不以单元测试替代。

## 后续卡顿、状态与重新配对复测

- 用户确认蓝牙声音在 iPhone，但断续，通话页仍显示建立链路，清除配对后需开关系统蓝牙。
- 三星实际 AudioTrack 设备为 TYPE_TELEPHONY（18），Telephony Tx sink=true；双向 PCM 正常增长。iPhone 真机累计收到 1901 帧，无认证错误、重放或迟到丢包，播放跳过 83 帧。
- `dataPlayedBack` 包含下游 Voice Processing I/O 与播放设备的呈现延迟；60 ms 的有界流式队列改用 `dataConsumed` 补帧。真实 AVAudioEngine 离线渲染回归证明：原回调无法在没有设备呈现时补帧，新回调可在数据消费后触发。资料：[Apple 回调说明](https://developer.apple.com/documentation/avfaudio/avaudioplayernodecompletioncallbacktype/dataplayedback)。
- 通话状态按锁定传输读取蓝牙音频引擎，并订阅其状态更新，不再以 Wi-Fi 引擎/旧云端状态代表 BLE 媒体是否运行。
- iOS 等待旧连接的取消回调后才重新扫描或连接，忽略旧外设回调；原生自动重连保留目标外设重新发现服务。Android 本地清除认证同时关闭拥有者 GATT 连接，释放旧订阅。
- 新增 iOS 回归三项旧行为均失败，改动后整套 82 项通过；Android 撤销凭据关闭传输回归同样先失败再通过，Standalone 构建与测试通过。实际新版听感与重新配对流程仍待真机验收。
- 两端已保留数据覆盖安装：三星使用更新后的无线调试连接，iPhone Air 恢复在线后 `devicectl` 安装成功；未删除 App 或配对数据。新版日志已重新接上，仍需用户核对通话流畅度及取消配对后直接重新配对。

## 取消配对后的“尚未启动”

- 用户在后续验收反馈 iPhone 蓝牙 Agent 页显示“尚未启动”。真机配置仍为 bluetooth，Android 日志记录清除配对；不是用户切换回其他连接模式。
- iOS `unpairCurrentPeer` 删除双方凭据后只调用 `stop`，页面未重新出现，因此 `onAppear` 不会再启动扫描。统一配对取消/清除后的连接重置：原先启用则先停止旧会话再启动扫描，原先关闭则保持关闭；新扫描仍等待旧 GATT 断开回调，不绕过上一轮取消屏障。
- 新增回归捕获“只 disconnect、没有 scan”的失败，修复后全部 83 项 iOS 测试通过，iPhoneOS 编译通过。DEBUG 日志记录 enabled、状态和等待取消标志，不记录密钥、安全码或号码。
- 覆盖安装后真机已离开 stopped，但停在 connecting，且没有等待旧取消回调；Android 的 GATT 服务与可连接广播仍正常注册。缓存外设连接无超时，因此新增 8 秒连接看门狗：仅 connecting 超时才取消旧连接，收到取消回调后跳过缓存恢复、重新扫描；不打断 authenticating 或 ready，也覆盖系统原生重连等待。
- 超时策略回归先失败后通过，全部 84 项 iOS 测试及 iPhoneOS 构建通过；保留数据覆盖安装到 AirSIM Diag。仍需真机日志确认扫描和安全码认证恢复，不能据此宣称音频卡顿或重新配对验收完成。
- 真机进一步捕获 connecting 超时取消后未收到断开回调，等待屏障未释放。新增实际外设状态观察：只在同一旧外设已是 disconnected 时释放屏障，connecting/connected/disconnecting 和无关外设都不放行；最多观察 8 秒，仍未释放则显示明确错误，而不是强行建立重叠连接。
- 断开状态屏障回归先失败后通过，全部 85 项 iOS 测试、iPhoneOS 编译与签名验证通过；新版再次保留数据安装至 iPhone Air。
- 最新真机日志已经依次到达 connect_timeout → cancellation_finished → scanning → connecting → connected → authenticating；未开关系统蓝牙。首次认证进入 failed，随后 App 内连接重置再次完成扫描、连接、认证，最终进入 ready。已验证链路恢复与认证完成，尚不能视为通话听感验收通过。
- 随后收到本轮真实蓝牙通话日志：engineRunning=true，累计 received=1703、played=1676、captured=1685，replay/late/invalid/concealed 均为 0，skipped=23、dropped=9 在后半段保持不增长，结束时媒体引擎正常 stopped。双向音频数据流和结束清理有真机证据；具体听感及界面“蓝牙语音已连接”文字仍需用户确认。

## 纯蓝牙通话结束后的 call_mismatch

- 用户确认新版蓝牙通话正常，但两端关闭 Wi-Fi 和移动数据、仅保留 BLE 时，挂断后弹出 call_mismatch。不能将这一错误解释为 VoWLAN/Relay 不可达，也不能通过开启网络掩盖。
- Android 当前通话拥有权在权威 ended 事件时清空；此后到达的 end/reject 被视为 call_mismatch。现对记录过的同一 callID+generation 终态做幂等确认，不调用 Telecom，不影响下一通；未知身份与未认证命令继续拒绝。
- iOS 等待挂断回复期间可能先收到 ended，旧逻辑仍会发出 ending，或将迟到的错误弹到拨号页。现只在同一身份仍为当前通话时发布 ending；仅该身份已有认证的终态事件时才接受迟到挂断错误为已完成，不掩盖当前通话的真实错误。
- Android 回归覆盖 ended 先到、重复 end/reject、新通话隔离、未知身份和未认证拒绝，旧实现失败；iOS 使用真实通话协调器注入控制传输，复现迟到成功恢复 ending 和迟到失败弹错，两项旧实现失败。改动后 iOS 全部 87 项与 Android phone-control 全套测试通过。新增 DEBUG 通话状态/命令日志不记录号码、通话 ID 或密钥。
- Standalone 全套测试与 APK 构建通过，已保留数据覆盖安装到 Flip7；iPhoneOS 编译、签名验证及 AirSIM Diag 保留数据覆盖安装至 Air 成功。纯 BLE 的挂断弹窗是否消失仍待安装后的真机复测，未把回归测试当成实际验收。

## Android 默认通话卡（双卡 / 多卡）

- 在 Android 设置中新增「默认通话卡」：跟随系统默认，或显式选择已启用的蜂窝 SIM/eSIM 账户。使用本地私有存储保留选择，不修改系统默认通话/短信卡，不需要 Wi-Fi 或 Relay。
- VoBLE、Standalone VoWLAN/Relay、旧 AVF 命令入口及 Android 本机拨号统一使用所选 `PhoneAccountHandle`。拨号前重新检查可用账户，指定卡关闭、移除或电话状态权限撤销时返回明确错误，不自动换卡。
- 新增 8 项 JVM 回归，先验证缺失选卡功能导致失败，再实现并通过：默认跟随系统、持久化、失效卡/撤销权限、过滤停用与 VoIP 账户、共享拨号入口、可选号码与元数据权限、Android 29 兼容、三卡与列表顺序变化。
- Standalone 全套测试/构建及 AVF Bridge APK 构建通过。保留数据覆盖安装到三星 Flip7 成功；当前锁屏，选卡页面、双卡实际拨出及默认短信卡保持不变的真机验收仍待执行，不将 JVM 的 Telecom 参数检查视作真实运营商路由验收。

## 配对设备清理与换卡后的号码刷新

- iPhone 设置「配对三星手机」下方新增设备列表与逐个确认删除。历史只存设备标识、名称和 Agent 类型，不缓存号码；离线记录不被当作可拨号路由。
- 删除清除该设备的本机记录和绑定，并撤销对应 BLE 凭据；设备级拒绝标记防止旧广播、云端状态或迟到响应重新加入。在线 BLE 尝试远端 unpair；离线删除不宣称已撤销 Android/Relay 端授权。其他设备、通话和短信保持不变。
- BLE 改为从当前广播连接，不以缓存 UUID 直接恢复；认证后读取 `device_info`，校验身份，号码为空时显示未提供，不借用旧 VoWLAN/Relay 号码。VoWLAN 当前健康检查清空旧空值，旧会话迟到结果不能更新已删除或重启发现后的设备。
- Standalone 心跳不再使用首次注册的号码；Android 当前号码对应 App 所选通话卡或系统默认通话卡，停用、换卡和撤销权限均不借用另一张卡号码。旧 AVF Linux Agent 的云端心跳仍使用注册 metadata，未在本次迁移。
- 新增 5 项 iOS 回归，先复现空号码保留旧值、删除不持久化、身份不匹配、删除广播仍自动重连及离线凭据未撤销，再修复；最新整套 **92 项通过**，iPhoneOS 编译与诊断包签名验证通过。离线撤销测试保留真实 BLE 控制器，仅替换凭据存储边界；unsigned Simulator 无 Keychain entitlement（-34018），未将内存测试称为真实 Keychain 验收。
- Android 当前 SIM 身份测试先因错误选择第一张卡而失败，修复后 phone-control、Standalone 全套和 AVF Bridge APK 构建均通过。新版已保留数据安装到 Flip7 与 iPhone Air 的 AirSIM Diag；iPhone 锁屏，启动被系统拒绝（Locked），新列表显示、真实换卡与用户设备删除后重新配对仍待真机验收，未删除真实设备记录测试。

### 2026-10-14 诊断包启动闪退补验

- 用户解锁后发生启动闪退；Air 真机 `AirSIM-2026-10-14-010451.ips` 显示 DYLD 在进入业务代码前终止，原因是 `AirSIM.debug.dylib` 未签名。同次 Live Activity 扩展崩溃为 `AirSIMLiveActivityExtension.debug.dylib` 未签名，不是设备列表或历史数据异常。
- 对旧包两个 Debug 动态库单独执行 `codesign --verify --strict` 均失败，确认包根目录的 `--deep` 验证未覆盖此遗漏。重新签名全部四个内嵌动态库（含两个 preview），逐个验证，再签扩展和主 App；不改业务代码、不清除数据。
- 修正版覆盖安装成功，Air 真机 console 已执行主 App 初始化并恢复 BLE `ready`；间隔复查主 App 与实时活动扩展进程仍存活。用户确认「能打开，列表正常」，设备列表真机显示已验收；实际换卡与真实删除仍待测试。最新 iOS 全套 92 项测试通过（0 失败）。另见 ActivityKit `SessionCore.PermissionsError Code=3`，不将启动修复表述为实时活动权限问题已解决。

## Shizuku 启动检查弹窗

- Standalone 与 AVF Bridge 共用启动检查：系统权限流程结束后，按未安装、未运行、未授权分别提供官方下载、打开管理器、授权入口；已就绪不弹窗，当前 Activity 启动及其配置重建最多提示一次。外部页面返回继续原启动流程，闪退报告延后到启动引导结束，避免与权限或初始化提示叠加。
- 新增真实启动策略回归，初始实现先复现 `expected INSTALL but got NONE`；修复后覆盖三种提示、就绪静默、后台不消耗检查、返回不重复及配置重建不重复。完整 phone-control、Standalone 测试和 47 项音频桥检查通过，两种 Debug APK 构建并验证签名通过。构建仍有现存 Android API 弃用、Java serial 与 JDK native-access 警告，无编译错误。
- 本轮只生成 APK，未覆盖安装、卸载 Shizuku 或撤销三星授权。缺失安装、未运行及未授权弹窗的真机视觉与操作验收仍待执行，不能将 JVM 策略测试视为系统权限弹窗验收。

## 已知边界

### 2026-10-14 兼容风险审查修复与本次配对开关（未发布）

- Redmi Android 12 的旧包在 VoBLE 页因 `ByteArrayOutputStream.writeBytes` 缺失崩溃；配对/分片重组等九处改为兼容写法。VoBLE 前台服务启动受系统限制时记录失败并等待前台重试，不因 `IllegalStateException` 或权限撤销竞态终止 App。此前签名修复包保留数据覆盖安装后，用户确认可以完成配对。
- 后续六项审查风险已修复：Shizuku 输出的 API 35 `isEmpty`、URL Charset 重载、短信 API 31 工厂、PCM 失败路径空流、AVF API 34 启动选项，以及旧 OEM 无 `cmd audio` 实现。官方 NewApi 扫描不再报告本轮缺失 API；完整扫描仍保留四项既有权限诊断和三项常量警告，不宣称完整 lint 全绿。
- 静音使用 shell 包身份的 `AudioManager`，回读验证后才报成功；挂断恢复初始静音与音量，失败保留快照重试。回归覆盖系统忽略 mute、原先已静音、重复 mute、解除静音失败、解除成功但恢复音量失败，后者不再误报已静音。测试替换平台音频边界，未改变真机通话音量。
- Android 共享与 Standalone 测试通过，包含 API 29–35 短信工厂分支和空服务回退（不发送短信）；47 项 PCM 桥检查通过。AVF/Standalone Debug 构建通过；编译仍有弃用等警告。
- Redmi 使用 `app_process` 加载新构建进行蓝牙分片、加密、服务拒绝/重试、URL 查询/PCM 失败清理/Shizuku 输出及音频后端只读检查；旧已安装包的 URL 解码先复现 `NoSuchMethodError`，候选包对应路径通过。这里只加载测试包，不代表新候选 APK 已覆盖安装或完成真实通话、短信验收。MIUI shell Context 初始化会打印系统缺失主题配置的诊断，但只读检查最终通过。
- iOS「配对安卓手机」新增仅控制本次配对的本地开关；不写全局模式。ON 不读取云端凭据，仅写 VoWLAN；OFF 缺凭据时明确失败。配对等待在途 Agent 写入结束并阻止新写入，防止迟到云端 POST 覆盖本地配置。自动同步识别本地 Agent，其他全局 Relay token 刷新不因此关闭。97 项 iOS 测试通过；本轮尚未覆盖安装 iPhone 验收界面。
- 发布继续暂停；没有 commit、push、GitHub Release 或 TestFlight 更新。Android 10/11/13、其他 OEM、真实静音及音量恢复、真实双向通话和 Apple Watch 仍需真机验证。

### 2026-10-14 Android 11/12 启动兼容修复（未发布热修）

- 小米 M2004J19C（Android API 31）实机与用户提供的 vivo V2111A（API 30、报告标注旧版 0.1.0）堆栈均定位到 `BridgeLog.readFile` 的 `ByteArrayOutputStream.toString(Charset)`，不是配对数据损坏。报告内容与用户标识未写入仓库。
- 七处日志/报告/HTTP/WS 解码改用兼容构造器；四处 VoWLAN/WS/云端 PCM 定长读取改为 `DataInputStream.readFully`。短 READY 帧仍拒绝，不消费后续 PCM。字节码回归检查在旧实现上先失败，改动后通过；真实诊断文件 UTF-8 读写、Android 共享与 Standalone 全套、47 项音频桥检查通过。
- 首次修复包真机启动继续暴露 `RuntimePermissionPolicy` 的 `List.toArray(IntFunction)` 不可用。新增方法引用检查先复现两处失败，再将两处统一改为 `toArray(new String[0])`；完整测试与 Standalone 正式签名构建通过。
- 同正式发布证书保留数据覆盖安装至小米成功，冷启动后 PID 11266 在多次检查中存活，进入 MIUI 权限申请页；内置 Agent 与 VoWLAN 服务已创建。权限选择后的首页/配对、vivo 真机、实际通话仍待验收。本次未清除数据、未替换 GitHub Release 工件。

### 2026-10-14 Apps v0.9.7 发布核验

- 从源码提交 `8bce6ac` 构建，Android/iOS 版本统一为 `0.9.7 (80)`；独立 Linux Agent 保持 `0.4.6`。不新增 workflow，不合并 main。
- iOS 92 项 XCTest、Android 共享/Standalone 全套、47 项 PCM 桥检查、Go Agent/installer、AVF Debian 打包测试、Relay 46 项及语法检查全部通过。
- AVF 与 Standalone Release APK 验签通过、`debuggable=false`，证书 SHA-256 与 v0.9.6 一致。两套 iPhoneOS Release archive 成功，正式主 App、Watch 与 Live Activity 嵌套签名验证通过；App Store 分发时由 Xcode 再重签。
- 本次公开 IPA 是无签名/无描述文件的 Release 构建，未复用 Debug 诊断包。正式 TestFlight 上传状态以 Xcode 返回为准，不把 Archive 成功称为上传或审核通过。
- 本轮未新增真实运营商通话或删除用户配对数据；此前真机结果与待验收边界继续保留。

- VoBLE 是独立模式，不是 VoWLAN 的依赖；一次通话建立后不会在 VoBLE、VoWLAN 和 Relay 之间无提示漂移。
- BLE 只承载 AirSIM 控制和音频，不实现 Android 到 iPhone 的 Bluetooth PAN 网络共享。
- 音频为 G.711 μ-law 8 kHz 单声道，控制和媒体均以 AES-256-GCM 认证；PCM 只在内存中处理。
- iOS 用户强制退出 App 后，系统不保证 BLE 后台唤醒。CallKit 可用于本地蓝牙通话，但本地模式不依赖 PushKit。
- Apple Watch 使用 iPhone 的 CallKit/WatchConnectivity 状态与系统音频路由，不是 Watch 到 Android 的直接 BLE 音频链路。
- 自动化测试不替代三星、小米、iPhone 与 Watch 的联合真机电话验收。
