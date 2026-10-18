# AirSIM 三星 Android 控制 App

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
# 未发布：Relay 命令路由

共享源码新增定向命令、严格关闭帧解析和可取消的重连代次；SIM / 名称 / token 更新不替换命令连接。[兼容与验收边界](../../docs/relay-agent-routing.md)。本轮未安装或发布。
