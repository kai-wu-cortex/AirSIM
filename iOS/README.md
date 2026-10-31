# AirSIM iOS 与 watchOS

2026-10-31 发布准备：[Apps v0.9.8.20](../docs/releases/0.9.8.20.md)，iOS／Watch／Live Activity `0.9.8 (152)`。包含 PR #18、后台 VoWLAN 恢复与 CallKit 无区号号码原样展示；TestFlight 使用 production APNs，上传、处理及外测可用状态见发布说明。下文旧候选状态仅作历史记录，不能代表当前发布状态。

2026-10-30 未发布修复：[APNs 接听后的本地音频启动竞态](../docs/vowlan-first-call-startup.md)。兼容通话的音频任务独立于轮询；前后台刷新不再因轮询世代或调用方取消而关闭已握手的 PCM。挂断、停止、CallKit 停用／重置仍取消在途启动，回滚记录固定原因码，不记录通话身份或 PCM。未安装、发布或上传 TestFlight，锁屏 APNs 接听与双向声音须真机复验。

2026-10-29 未发布候选：[反馈仅允许手动上传](../docs/manual-feedback-policy.md)。设置页手动按钮保留，非手动触发在采集与联网前拒绝；Verbose 本地记录不受影响。

2026-10-29 未发布候选：[Tailscale / 其他 VPN 恢复修复](../docs/handoff/2026-10-29-tunnel-recovery-review.md)。保留经配对的非 CGNAT 私网候选、蜂窝下重新验证、限制离线端点循环切换；不改变签名认证或通话中的媒体路径。需用户设备复测，尚未进入 TestFlight 147。

2026-10-20 发布：[Apps v0.9.8.8](../docs/releases/0.9.8.8.md)，iOS／Watch／Live Activity `0.9.8 (113)`。包含配对时钟校正、双卡短信与通话卡槽、私有网段、VoBLE 静音修复；灵动岛仅保留 Agent 状态，通话全部交给 CallKit。GitHub unsigned IPA 仍需重签。TestFlight 上传/处理状态以 App Store Connect 实际回执为准。下文候选及旧版本记录保留追溯。

0.9.8.1 新增应用更新入口：首次安装／升级启动展示包内版本说明；「设置 → 关于」可重看和手动检查新版。前台每日最多自动检查一次（失败也限频），不自动下载／安装 IPA，不访问 Relay；TestFlight 可用性与 GitHub 发布分开提示。[行为、维护和验证边界](../docs/app-updates.md)。

本轮应用版本为 [0.9.8（92）](../docs/releases/0.9.8.md)：本地双通道／多安卓归属、配对与 Verbose 改进、云端 Android 挂断回执兼容及设置顶部的派生本地模式开关。公开 full／sideload IPA 均须重签；TestFlight 上传状态单独核对。后文 91 及更早版本为历史记录。最新真机验收尚未全部完成，详见发布说明。

## 未发布修复：短信会话与 Tab 栏转场

短信会话由整个 Tab 容器外层的导航栈推入，返回过程中由会话页遮挡下面的原生 Tab 栏，避免 Tab 浮在输入条上方。UIKit 转场协调器同步整条 Tab 栏的透明度，并在交互式返回取消时恢复原状态；不使用固定延时、横向遮罩或会话页安全区补偿。短信列表的普通行按钮直接更新外层导航路径，不再使用跨 Tab 容器的隐式 NavigationLink 激活状态；编辑模式仍使用原生列表选择，短信通知也进入同一外层导航路径。

后续会话交互改造中，导航栏可见性统一由 SwiftUI 管理，UIKit 桥接仅改变 Tab 栏透明度，避免侧滑返回取消后导航控制器仍停在会话、导航栏项目却停在列表的不一致。已在模拟器实际完成侧滑取消与正常返回检查。

路径比较修复：短信详情改用单页 `isPresented` 呈现状态，不再将短信会话值写入固定元素类型的导航路径。此改动保持原有 `NavigationStack`／`TabView` 视图层级、Tab 样式和安全区布局，不引入全局 UIKit 宿主。

短信列表的标题、左侧会话操作菜单和右侧撰写按钮直接挂载在外层导航栈的 Tab 根内容上，避免 Tab 内的列表无法提供外层导航栏项目而留下空白。菜单与列表共享选择和弹窗状态，保留撰写、选择会话、刷新及本机删除操作；不新增导航宿主，也不修改 Tab 栏布局或安全区。

顶部栏回归实际打开并取消撰写，连续三次进入会话、返回后检查标题与操作按钮恢复；原模拟器实时截图已确认标题、菜单、撰写按钮显示，原生 Tab 栏保持在底部。原生菜单项的前台触摸检查受本机锁屏阻挡；测试菜单可访问性激活不能替代触摸验收。

