# DJOneHub for iPhone / iPad

这是 DJOneHub 的 iPhone/iPad 通用客户端。最终运行方式是 QDC507 直接通过 USB-C 接入移动设备，App 通过模块提供的 CDC ECM 网络连接 `http://192.168.225.1:7575/`，日常使用不依赖 Mac。

模块 Agent 0.3.38 起包含增强版 WRT Lite：复用原厂 `bridge0`、dnsmasq 与蜂窝 NAT，在不安装完整 OpenWrt 的前提下提供转发开关、NAT 自动修复、月流量配额、31 天历史、定时断网、DNS 覆盖、端口转发及客户端在线状态。Agent 0.3.39 新增同版本修复安装、空间预检、持久安装状态与有界日志，App 可在设置中的“Agent 维修中心”查看过程和主动重装。QDC507 当前 3.18.44 内核未编译 TBF/HTB、TUN 和 filter/mangle，因此界面会明确显示不支持 SQM、VPN 与按设备防火墙；不会用无效配置伪装相关能力。

## 功能范围

- 拨号、接听、拒接、挂断、DTMF、静音、通话录音与 USB Audio。
- 最近通话、短信收发、短信清理、系统通讯录。
- 模块状态、4G 策略、实时流量、GPS、网络诊断与模块重启。
- eSIM Profile 查询、下载、切换、重命名、删除与卡内通讯录检测。
- AT 调试、模块初始化、语音运行时、外观、语言与铃声。

## 当前开发状态

iPhone/iPad 客户端当前版本为 `0.6.7 (24)`，最低支持 iOS/iPadOS 16.3。模块侧 Agent `0.3.5` 使用已通过实机启动矩阵的 Go 1.24.13 构建，ARMv7 静态产物和单元测试已通过。通话记录和短信以手机本地 JSON 为唯一长期副本；模块仅暂存尚未交付的数据，收到手机原子写入成功回执后立即清除对应通话记录及 SIM/ME 短信。

工程已启用 iPhone 与 iPad 通用设备族；App 会先完成麦克风授权与本地音频启动，再请求模块 PCM 路由。Agent 会在 D5/D6 网络桥之前同时启动 VoLTE D4 route session 与 `voc_svr` 基带媒体路由。PCM helper 为两个工作线程显式使用 256 KB 栈，TCP 下行按 8 kHz PCM 的 `16 KB/s` 使用单调时钟节拍，TCP 上行按 `256 B/16 ms` 的硬件节拍平滑写入。通话中的 PCM 进程或 USB 网络短暂中断后，Agent 与 App 会在当前通话内重建媒体链路。

## 一键接入与安全更新

`../dist/DJOneHub-QDC507-Module-v0.3.5/` 是本地构建出的可分享自包含模块部署包；正式分发使用私有仓库 Release 资产。部署包包含 Mac 一次性部署器、QDC507 ADB 探针、libusb、DATA11 内核桥、Agent、语音运行时、SHA-256 清单和 `install.command`。部署器会拒绝未知 USB ID、固件内核版本、原厂服务 PID、通话状态或语音文件摘要不匹配的模块，不会停止或抢占 `ql_manager_server`。

Agent 的 `/api/system/update` 只接受固定平台的 gzip tar 更新包。清单使用发布者 Ed25519 私钥签名，Agent 只内嵌公钥；每个文件还要通过 SHA-256、路径白名单、大小和权限校验。更新在无通话时执行，先写入同一 UBI 分区的暂存目录，再原子替换并写入待确认标记；启动器健康检查失败时自动恢复上一份备份。

App 首次接入会自动执行模块版本检查、签名更新、Agent 初始化、语音运行时检查、麦克风授权和 USB 模式修复。用户只需把已完成一次出厂部署的模块插入 iPhone 或 iPad，并允许系统权限；更新包内置在 App 中，不需要用户操作 Mac。完全空白且未部署的模块仍必须先通过 `install.command` 完成第一次出厂配置，这是 iOS/iPadOS 公共 API 的权限边界。

