# AirSIM 三星 Android 控制 App

2026-11-05：[Apps v0.9.8.23](../../docs/releases/0.9.8.23.md)，Android Standalone／AVF Bridge `0.9.8.23（128）`。包含兼容设备的跨模式早期媒体和 iPhone 云端扬声器恢复；AVF Linux Agent 未更新，不能仅通过更新 Bridge 获得新媒体能力。发布及实机验证范围见说明；以下旧版本记录保留追溯。

2026-10-31 发布准备：[Apps v0.9.8.20](../../docs/releases/0.9.8.20.md)，Android `0.9.8.20 (125)`，配套 iPhone build 152。修正认证网关 Push POST 允许规则；新安装推荐 Standalone，本次不发布 Linux Agent。正式包沿用原签名，真机验收边界见发布说明。

2026-10-20 发布：[Apps v0.9.8.8](../../docs/releases/0.9.8.8.md)，共享 APK `0.9.8.8 (102)`。Standalone 推荐用于新安装；AVF Bridge 不等于 Linux Agent 更新。本版包含配对时钟校正、双卡短信/卡槽、KernelSU Root 通道、私有网段与可配置端口、VoBLE 静音修复；实际 OEM 音频仍需验证。

0.9.8.1 新增应用更新入口：首次安装／升级启动展示包内版本说明；「设置 → 关于」可重看和检查对应 Standalone／AVF Bridge APK 的新版。每日自动检查有界，与「检查并安装最新 Agent」的 Debian 更新完全分开，不自动下载、安装或卸载 App。[行为与维护约定](../../docs/app-updates.md)。

未发布安卓候选 `0.9.8.1（94）`：共享 PCM 桥在启动失败时及时释放已创建端点，原始失败阶段／错误码穿过 Shizuku 快照保留到 Watchdog TXT；保留 93 的臻情分支，不改变其他厂商静音策略。华为 Android 10 的真实音频能力仍待验证。[依据与限制](../../docs/android-pcm-startup-failures.md)。

未发布安卓候选 `0.9.8.1（93）`：共享的 Shizuku 输出策略增加臻情 Zhenqing 的最低非零音量兼容分支，避免已观察到的静音后下行 PCM 近乎全零；Watchdog 同时校验未静音与目标音量，结束后恢复原状态。不改 iOS／Relay／PCM 增益，不代表全部紫光展锐设备已验收。[依据与真机验证边界](../../docs/zhenqing-android13-call-audio.md)。

本轮应用版本：[0.9.8（92）](../../docs/releases/0.9.8.md)，优先使用 Standalone，推荐 Android 10–13 用户升级。共享源码包含下述双通道协议与配对修复；Linux Agent 仍未发布新二进制，旧 AVF 需具备 `canonical_call_ids` 才能使用新的归属 VoWLAN 拨号。后文较早“未发布”说明为开发追溯，不代表本轮全场景真机验收。

未发布双通道开发：`/v1/health` 增加 `identity_proof`，使用本次已认证请求的 nonce 与 `agent_id` 生成 HMAC；新多设备目录必须验证该证明才合并 VoWLAN／VoBLE 身份。旧 iOS 可忽略新增字段；旧 Android 不具备新多设备身份验证能力，需要升级 APK。原请求签名、时间戳与防重放检查保留，不涉及 Relay 修改。本轮功能仍在开发，尚未安装或发布。

双通道通话归并还需 `canonical_call_ids` 能力：Standalone 直接支持；AVF Bridge 仅在 Linux Agent 宣告能力时启用。新版 Linux 状态保留原 `id`，另外导出 Telecom `android_id`。iOS 归属拨号携带 `operation_id`，网关返回绑定请求 nonce、操作 ID、Telecom ID 和后端 ID 的 HMAC 回执；不同传输不按号码或设备名猜测。旧客户端不传该字段时保持原协议；旧 AVF 不宣告能力时，新归属拨号在发送实际命令前拒绝，需要同时升级 APK 与 Linux Agent。本轮不会自动部署。