模拟器构建及 `SMSDeletionTests` 7 项通过，导航回归覆盖真实 `RootView` 中的会话层级；用户手动确认本轮效果正常。未发布或上传 TestFlight。
重复进入修复：导航回归通过真实可访问性行操作连续执行三次打开与返回，检查会话层级和导航栏项目归属，覆盖同一会话返回后再次打开。前台连续触摸复验受本机锁屏阻挡，不能将该回归记录写成真机验收。

## 未发布修复：手机接听后同步 Watch 撤铃

iPhone 在 CallKit 生命周期进入 `active` 或终止状态时，经 WatchConnectivity 发布同一通 APNs 来电的状态；本地展示 ID 作为别名，Watch 同时按 ID 与 UUID 匹配。WatchConnectivity 激活完成后会重发最新待发送状态，Watch 会记录已结束的 ID／UUID，迟到的 `incoming` 不会重新拉起铃声。模拟器定向 XCTest 通过；iPhone／Apple Watch 真机、锁屏 APNs 和不同到达顺序仍需验收。

## 未发布功能：原生风格短信会话

会话消息列表改用 UIKit 复用单元与只读原生文本视图：接收消息左对齐、发送消息使用系统绿色，保留 SIM 来源和真实的已发送状态。首条、跨自然日及相邻间隔至少五分钟时显示本地化日期时间；连续同方向消息紧凑排列，组尾显示气泡尾部。五分钟是 AirSIM 的分组规则，不是 Apple 公布的阈值。

日期标签保留原有中英语言判断：英文相对日期以句首形式显示 `Today`／`Yesterday`，中文仍为“今天／昨天”；不改变系统时区与 12／24 小时设置。

长按气泡提供 Copy／复制、Select／选择文本、More…／更多…。文字选择使用系统选区手柄与编辑菜单，不允许修改短信；More 默认勾选当前消息，整行可继续勾选。多选期间收起输入条、保留草稿，底部左侧删除、右侧系统共享；取消多选恢复草稿且不主动弹键盘。新消息不会自动选中，阅读位置在选择、布局变化与非底部收信时保留。

批量删除仍只删除此 iPhone 的 AirSIM 记录，沿用持久化删除标记防止旧同步回流；写入失败保留消息与选择。分享仅包含选中正文，按会话顺序作为独立文本项目交给系统分享面板，不默认附加号码或设备标识，关闭面板后保留选择。未部署 Relay、未改跨端协议、未发布或上传 TestFlight。

## 未发布修复：云端后台待机状态

云端查询调度与结果接收时间分开记录，切后台重新允许事件触发查询时，不再把已收到的云端在线结果当成过期。本地 HTTP 链路不可达不会覆盖最近确认的云端待机状态；空闲后台／锁屏保留最近一次查询结果，不增加 Relay 定时请求，也不代表持续实时探测。回到前台、云端拨号前及已有的通话事件查询仍核对新状态；新结果离线、自检刷新失败或关闭云端模式时不会继续保留在线缓存。候选包已保留数据覆盖安装到 iPhone Air 并启动，270 项 XCTest 复跑通过；用户暂不方便测试，灵动岛与锁屏真机显示仍待复验。此修复尚未提交、推送或发布。