实机差分已确认 Mac USB AT interface 2 经内核 `g_smd` 桥接到 `DATA11`；`/dev/smd21` 实测返回 `ENODEV`，不能作为 transport。`/dev/smd7` 是原厂 `ql_manager_server` 使用的 `DATA1`。停止原厂服务会连带中断 ECM 数据网，因此旧的抢占式部署和相关诊断已由代码安全闸禁用。

`../module/kernel-bridge/qdc507_data11_bridge.c` 实现独占字符设备 `/dev/djonehub_data11`，支持阻塞/非阻塞读写与 `poll`。桥模块已按实机 `/proc/config.gz` 和原厂模块 ABI 构建。移动模式使用 `diag,ecm,ffs`，新版 Agent 已通过 DATA11 自动启动；模块本机 `/api/health` 应返回 `ok:true`、`version:0.3.5` 且无轮询错误。双模式启动器会在 Mac 模式保留 `diag,serial,ecm,ffs,audio`，不会停止或抢占原厂 `ql_manager_server`。

实体 SIM 与 eSIM 的路由由模块当前卡槽状态决定。eUICC AID 的 `AT+CCHO` 在实体 SIM 路由下返回 `ERROR` 不代表 DATA11 桥故障；Agent 会把这类结果显示为“当前卡片为实体卡，非 eSIM 卡片”。部署器提供启动器更新和运行时原子更新动作，提交前会确认无通话、锁定原厂服务 PID，并在失败时自动回滚。

安装完整 Xcode 后打开 `DJOneHub-iPad.xcodeproj`，选择自己的签名 Team 和 iPhone/iPad 设备即可构建。签名 IPA、证书、Provisioning Profile 和本机实机备份均由 `.gitignore` 排除，不属于源码仓库。

## 通话音频方案

iOS/iPadOS 公共 API 无法像 Mac 一样直接控制四条 USB UAC/本机音频端点，因此移动模式不使用 UAC。模块侧 `mavo-pcm-bridge` 从原厂音频库取得通话 PCM，并在 `192.168.225.1:7580` 提供 `8 kHz / PCM16LE / mono` 的 TCP 双工流；移动端使用 `AVAudioSession.playAndRecord + voiceChat` 采集麦克风、播放远端音频并启用系统回声消除。协议握手为 `DJ1PCM1\n` / `DJ1READY`。

ARMv7 helper 的 ELF、动态链接器、GLIBC 版本和原厂音频符号检查均已通过。最终听筒响度、回声和双向声音质量仍需在不同运营商的真实通话中持续验证，签名证书本身不会改变音频路由能力。

## 尚未完成

- eSIM Profile 下载仍需验证模块内 TLS、证书链和 SM-DP+ 网络事务；当前下载接口明确返回未实现。切换、重命名和删除已接入 `euicc-go` LPA，DATA11 AT 与 Agent 已通过实机通信验证；eUICC 管理仍需换回 eSIM 路由后验证，不能用当前实体 SIM 的 `CCHO ERROR` 冒充完成。
- 通话录音、听筒响度和回声抑制仍需结合真实通话继续验证。
- 不同 iPad/iPhone 型号的 USB ECM 枚举、DHCP 行为和以太网优先级仍需扩大实机矩阵。

## 安全边界

客户端只接受环回或 RFC1918 私有 IPv4 的 HTTP 模块地址。AT、eSIM 和服务停止操作均由用户显式触发；删除与停止服务必须二次确认。部署脚本不得停止 `ql_manager_server`。完整 DATA11 测试还带有默认路由保护闸：Mac 默认出口不是 Wi-Fi `en0` 时，脚本会在 USB 重绑定前直接拒绝执行。

开发 Mac 应设置为 `Wi-Fi` 优先、模块 ECM 次之；模块仍可通过 `192.168.225.0/24` 访问，但不应抢占默认互联网出口。移动设备测试若没有取得 DHCP 地址，可临时设置 `192.168.225.2/24`，路由器与 DNS 留空，以保留 Wi-Fi 默认互联网出口。

## 许可

本项目基于 DJOneHub Mac 版公开源码移植，仅限 PolyForm Noncommercial License 1.0.0 允许的非商业用途。详见 `../THIRD_PARTY_NOTICES.md`。