未发布配对回归修复：一次性配对恢复 Wi-Fi／热点上的双端链路本地 IPv6 连接，避免 Bonjour 选中 IPv6 后被手动地址的 IPv4 来源检查误拒。来源仍须属于系统确认的 Wi-Fi／热点接口，六位码加密和限时校验不变；控制与 PCM 网关的 IPv4 策略不变。详见[配对安全边界](../../docs/manual-ip-pairing.md#协议与安全)，尚未完成本轮双端真机成功配对验收。

工作区候选构建为 `0.9.7.1 (86)`，尚未发布。Standalone 与 AVF Bridge 共享「设置 → 关于」：从实际安装 APK 读取版本号与 versionCode，可打开 GitHub 仓库和版本发布页；不依赖 Agent、Relay 或网络查询版本。

build 86 的本机通话静音只由已确认远程通话和就绪媒体触发，不再仅因默认 `remote_silent` 设置静音所有原生通话。链路失效或挂断恢复先前状态，蓝牙 PCM 中断主动释放所属会话，静音与恢复结果均记录到 VERBOSE TXT。[行为及验收边界](../../docs/remote-call-local-output-mute.md)。

build 85 在 VoWLAN 前台服务通过正常权限 `ACCESS_NETWORK_STATE` 监听 Wi-Fi 网络和地址变化，重发 NSD 广播并隔离过期注册回调，不因仅重发广播关闭现有控制／PCM Socket。不要求 Wi-Fi 已验证可上网，不更改 Linux Agent 或 Relay。[机制与验收边界](../../docs/vowlan-network-return.md)。

build 84 提供绑定远程通话身份的音频 Watchdog、Shizuku 受控静音复检及真正的 TXT 导出；无法确认归属的旧 AVF 云端不自动修复，不把系统静音标志当成物理扬声器无声证据。[使用与边界](../../docs/sms-deletion-audio-watchdog.md)。

build 83 的[手动地址配对](../../docs/manual-ip-pairing.md)复用现有加密 claim，新增限时公开会话元数据读取与已认证的实际网关端口回传。配对页显示当前地址／随机配对端口；Tailscale 用户填本机 Tailscale IPv4。通话网关分别绑定 Wi-Fi、指定 VPN IPv4 或回环代理入口，不绑定公网／通配地址；回环入口仍需 HMAC 与 PCM 认证，不得代理 Linux `8575/8576` 或将 Shell `7580` 开放到外网。

该目录包含 AirSIM Android 端的共享实现以及旧 AVF 兼容 Manifest。新安装推荐使用根目录的 [Android Standalone APK](../../android-standalone/README.md)，由同一 APK 内置 Agent；只有兼容旧部署时才使用这里的 AVF 版构建入口。

当前正式应用版本为 [`v0.9.7.2`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.7.2)（Android `versionCode 91`），包含 Android 10–13 兼容性修复及后续稳定性改动，推荐升级；新安装优先 Standalone。三星最低音量策略不保证完全静音，实际效果待复验，见[发布说明](../../docs/releases/0.9.7.2.md)。配套 Linux AVF Agent 保持 [`v0.4.6`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.6)。维护者云端模式使用 `https://airsim-push.remotepilot.site`，不得改用 DJOneHub 的 `https://push.remotepilot.site`。自行签名的 Apple 客户端需要部署与其 Bundle ID、APNs 凭据匹配的独立 Relay。

## 主要职责

- 申请并维护默认电话 App 角色。
- 监听来电、拨出、接通、挂断和 DTMF 状态。
- 将通话与短信事件发送给 AVF Agent。
- 执行 Agent 下发的拨号、接听、拒接、挂断和短信命令。
- 提供限时配对窗口与六位确认码。
- 在三星热点接口上发布经过认证的 VoWLAN 控制与 PCM 服务。
- VoWLAN 优先使用 `7592/7593`，端口占用时自动选择可用端口并通过服务发现公布实际端口，避免与 DJOneHub 的 `7590/7591` 冲突。
- 维护前台守护服务、Shizuku 状态和故障诊断。
- 通过独立 AVF installerd 检查、安装和回滚签名 Debian 包。
- 启动时检测 AVF、AOSP Linux Terminal 和 AVF 私网状态，并提供可复制的一键安装命令。
- 状态首页明确显示当前使用 VoWLAN、云端模式、云端异常或离线；仅配置 Relay 不会被误报为已经在线。

## 默认通话卡

Android AirSIM「设置 → 默认通话卡」支持选择已启用的 SIM/eSIM，或保持「跟随系统默认」。本地保存的选项用于 BLE、VoWLAN、Relay 和 Android 本机拨号，不改变系统默认通话卡及短信卡，无需 Relay 注册或网络连接。

读取可选卡需要现有的电话状态权限，号码展示权限为可选。每次拨号使用系统提供的 `PhoneAccountHandle` 并重新检查其是否仍启用；指定卡不可用时返回明确错误，不静默切换其他卡。系统紧急呼叫路由不受此选项保证。

## 运行要求

- 三星 Android 测试手机，目标 SDK 35。
- 用户将 AirSIM 设置为默认电话 App。
- 用户确认 AirSIM 已获得「发送短信」权限，并在双 SIM 设备上指定默认短信 SIM；不同 Android 系统可能随电话角色授予该权限，也可能要求单独授权。
- 官方 Shizuku 管理器已启动，并向 AirSIM 授权。
- Android AVF Agent 可通过设备内部私网访问。
- Agent 控制 token 已写入 App 私有存储。

## 构建与测试

在仓库根目录运行：

```sh
./android/phone-control-app/test.sh
./android/phone-control-app/build.sh
sh ./android/phone-control-app/verify-apk.sh
```

调试 APK 输出到：

```text
android/phone-control-app/build/android/AirSIM-Phone-Bridge-debug.apk
```

正式发布使用仓库外的长期签名库；不要用 debug keystore 发布，否则后续版本无法安全升级：

```sh
AIRSIM_ANDROID_BUILD_VARIANT=release \
AIRSIM_ANDROID_KEYSTORE=/absolute/path/to/airsim-android-release.jks \
AIRSIM_ANDROID_KEY_ALIAS=airsim-release \
AIRSIM_ANDROID_KEYSTORE_PASSWORD='从 Secret Store 注入' \
AIRSIM_ANDROID_KEY_PASSWORD='从 Secret Store 注入' \
./android/phone-control-app/build.sh
```

Release APK 输出到 `android/phone-control-app/build/android/AirSIM-Phone-Bridge-release.apk`。签名库和密码不得提交到 Git；公开 Release 必须复用同一签名证书，才能覆盖升级已安装版本。

## 三星手机配置

首次权限请求结束后，App 自动检查 Shizuku：未安装的弹窗包含官方地址 `https://shizuku.rikka.app/zh-hans/download/` 和下载入口；已安装未启动提示打开管理器，未授权提示授权。就绪时不弹窗；本次启动最多一次，可点「稍后」继续。启动引导与权限、AVF 环境及闪退报告提示按顺序呈现，不会自动安装 Shizuku 或绕过用户授权。

1. 安装 APK 并启动 AirSIM。
2. 如果启动提示显示 AVF Linux 尚未运行，点“启动 Linux Terminal”；若 Terminal 未启用，点“打开开发者选项”并启用 Linux 开发环境。
3. Linux 首次启动后，复制并在 Terminal 中执行 v0.4.6 首次安装命令；已有 `0.4.4-1` 的设备请先按[一次性密钥迁移](../../docs/AVF_INSTALL_GUIDE.md)升级到 v0.4.5，再通过安装器升级，不能通过旧 installer 直接跳过密钥迁移：

   ```sh
   bash -o pipefail -c 'curl -fsSL --connect-timeout 10 --max-time 90 --retry 2 --proto =https --proto-redir =https --tlsv1.2 https://github.com/kai-wu-cortex/AirSIM/releases/download/v0.4.6/install-avf.sh | sudo sh'
   ```

4. 在系统设置中选择 AirSIM 作为默认电话 App。
   首次启动还应允许「发送短信」权限；「读取短信」是可选的收件箱兜底权限，仅用于扫描授权后新收到的短信，拒绝后仍使用短信广播。若有两张 SIM，请在系统 SIM 卡设置中指定默认短信 SIM。缺少发送权限或默认短信 SIM 时，Agent 会返回明确错误，不会把短信命令当作通话命令执行。
5. 启动 Shizuku，并在 AirSIM 的 Shizuku 区域完成授权。
6. 在 Terminal 运行 `sudo airsim-avf-pair`，从当前 AVF 私网确定 Agent 地址，把输出的控制 token 保存到 App。不要把 token 粘贴到日志、截图或仓库。
7. 确认 Agent、音频桥和 VoWLAN 状态均为就绪。
8. 打开两分钟配对窗口，让 iPhone 输入三星端显示的六位配对码。

安装命令也固定显示在 App 的“设置 → AVF Linux 首次安装”中，可随时复制；**复制不会自动运行**，须在 Debian Terminal 粘贴并按回车。App 只会在 AVF 未启动，或 AVF 已启动但 Agent 尚未配置时显示启动提示。`Agent 可达 · 尚未配对` 只表示 `8575` 的无凭据健康检查通过，不代表安装管理或通话控制已就绪；`installerd` 还需要 `8576` 服务和控制 token。修复版线上引导脚本遇到已有 `current.deb` 会优先恢复服务而非拒绝运行；发布前仍需按[AVF 安装与无损排障指南](../../docs/AVF_INSTALL_GUIDE.md)手动检查 systemd 服务，不要清除 Linux Terminal 数据。

Terminal 若报 `udev` 需要较新 `libudev1`、`unmet dependencies`，属于 AVF Debian 包状态问题。先在 Terminal 运行 `apt-cache policy udev libudev1` 和 `sudo apt-get -s -f install`，检查模拟计划；不要直接让 App 或脚本自动执行 `apt --fix-broken install`。

## 厂商系统兼容性边界

本版修复增加 URL UTF-8 编解码、Shizuku 命令输出与 PCM 失败清理的旧 API 替代；短信工厂按 API 31 分支，保留默认短信 SIM。旧 AVF 模式在 Android 10–13 改为可点击通知提示用户恢复 Terminal，只有 API 34+ 才调用新的后台启动选项。Shizuku daemon 版本提升至 8，覆盖升级后不复用旧静音实现；使用 shell 包身份的 `AudioManager` 操作并回读静音结果，挂断恢复之前的静音/音量，失败保留恢复快照供重试，不虚报静音成功。OEM 不支持时仍须用户处理。

Android 11/12 真机曾在启动时因 `ByteArrayOutputStream.toString(Charset)` 和 `Collection.toArray(IntFunction)` 缺失而闪退。共享实现改用兼容的 UTF-8/ASCII 解码与数组转换；VoWLAN、Relay、PCM 和闪退报告路径同步替换 `InputStream.readNBytes`。`test.sh` 与 APK 构建都会检查编译后的方法引用，阻止这些已知不兼容调用回归；这是定向回归检查，不是完整 Android API lint，仍需目标系统真机验收。

AirSIM 会识别小米、Redmi、OPPO、OnePlus、realme、vivo、iQOO 和荣耀等厂商，并区分“Terminal 已安装但停用”“Terminal 未安装”和“系统未公开 AVF”三种情况。App 可以启动已安装的 AOSP Linux Terminal，或跳转到开发者选项，但普通第三方 App 无法强制补装厂商固件删除的 Terminal、打开未公开的 AVF 系统功能，或绕过系统签名权限。遇到后两种情况需要厂商系统更新、包含 Terminal 的系统镜像，或由 OEM 将 AirSIM 作为特权系统组件集成。

## 通话与音频策略

来电通知呈现默认使用 `remote_silent`。本机通话声音仅在唯一的已确认远程通话具有就绪 PCM 所有者、且正在拨号／通话／保持时由 Shizuku 受控静音；未接听、普通本机通话或多通话不盲目静音。媒体中断、通话结束或服务销毁时恢复原音量与静音状态。旧 AVF 云端无法提供精确媒体归属时不自动静音，不能再依赖通知模式跳过身份检查。紧急通话始终交回系统预装电话 App。

作为默认电话 App，AirSIM 还提供独立锁屏来电界面和通知接听/拒接/挂断入口；它不展示短信或设置内容。来电通知使用新的高优先级渠道，避免既有低优先级前台服务渠道无法升级的问题。系统若未授予全屏来电权限，会退化为可操作的横幅通知；是否亮屏以及锁屏操作仍需在每种目标机型上实测。

## 短信发送

iPhone 经 VoWLAN 或云端 Relay 提交发信请求后，AVF Agent 把 `send_sms` 命令交给 Android Bridge。Android Bridge 使用系统短信服务和默认短信 SIM 分段发送；每一段都收到系统「已发送」回执后，才向 Agent 回报成功。这个回执表示手机已把短信交给运营商网络，不代表收件人已收到。超时或失败时，请先在手机短信记录中核对，避免重复发送。短信命令与 Telecom 通话 ID 控制相互独立。

Shizuku 发信在 UserService 内清除传入的 Binder 调用身份，并在 `finally` 中恢复。shell 进程使用系统派生的 `com.android.shell` Context；API 30+ 补齐 `app_process` 缺少的电话服务注册表，API 31+ 使用 Context 创建指定 SIM 的 `SmsManager`。指定 SIM 初始化失败时返回错误，不降级到默认卡。Shizuku 返回 `ok` 仅表示 API 接受请求，不是运营商发送回执或收件人送达回执。

2026-10-21，该路径在一台红米（私有 Android build 103）上验证了锁屏、熄屏发信，无需操作确认弹窗，也未使用 root、关闭系统优化或更换默认短信 App。其他 ROM、双卡切换、长短信和重启恢复尚未完成真机验证。此修改不涉及 5G 消息／RCS 接收。`sh android/phone-control-app/test-privileged-sms.sh` 可单独运行身份、SIM 选择和失败路径的 JVM 回归测试；这些测试不代替厂商系统实测。

Shizuku 读收件箱不经 `ContentResolver`。UserService 是 `app_process` 起的 shell／root 进程，没有 ActivityManager 的 App 记录，Context 的调用包名也不属于该 uid，用 `ContentResolver` 查询必然抛 `SecurityException`。现与 AOSP `content` 命令相同：用 `getContentProviderExternal` 取 SMS provider，以 shell 身份查询（Shizuku 以 root 运行时为 `root`；API 31+ 用 `AttributionSource`，API 29–30 用调用包名），用完 `removeContentProviderExternalAsUser` 释放。返回行带 `sub_id`，供卡槽标注。AirSIM 自带的 root 通道仍未实现收件箱读取，只用本地视图。

2026-11-02，该路径在一台小米 13 Pro（HyperOS 3.0 / Android 16）上验证：`shizuku_sms_inbox_failed` 不再出现，`sms_inbox_scan source=shizuku` 每 30 秒成功一次。该机此前从未走通这条路径，一直退回 App 自身被过滤的收件箱视图。真实来信经此路径转发、API 29–30 的接口形状尚未在真机验证。`sh android/phone-control-app/test-privileged-sms.sh` 同时运行该路径的 JVM 回归测试。

## VoBLE 广播生命周期（未发布，2026-10-19）

共享 `VoBLEGatewayService` 现在监听系统蓝牙状态：打开时重新启动 GATT server／广播，关闭时释放失效 server；广播启动失败会关闭失效 server 并按 2/4/8 秒有界重试 3 次。此前服务先于蓝牙启动时不会自动恢复，iPhone 会一直停在“正在发现”。诊断日志只记录尝试次数、错误码和状态，不记录设备地址、号码或密钥。JVM GATT 生命周期回归通过；正式包仍需原 release keystore，未安装或发布。

## 网络与安全

- Agent 配置仅接受 AVF 私网地址；AVF 网段由系统动态分配，不能固定为 `10.185.5.0/24`。App 优先根据 `avf_tap_fixed` 所在网段推断来宾地址，仍需在当前设备上验证。
- bearer token 只保存在 Android 私有偏好设置中，不写入日志。
- VoWLAN 仅绑定有效的三星热点地址，不监听通用网络接口。
- 所有控制请求均执行路由白名单、消息大小、时间戳、随机数与 HMAC 校验。
- 原始 PCM、配对明文和认证材料不得进入诊断日志。
- Agent API 使用 AVF 端口 `8575`，救援安装服务使用 `8576`；两者复用首次引导生成的控制 token。
- 旧版 AirSIM 保存的 `:7575` 地址会迁移到 `:8575`；`7575` 可能属于同机 DJOneHub，不再视为 AirSIM 在线证据。未发布端口迁移版 Agent 前，不能用旧版在线包做共存安装。
- Android 管理端只提交签名的 `airsim-avf-agent_*_arm64.deb`，芯片厂商差异由 App 的能力探测处理，不选择不同 Debian 包。
- “检查并安装最新 Agent”从 `kai-wu-cortex/AirSIM` 的最新 GitHub Release 选择唯一的 `airsim-avf-agent_*_arm64.deb` 及同名 `.sig`；Release 缺包、缺签名、多包或非 HTTPS 下载都会被拒绝。

## 端到端加密云端短信（Standalone，issue #24）

- 配对：Standalone 在 `GET /pair/v1/info` 返回 `capabilities.e2e_sms: 1`，Bonjour TXT 带 `e2e=1`。新版 iPhone 只在安卓和 Relay 都声明支持时，才把 32 字节的 `e2e_key`（base64url、无填充）放进加密的配对包；每次云端配对都会替换钥匙，不带钥匙的云端配对会删掉旧钥匙，本地模式配对不保留钥匙。Relay 回滚到不认识 `e2e` 的版本时，加密短信留在队列里等待，不会被丢弃。安卓在任何模式下都会在 `registerPairing` 之前删掉它；只有 Standalone 会按「iPhone 设备编号＋Relay 地址」把它存进单独的偏好文件 `e2e_sms_keys`。经 `/api/push/register` 等其他途径带来的 `e2e_key` 一律丢弃。AVF 模式不声明、不保存。
- 上传：当前云端注册有钥匙时，`/v1/events/sms` 只带 `event`、`delivery_id`、`timestamp` 和 `e2e` 信封（AES-256-GCM，附加数据绑定设备、Agent 和去重编号），不带发件人、正文和接收卡槽。信封里的明文 JSON 依次是 `sender`、`content`、`timestamp`、`truncated`，已知接收卡槽时再加 `sim_slot`（如 `SIM 1`，明文上传时它在外层）。明文超过 2,400 字节时按码点截断，并标记 `truncated`。无法加密的短信留在队列里，绝不改发明文。Relay 返回 `{"error":"invalid encrypted SMS"}` 或 `{"error":"encrypted SMS too large"}` 时视为最终拒绝。
- 去重编号：有钥匙时改为 `HMAC-SHA256(delivery-id 子密钥, 发件人\0时间\0正文)`，Relay 无法拿常见验证码去比对反推。广播、收件箱扫描和通知读取三条路径用同一算法，云端和局域网两份副本的编号一致。没有钥匙时与之前完全相同。
- 注册上传：不论是否加密，`/v1/devices/register` 都只上传 Relay 读取的 14 个字段；VoWLAN 和 E2E 钥匙、通知转发配置、Relay 地址和安卓身份信息不再离开手机。
- 依赖 Relay 支持（`/healthz` 的 `capabilities.e2e_sms`）和新版 iPhone App。任何一端没更新，iPhone 都不会下发钥匙，短信照旧明文上传。`sh android/phone-control-app/test-e2e-sms.sh` 运行加密、配对钥匙、注册白名单和上传正文的 JVM 测试，加密结果与 Node 独立计算的向量逐字节对照。

# 未发布：Relay 命令路由

共享源码新增定向命令、严格关闭帧解析和可取消的重连代次；SIM / 名称 / token 更新不替换命令连接。[兼容与验收边界](../../docs/relay-agent-routing.md)。本轮未安装或发布。

## Shizuku 收件箱首次追平（2026-11-02）

第一次成功读取特权收件箱时固定一个 15 分钟窗口，只转发窗口内收到的短信；旧行只推进持久游标。每批最多 100 行，满批继续追平，不足一批才记录完成。窗口在批次和重启之间保持不变，完成后恢复正常游标补收，不截断日常离线期间的短信。优先以手机接收时间判断窗口，无接收时间才回退运营商时间；无有效时间的旧记录不生成新通知。空扫描只在首次追平完成时记日志，后续仅有新短信时记录。

反射调用显式允许访问非公开代理类的公开方法，覆盖 API 29/30/31/36 的测试形状；参见 [AOSP ContentProviderProxy](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-11.0.0_r25/core/java/android/content/ContentProviderNative.java)。JVM 回归不能替代对应 Android 版本的真机验证。