2026-10-19 后续未发布修复：前台空闲也不再用 90 秒期限丢弃展示快照，避免云端拨号页停留后设备卡片消失。云端在线胶囊标为“上次在线”，表示最近确认结果，不表示持续实时探测；不新增 Relay 轮询，真正云端拨号仍先重新查询。新的离线结果、明确刷新失败（含拨号前查询）或关闭云端继续替换／清除在线快照。蓝牙配对页、设置与诊断使用 Hub 的配对展示状态：未选择外设时展示共享 Radio 的扫描／不可用状态，不再把未启动的占位会话当成扫描器；扫描及启停变化通知 UI，只有设备实际认证才可显示就绪或获得拨号／音频权限。模拟器构建与全量 280 项 XCTest 通过；本机 Release 构建和签名验证通过，安装与真机回执见 [handoff 第 9 节](../docs/handoff/2026-10-19-ios-multi-android.md#9-后续问题云端拨号卡片消失蓝牙配对页尚未启动)，不等于真实停留或配对验收已完成。

2026-10-19 BLE 发现恢复（未发布，本机 build 96／97）：共享 Radio 的 `start()` 现在会重新下发一次 `scanForPeripherals`，即使内存中的 `scanning` 仍为 true；用 10 秒时间戳限制避免重复启停。iOS 可能在挂起时静默停止扫描而不回调状态，旧逻辑只信任标记，页面会一直停在“正在发现”。新增 `voble-radio` Verbose 事件记录电源／授权状态、扫描启停／重建、发现数量和 RSSI，不记录设备名、地址、号码或密钥。全量 **282 项 XCTest、0 失败**；Release 设备构建已保留数据安装到 iPhone Air（`0.9.8 (97)`，Apple Development／sandbox）。安卓端广播恢复见 [handoff 第 10 节](../docs/handoff/2026-10-19-ios-multi-android.md#10-2026-10-19-追加ble-一直正在发现找不到安卓)。

2026-10-19 BLE 通话卡顿回归修复（未发布，本机 build 97）：多设备重构后，共享 Radio 在连接和通话期间持续扫描；旧版单设备控制器在 `connect` 时先 `stopScan`。扫描与 BLE 媒体连接争抢射频时间，上行编码队列（8 帧）积压后丢帧，听感表现为卡顿。现在任一设备 `audio.running` 时暂停共享扫描，通话结束恢复；通话中的前台 re-arm 和“重新扫描”也不会再抢占。修复前两次真机统计 `dropped_frames` 分别为 108（约 9 秒）和 5（约 2 秒），波动大。**2026-10-19 用户定位：后台运行的模拟蓝牙触摸板占用 BLE 通道，关闭后卡顿消失**；因此不能把暂停扫描或音频管线当作卡顿的唯一修复。暂停扫描仍保留，用于恢复旧版“连接后停扫”的行为。关闭外部 BLE 设备后的听感、长通话丢帧和双向音质仍需复测。未提交、推送或发布。

2026-10-19 配对核对码延迟修复（未发布，本机 build 98）：`pendingSAS`／`errorMessage` 是所选 `VoBLECentralController` 的 `@Published` 字段，Hub 原先只转发 `$state` 与 `$deviceInformation`，所以页面已显示“正在进行应用层认证”时，六位码仍要再点一次设备才出现。Hub 现在转发所选控制器的 `objectWillChange`；全量 **283 项 XCTest、0 失败**，build 98 已保留数据安装。真实配对码显示与确认仍需复验。

2026-10-19 蓝牙 PCM 状态显示（未发布，本机 build 101）：通话页原来用 `vobleAudio.running` 判断，可能读到非通话会话，导致 `ENGINE_READY`/媒体已运行时仍显示“正在建立蓝牙语音链路”。现在按通话归属会话的 `audio.running` 或 `media.isRunning` 判断，并在没有明确归属时检查所有 BLE 会话；连接后显示绿色 **“已连接蓝牙 PCM 链路”**，未连接保持橙色“正在建立蓝牙语音链路”，状态胶囊底色同步。全量 **287 项 XCTest、0 失败**。

2026-10-19 灵动岛双通道在线与 Agent 文案（未发布，本机 build 103）：离线判断原来只看 USB/VoWLAN 本地控制或云端心跳，本地双通道下 USB 断开但 VoBLE/VoWLAN 仍在线时会误报“模块离线”。现在把当前 Agent 的 `vowlanOnline`/`bluetoothOnline` 纳入判断，任一路可达即进入待机态并显示 `VoWLAN 在线 · VoBLE 在线`；离线文案改为 **“Agent 离线”**，待机/来电/兜底同步改为 Agent 文案。新增 2 项回归，全量 **291 项 XCTest、0 失败**；build 103 已安装。

2026-10-19 多 SIM 卡槽选择（未发布，本机 build 102）：配对安卓上报多于一个 call-capable SIM/PhoneAccount 时，拨号页当前设备卡显示 `simcard.2` 小按钮；展开可选择**本次拨号**使用的卡槽，菜单显示卡槽标签与号码，选择按 agent 记忆，不修改安卓全局默认通话卡。数据来自 BLE `device_info` 或 VoWLAN `/v1/health` 的 `sim_slots`，拨号经 `sim_account` 下发。全量 **289 项 XCTest、0 失败**；build 102 已安装。当前三星只有一个 call-capable 账号，按钮未在真机显示；双 SIM/eSIM 与 AVF/Cloud 透传仍待验证。

2026-10-19 通话路径修复（未发布，本机 build 100）：只把已验证的本地 peer 计入拨号目标；绑定设备离线时不再把另一台显示为当前设备；云端通话占用主展示时，本地来电保留为“其他设备”提醒，且云端通话进行中禁用该提醒的接听按钮；接听失败释放媒体/registry active 并恢复响铃页；直接拨号失败清理 pending；BLE `start_media` 对 `disconnected`／`notReady` 做一次重试；云端来电仅在 `startsVoWLAN` 时启动本地浏览；本地 ringing/active 或云端通话时拒绝新拨号，本地通话展示期间不接收云端 PushKit 主展示。新增回归，全量 **286 项 XCTest、0 失败**；build 100 已安装。接听失败、云端与本地并发、双安卓“其他设备接听”仍需真机复验（P2-7 的 CallKit 事务尚未实现）。

## 本地双通道与多安卓（0.9.8）

未发布修复（2026-10-19）：纯 VoBLE 下多台安卓已认证但未指定默认设备时，拨号页保留可点击的设备列表，先选择目标再拨号，不静默换手机。Bonjour／手动地址候选本身不算已配对；列表只使用已记录配对、已注册云端或已认证的本地／蓝牙身份，广播 TXT 不覆盖可信设备信息。已结束通话的路由随 Registry 保留最多 128 条轻量历史，释放后台对象；在途挂断／拨号任务仍持有原设备后端，旧 CallKit 操作不能控制新通话。此修复不改变协议或版本号，未安装／发布，双安卓真机验收仍待进行。

本轮模拟器 `build-for-testing` 与全量 276 项 XCTest 通过（0 失败），包括新增的未绑定多蓝牙设备选择、未认证广播隔离、缺失设备名称、300 通结束记录清理、在途挂断后端生命周期及过期 CallKit UUID 回归；不等于两台安卓真机通话或音频已验收。

`VoBLE` 分支正在验证「本地双通道」：同一安卓同时保持 VoWLAN 与 VoBLE 控制连接，接听／拨出前优先 VoWLAN，其次 VoBLE；只启用一路音频，通话途中不自动换路。不访问 Relay、不注册 PushKit；本机 CallKit 仍可用。原有四种连接模式的持久化值不变，升级不会自动改为双通道。

在设置中可独立添加 Wi-Fi 和蓝牙配对，不要求先完成另一条链路。一个 iPhone 可保持多台安卓待机；拨号页设备列表选择的是下一通默认设备，不会改变正在通话的设备。其他安卓来电仅显示来源提醒，后台通知不播放第二路铃声；点击后重新验证是否仍响铃，忙时不会结束当前电话或自动接听。

新增设备级 VoWLAN 凭据和健康证明。双通道去重依赖安卓原始 Telecom ID：Standalone 需新版 APK；AVF 需同时更新 Bridge APK 和 Linux Agent。旧 AVF 接口仍兼容旧客户端，但没有 `canonical_call_ids` 能力时，不提供新的设备归属 VoWLAN 拨号，不按号码／时间猜测身份。

当前仍在真机验收，未发布、未部署 AVF／Relay。审查后 239 项 XCTest 通过，Release 候选已保留数据覆盖安装到 iPhone Air，Standalone 候选已保留数据覆盖安装到 Flip7；用户暂不测第二台安卓。构建和真实电话验收分别记录在[测试矩阵](../docs/voble-real-device-test-matrix.md)，不能将模拟器结果视为两台安卓双待、射频恢复或双向通话已验收。

未发布修复：短信列表仅在「选择会话」时启用多选，普通点击继续打开会话，保留滑动删除与短信通知跳转。VoWLAN 配对扫描隔离旧回调，失败后可重建扫描实例；自动发现页提供「重新扫描」，返回前台重新扫描，离开页面／进入后台停止扫描，手动地址模式不启动 Bonjour。仍需三星与 iPhone 真机验证，不能把本机 Bonjour 测试视为路由器、VPN 或安卓 NSD 广播已验收；自动发现持续无设备时应同时检查安卓配对窗口、本地网络权限及网络隔离。

当前应用发布为 `0.9.7 (91)`，见 [Apps v0.9.7.2](../docs/releases/0.9.7.2.md)。包含下述候选功能及蓝牙 UI／挂断实时活动修复；公开 full unsigned IPA 包含 Watch，sideload unsigned IPA 不含 Watch、保留 Live Activity，两者均须自行重签。维护者另经 Xcode 上传 production 推送环境版本到 TestFlight，不能将 GitHub IPA 或本机安装视为上传／审核成功。下文旧候选和 build 81 为历史基线。

另有未发布的 [Relay 多安卓定向命令](../docs/relay-agent-routing.md)适配：操作开始时快照目标，通话控制不随选择变化，结果查询退避且可取消；需要 Relay 和目标安卓明确支持 v2，不自动退回 v1。不新增常驻状态查询。

工作区候选构建为 `0.9.7 (85)`，尚未发布或上传 TestFlight；下文 build 81 是已发布基线。候选版在「设置 → 关于」读取本安装包版本号与 build，并提供 GitHub 仓库和版本发布页入口。联系人按系统完整姓名格式读取 given / middle / family name；旧格式缓存首次获得通讯录权限后自动更新一次，读取失败保留本机副本、下次重试，手动下拉刷新仍可更新联系人。

build 85 针对 [Issue #2 的同网恢复](../docs/vowlan-network-return.md)：Wi-Fi 路径变化后重新发现并认证 VoWLAN；自动模式空闲时回到优先链路，固定云端不变、通话途中不切换，不新增 Relay 定时查询。系统挂起与锁屏行为仍须真机验收。

build 84 新增短信单条、会话及多选删除，仅删除 iOS AirSIM 本机记录，不操作安卓系统短信；原子保存脱敏删除标记防止旧同步回流。[使用与验收边界](../docs/sms-deletion-audio-watchdog.md)。

build 83 新增[手动 IP＋配对端口](../docs/manual-ip-pairing.md)，可绕过 Bonjour 发现，支持局域网 IPv4 及 Tailscale `100.64.0.0/10`。两端 App 都需更新；不需要修改 Linux Agent 或 Relay。真实 Tailscale 两端配对、短信、通话音频仍待真机验收。

该目录包含面向三星 Android 电话端的 iPhone、Apple Watch、Live Activity 与共享模型。客户端可通过 VoWLAN 或 VoBLE 直连三星手机，也可通过独立 Cloudflare Relay 使用远程通话与短信。

当前应用构建为 `0.9.7 (81)`，随 [Apps v0.9.7.1](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.7.1) 提供 unsigned IPA；维护者另行通过 Xcode 上传 production 构建至 TestFlight，上传/处理/审核状态需分别核对。配套 AVF Agent 为 [`v0.4.6`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.6)。维护者 `com.eric3u.airsim` 构建使用 `https://airsim-push.remotepilot.site`；自行更换 Bundle ID 后必须使用自己的 Relay 和 APNs 凭据。

## Xcode 工程

打开：

```text
iOS/AirSIM.xcodeproj
```

主要 target：

- `AirSIM`：iPhone / iPad 主 App
- `AirSIMWatchApp`：Apple Watch App
- `AirSIMLiveActivityExtension`：锁屏与灵动岛实时活动
- `AirSIMTests`：传输选择和协议边界测试

## 客户端能力

- 三星设备一次性加密配对
- VoWLAN 服务发现、HMAC 鉴权和健康检查
- CallKit 拨号、来电、接听、挂断、静音与 DTMF
- PushKit、通知 APNs 与 ActivityKit
- 首次进入前台优先申请麦克风权限；完成麦克风授权决策后才启动本地发现和通知授权。若系统暂缓弹窗，下次进入前台会重试，不需要重新配对。
- Apple Watch 拨号、接听和通话媒体
- 短信列表、发送、通知和联系人整合
- VoWLAN、VoBLE 与云端 Relay 传输选择；自动模式只按实际可用的拨号路由选择，优先级固定为 VoWLAN → VoBLE → 云端
- VoBLE 的拨号可用性由已认证的蓝牙会话和媒体通道判断，不依赖 Relay、VoWLAN 健康检查或 HTTP 200
- 拨号页、配对设备列表、锁屏实时活动与灵动岛同步显示 VoBLE 在线状态和当前传输
- VoBLE 通话的灵动岛接听、拒接和挂断会唤起 AirSIM，由主 App 的已认证 CoreBluetooth 会话执行；不会错误请求 VoWLAN 固定地址或 Relay
- VoBLE 配对页支持经认证的双端取消配对；密钥错位时会给出 Android 本地清除路径，并允许清除 iPhone Keychain 中的旧凭据后重新扫描
- 云端 PCM 使用有界自适应缓冲、短时缺帧补偿与 20 毫秒收发节奏；挂断后抑制旧状态恢复通话界面。用户已完成本轮云端真机通话，反馈不再重现、声音更稳；策略与 TCP 限制见[云端 PCM 抖动处理](../docs/cloud-pcm-resilience.md)。
- 设置页实时显示当前 VoWLAN / 云端模式与 Agent 心跳状态
- 云端模式在 App 进入前台时查询一次 Relay 状态；需要走云端拨号时再核对一次，灵动岛显示通话前等待一次状态查询（后台来电也适用）。本地模式不查询 Relay，VoWLAN 失联和后台待机更新不会启动定时云端查询，避免反复消耗请求额度。
- 四阶段云端自检：本机 Push 凭据、Relay 身份、设备注册、Agent 心跳
- 本地通话记录、单条滑动删除、详情删除、诊断和媒体健康状态

VoWLAN 接听、拒接和挂断请求在已知当前通话时携带 `/api/calls/status` 返回的 `call_id`（JSON 字段 `call_id`）。Standalone 与新版 AVF Agent 会校验它，避免旧来电通知误操作后续通话；未取得通话 ID 时仍可发送兼容旧版 Agent 的空请求。

### APNs 来电的远端挂断（未发布）

APNs 先建立主通话、随后通过 VoWLAN 接听时，本地终态按认证设备和后端通话 ID 映射到原 CallKit 身份。Registry serial、BLE generation 与 Relay generation 属于独立计数器，不跨命名空间比较；本地事件按各自通道的 epoch／generation 水位验证。另一通道已经结束时，后到的合法终态仍可补全后端映射，但不重复产生结束副作用，也不能恢复为活动通话。另一台设备、其他通话和过期事件不能结束当前通话。

AppModel 接管冷启动 handler 时，认领仍匹配系统当前 ID／UUID／设备／generation 的推送通话，并保留已接听的状态；已结束或替换的 UUID 不会回放。身份保留到权威终态，支持本机先结束系统界面后再收到回执。终态先使生命周期结束，再关闭本机媒体、PCM 重连和原 CallKit 展示，不向后端补发拒接／挂断。在途接听回包不能重新锁定或启动已结束的通话；本地事件先到时仍沿原 owned-call 路径处理，不在通话中途迁移传输。

原 fork 基线上的 65 项相关 XCTest 已通过，两位 reviewer 针对修复逻辑复审未发现新增问题。移植到上游 VoBLE 后，保留上游新增回归并适配其音频失效检查 API，44 项相关测试再次通过，覆盖跨通道终态、冷启动接管、APNs-first、在途接听取消、本地-first、系统回调后的终态与跨设备隔离。上游发布说明已记录的双设备链路超时和 Watch admission 两项既有异常未在本轮复跑，不宣称全量回归通过。上游构建的模拟器 App 进程已实际执行 push 先到／模型后建的身份认领，以及真实 TCP 鉴权、EOF 重连、BLE 先结束、过期 VoWLAN 忽略、合法映射终态关闭原 CallKit 和连接；合成来电使用受控 CallKit 上报边界，不等于真实 PushKit／系统界面验收。未重新验证音频引擎；已有模拟器 AudioToolbox RPC 超时限制，锁屏来电、双向音频和运营商远端挂断仍需真机复验。未安装真机、未发布，未改 NekoSIM、Android 或 Relay。

Standalone 的本地 Gateway 与云端通话描述仍分别生成后端 ID；两端 ID 不同时的映射属于既有生产者限制，本轮未修改该跨端协议，不能据上述合成映射回归宣称已通过 Standalone 真实推送验收。

### 短信收发与推送

AirSIM 与 DJOneHub 采用相同的通道分工，但使用各自独立的 Relay 和 APNs topic：iPhone 发短信时，VoWLAN 就绪则直接调用 Agent；离线且云端模式开启时，向 Relay 提交经设备鉴权的 `send_sms` 命令，由 AVF Agent 执行并回传结果。Agent 收到短信后，把带 `delivery_id` 的事件送到 Relay；Relay 使用主 App topic 的普通 APNs `alert` 通知 iPhone，App 保存本地历史并按 `delivery_id` 与下次 Agent 同步去重。点开通知会进入发件人会话，冷启动时也会保留这一导航请求。

PushKit VoIP push 仅用于真实来电并交给 CallKit，不能拿它承载短信正文或唤醒发信任务。短信通知需要用户允许普通通知、iPhone 已取得 alert token，且 Relay、Agent 注册与心跳正常。普通 APNs 的送达及后台执行由 iOS 决定；正式验收必须分别测试前台、锁屏、冷启动和云端发信，不应把控制面自检通过等同于短信实测通过。

## 首次配置

1. 在三星手机启动 AirSIM，并确认 Agent 与 Shizuku 音频桥就绪。
2. 将 iPhone 连接到三星热点或同一局域网。
3. 在三星端打开两分钟配对窗口。
4. 在 iPhone「配对安卓手机」选择本次配对方式，再输入安卓端的六位配对码。「仅本次配对不写入云端」打开时只写入 VoWLAN 密钥，不读取/写入 Relay 与推送参数；关闭时写入云端配置，缺少凭据会提示，不静默回退。初始值跟随当前全局本地模式，但切换只影响本次配对，不修改全局设置；配对中不可切换。配对前会等待在途 Agent 注册写入结束，自动注册也会识别安卓的本地配对状态；其他设备的全局 Relay token 刷新不因此关闭。
5. 等待 VoWLAN 状态显示为就绪。
6. 如需 VoBLE，在“连接模式”选择蓝牙并完成系统蓝牙授权及 AirSIM 配对；看到“VoBLE 在线”后即可本地拨号，无需填写 Relay 参数。

设置顶部的「仅本地模式」直接由连接模式推导，不另存独立开关：VoWLAN、蓝牙和本地双通道为开启，云端和自动为关闭。从云端／自动打开时切换本地双通道；关闭时切回自动；已选本地链路不会被重复开启操作改变。关闭只允许使用云端，不会把安卓明确选择的本地配对自动改为云端配对。
7. 如需远程模式，在“云端 Relay”填写与当前签名身份匹配的独立 Relay 地址，点击“保存 Relay 地址”，再启用“远程通话与短信”。维护者 `com.eric3u.airsim` 构建使用 `https://airsim-push.remotepilot.site`；其他 Bundle ID 必须使用自行部署的 Relay。
8. 打开“设置 → 云端模式自检”。四项全部通过才代表云端控制链路可用；“Relay 身份”会拒绝 DJOneHub 或其他服务，“Agent 心跳”要求 AVF Agent 在最近 90 秒内上报。自检不会拨号或发送短信。

### 管理已配对 Android 设备

「设置 → 安卓连接 → 配对安卓手机」下方列出已配对设备，显示当前读取的设备名、号码与 VoWLAN/VoBLE/云端状态，支持逐个确认删除。离线历史只保留设备标识、名称和 Agent 类型，不保存号码。号码不可读或 SIM 未提供时显示“号码未提供”，不会用历史号码补齐。

删除会清除本机列表项、手动绑定与该设备的蓝牙凭据，并保留拒绝自动重连的设备标记；其他设备、通话记录和短信不受影响。在线蓝牙设备会尝试同时撤销 Android 凭据；离线删除不等同远端授权撤销，远端旧凭据可能需要在 Android「VoBLE 认证配置」中清除。删除的设备必须显式重新配对，不能被广播或云端旧状态自动加回。

重连使用当前广播和认证检查，不再凭缓存外设 UUID 建立连接。新版 Android APK 支持经认证的 BLE `device_info` 查询；旧 APK 不支持时不会借用 VoWLAN/Relay 的历史号码。Standalone 云端心跳及本地健康检查读取当前通话卡，不采用首次配对保存的号码。旧 AVF Linux Agent 的云端号码心跳尚未迁移到这一读取流程。

## 构建与测试

```sh
xcodebuild -project iOS/AirSIM.xcodeproj \
  -scheme AirSIM \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

在指定模拟器运行测试：

```sh
xcodebuild -project iOS/AirSIM.xcodeproj \
  -scheme AirSIM \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## 签名与推送

诊断包若从 `CODE_SIGNING_ALLOWED=NO` 的 Debug 构建重新签名，必须先签所有内嵌动态库（包括主 App 和 Live Activity 扩展各自的 `*.debug.dylib`、`__preview.dylib`），再由内到外签扩展与主 App。只对 `.app` 执行 `codesign --verify --deep --strict` 不足以证明位于包根目录的 Debug 动态库已签名；需对每个 `.dylib` 单独执行签名验证，并以真机启动后进程持续存活作为安装验收。漏签会在进入 App 代码前产生 DYLD `Library missing / missing code signature` 闪退。

这是源码可见、仅限非商业用途的工程，不提供原作者的 Apple Developer Team、App ID、证书或 provisioning profile。工程中的 `com.example.airsim` 是占位符，不能直接用于发布。首次真机构建前必须使用自己的 Apple Developer 账号重新配置并签名：

1. 在 Xcode 为 `AirSIM` 选择自己的 Team，将 Bundle Identifier 改为自己控制的唯一标识，例如 `org.example.airsim`。
2. 将 Watch App 改为主标识加 `.watchkitapp`，例如 `org.example.airsim.watchkitapp`，并将 `WKCompanionAppBundleIdentifier` 设置为主 App 标识。
3. 将 Live Activity Extension 改为主标识加 `.liveactivity`，例如 `org.example.airsim.liveactivity`；测试 Target 可使用主标识加 `.tests`。
4. 在 Apple Developer 为三个正式 Target 创建 Explicit App ID，启用所需 capabilities，并重新生成属于自己 Team 的开发/分发 provisioning profile。
5. 在 Relay 的 `ALLOWED_BUNDLE_ID` 使用同一个主 App 标识；PushKit、Watch 和 Live Activity 的 APNs topic 会以它为基础生成。

只替换签名证书而保留其他人的 Bundle ID 不会获得对应 App ID/APNs topic 的权限。主 App、Watch、Live Activity、provisioning profile 与 Relay 必须使用同一套标识关系。

Relay 地址通过 `AIRSIM_PUSH_RELAY_URL` 注入，APNs 环境通过 `AIRSIM_APNS_ENVIRONMENT` 配置。Debug 开发签名对应 APNs `sandbox`，Release/TestFlight 对应 `production`。

不要把 DJOneHub 的 `https://push.remotepilot.site` 填入 AirSIM。该地址只允许 DJOneHub Bundle ID；AirSIM 与 DJOneHub 的设备注册、命令队列、媒体会话和 Dashboard 相互隔离。维护者 AirSIM 地址也只接受 `com.eric3u.airsim`，开源使用者更换 Bundle ID 后必须同步更换 Relay `ALLOWED_BUNDLE_ID` 和 APNs 凭据。

新安装需要重新完成三星配对、通知授权、CallKit/PushKit 注册和 Watch 配套安装。

GitHub Release 中的 `AirSIM-iOS-<version>-unsigned.ipa` 是供重签的 arm64 构建产物，不包含 `_CodeSignature` 或 `embedded.mobileprovision`，不能直接安装。不能只签主 App：必须同步替换并签署 Watch App 与 Live Activity Extension 的 Bundle ID、entitlements 和 provisioning profile。公开 Release 不应上传包含开发设备 UDID 的 development/ad hoc IPA。

### 干净打包与侧载候选包

从 `CODE_SIGNING_ALLOWED=NO` 构建的 `.xcarchive` 或 `.app` 创建 unsigned IPA（输出目录需已存在，文件不可覆盖）：

```sh
sh iOS/scripts/package-unsigned.sh /absolute/path/AirSIM.xcarchive /absolute/path/AirSIM-full-unsigned.ipa full
sh iOS/scripts/package-unsigned.sh /absolute/path/AirSIM.xcarchive /absolute/path/AirSIM-sideload-unsigned.ipa sideload
sh iOS/scripts/test-package-unsigned.sh
```

`full` 保留 Watch 与 Live Activity；`sideload` 仅从临时副本移除 Watch，仍保留 Live Activity，不修改源归档。两种包均排除 AppleDouble（`._*`）、`__MACOSX`、签名目录和 provisioning profile。脚本拒绝已签名代码，不将开发签名包冒充 unsigned 包。候选包仍需侧载工具为主 App 和 Live Activity 扩展重签、匹配 Bundle ID 与权限；需要 Apple Watch 时使用完整包或正式 TestFlight。移除 Watch 和清理 ZIP 不等同于已确认修复某一侧载工具的“无法加载”，应以实际重签安装与启动验证为准。

## Verbose 日志调试

在「设置 → 调试 → Verbose 日志调试」开启详细记录，然后复现问题。支持 VoWLAN、VoBLE 与云端模式；蓝牙或离线时也可查看本机日志。开关会保留到下次启动，排查完成后请关闭。

- 「通话」筛选包含蓝牙媒体归属、音频引擎、CallKit 和云端通话事件。
- 使用「VoWLAN」「VoBLE」专项筛选；旧 AT／USB 筛选已移除。详细异常包含阶段、源码文件／函数／行号、NSError 域／代码、失败原因与最多四级底层错误，并对错误文本中的 URL、令牌和长号码进行脱敏。VoWLAN 统计区分引擎运行、采集回调、上下行字节和峰值，不把握手成功等同于双向声音正常。
- VoBLE 拨号失败会在 `dial_command` 阶段保留详细拒绝原因，并在回退到拨号页后保留错误提示。每次用户拨号在发送前预留序号，丢失回执或重启 App 后不会重复使用；不会因此自动重拨。
- 右上角导出按钮保存 UTF-8 `.txt` 文件；分享前检查并遮盖个人信息。
- 页面仅定时刷新本机有界日志，不自动请求 Relay 或安卓。需要补充安卓日志时，使用「手动读取安卓日志」（需已有经过验证的 VoWLAN 连接）。
- 清除按钮只清除本机调试日志及已读取的安卓日志副本，不删除远端日志、通话记录或短信。
- 未开启详细记录时仍保留有界、无通话标识的基础音频启动阶段；通话 PCM、配对密钥和 Push token 不应写入日志。

## 安全与隐私

- VoWLAN Secret 保存在 Keychain，不写入 UserDefaults 或日志。
- 配对使用 X25519、HKDF-SHA256 与 AES-256-GCM。
- 控制请求使用 HMAC-SHA256、时间窗口和 nonce 防重放。
- 通话 PCM 仅在内存和网络流中处理，不落盘。
- 日志与错误界面不得显示设备 Secret、HMAC、Push token 或完整媒体地址。

## 当前状态

模拟器构建与测试已覆盖主要协议和传输选择。正式发布前仍需完成 Apple 签名、实体 iPhone/Apple Watch 安装、三星实机拨号接听、双向语音、短信与后台推送验收。
