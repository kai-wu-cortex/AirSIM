# AirSIM — Android 与 iPhone / Apple Watch 跨设备通话、短信和 VoWLAN

[Apps v0.9.8.20 · Android 125 / iOS 152](docs/releases/0.9.8.20.md)：后台接听音频启动、VoWLAN 恢复、独立 Push 注册与 CallKit 号码显示修正。纯本地跨端协商及零 Relay 流量仍未完成端到端验收；请阅读发布限制。AVF Linux Agent 保持 v0.4.7。

本版包含 [APNs 接听后的本地音频启动竞态修正](docs/vowlan-first-call-startup.md)。前后台重启轮询不再撤销同一通话的音频启动，真正挂断、媒体归属／锁定路由变化和 CallKit 停用仍会使其失效；TestFlight 上传与真机验收状态见发布说明。

工作区未发布修复：APNs 与本地通话终态按认证身份收尾原 CallKit／PCM，补齐跨通道事件先后顺序与冷启动接管；保留过期事件隔离和本通传输锁定。[实现与验证边界](iOS/README.md#apns-来电的远端挂断未发布)。

[![Android Standalone](https://img.shields.io/badge/Android-Standalone%20APK-3DDC84?logo=android&logoColor=white)](android-standalone/README.md)
[![iOS](https://img.shields.io/badge/iOS-16.3%2B-000000?logo=apple&logoColor=white)](iOS/README.md)
[![watchOS](https://img.shields.io/badge/watchOS-10%2B-000000?logo=apple&logoColor=white)](iOS/README.md)
[![Android AVF](https://img.shields.io/badge/Android%20AVF-Linux%20arm64-FCC624?logo=linux&logoColor=black)](module/packaging/README.md)
[![Apps release](https://img.shields.io/badge/Apps-v0.9.8.20-2563EB)](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.8.20)
[![AVF Agent release](https://img.shields.io/badge/AVF%20Agent-v0.4.7-0F766E)](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.7)
[![Cloudflare Relay](https://img.shields.io/badge/Relay-airsim--push.remotepilot.site-F38020?logo=cloudflare&logoColor=white)](https://airsim-push.remotepilot.site/healthz)
[![Project status](https://img.shields.io/badge/status-active%20development-1f6feb)](#项目状态)
[![License](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-7c3aed)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/kai-wu-cortex/AirSIM?style=flat&logo=github&label=Stars)](https://github.com/kai-wu-cortex/AirSIM/stargazers)

**AirSIM 是一个以 Android 手机为蜂窝通信终端，让 iPhone 和 Apple Watch 远程拨打、接听电话与收发短信的源码可见跨设备通信项目。** 推荐的 Android Standalone APK 在同一前台服务中完成 Android Telecom、短信、设备身份、Relay 心跳、云端命令和媒体编排，不需要 AVF Linux、Terminal、Debian、`8575/8576` 或 `airsim-installerd`；Apple 客户端使用 CallKit、PushKit、ActivityKit 和 VoWLAN，可选的 Cloudflare Workers Relay 提供公网事件、APNs 推送、命令队列与媒体中继。

AirSIM is a source-available, noncommercial cross-device calling and messaging project that connects Android phones, iPhone, Apple Watch, Android AVF Linux, CallKit, PushKit, VoWLAN, APNs, and Cloudflare Workers.

> 本仓库包含完整源码、构建脚本与部署文档，不提供可复用的 Apple Developer 身份、生产 APNs 密钥或 Cloudflare 账户资源。维护者部署了仅供自身签名构建测试的 AirSIM Relay，但它不是面向第三方 Bundle ID 的公共托管服务，也不提供可用性承诺；重新签名的使用者必须自行部署 Relay。项目不能替代紧急呼叫能力，生产使用前必须完成目标 Android 手机、iPhone 和 Apple Watch 的联合验收。

> [!IMPORTANT]
> 本项目面向个人学习、研究、实验和其他非商业用途。任何商业使用、收费服务、商业产品集成或预期商业应用均未获授权；如需商业许可，必须事先取得版权所有者的单独书面许可。详见 [PolyForm Noncommercial License 1.0.0](LICENSE)。由于禁止商业用途，本项目属于 **source-available**，不是 OSI 定义的开源软件。

**Tags / Topics:** `Android` · `iPhone` · `Apple Watch` · `CallKit` · `PushKit` · `VoWLAN` · `VoBLE` · `Android AVF` · `Cloudflare Workers` · `APNs` · `SwiftUI` · `Go`

## Buy Me A Coffee
<img width="300" alt="05d04c887d99c9df849f81b1cff672dd" src="https://github.com/user-attachments/assets/91620ed1-727e-4a81-9d99-d20d6d55bb58" />

**软件发布后大家的热情太高了，测试服务器的小水管撑不过大家的热情导致超出限额。如果你喜欢本软件，可以支持一下作者**

## 讨论群 ##
<img width="362" height="358" alt="image" src="https://github.com/user-attachments/assets/402158bb-2263-408c-a85f-00b34a16b1bd" />
https://t.me/+TRDazm-qnXlhNGRl

## 核心能力

- **应用版本说明与更新检测**：iOS／Android 首次安装或升级后展示离线说明，设置中可重看／手动检查应用新版；前台每日最多自动检查一次，不自动下载安装，不与 Linux Agent 更新混用。[说明](docs/app-updates.md)。

- **跨设备电话**：在 iPhone 或 Apple Watch 上拨号、接听、拒接、挂断、静音并发送 DTMF，由 Android 手机完成运营商通话。
- **Android 全屏来电**：无论“远端静默”还是“本机显示”，直接呼 Android 号码都会拉起全屏来电页和最高优先级通知，显示号码、接听、拒接与挂断；模式选择点击即保存。
- **跨设备短信**：同步短信状态、发送短信并通过 APNs 通知 Apple 客户端；本地模式可通过 VoBLE 控制通道发送。
- **小米短信辅助**：MIUI 非默认短信 App 无法读取完整 inbox 时，使用无障碍辅助确认“是否发送短信”，并可选择只转发 `com.android.mms` 新短信通知来回信；不要求默认短信角色，也不能绕过系统签名限制。
- **VoBLE 蓝牙直连**：独立于 Wi-Fi、Relay、PushKit 的连接模式，通过认证 BLE GATT 承载电话控制与双向音频；控制消息支持分片，选中会话断线后按 1/2/4/8/16 秒退避自动重连。
- **VoWLAN 本地直连与恢复**：同一局域网或 Android 热点内使用 HMAC 认证的控制与 PCM 链路；网络恢复时重新发现并认证，通话中不切换传输。
- **手动地址配对**：自动发现受限时可填写 Android IPv4 与配对端口，保留六位码加密认证；支持局域网及 Tailscale 地址。
- **CallKit、PushKit 与 Live Activity**：iPhone 使用系统来电界面和 VoIP push；灵动岛/锁屏可切换 Android Agent，并显示通话与连接状态。
- **单 APK Android 端**：内置 Agent 与 Bridge，安装后不再依赖 AVF Linux、Terminal、Debian 或 installer。
- **云端 Relay**：通过独立部署的 Cloudflare Worker、KV 与 Durable Objects 连接 Android 内置 Agent 和 Apple 客户端。
- **可观察的模式与自检**：Android 首页和 iOS 设置页显示当前 VoWLAN / 云端状态；iOS 可依次验证 Push 凭据、AirSIM Relay 身份、设备注册和 AVF Agent 90 秒心跳。
- **HyperOS 自动配置**：默认电话角色界面不可用时，可通过已授权 Shizuku 让 APK 自动完成系统角色设置。
- **Android 通话音频桥**：通过 Shizuku `UserService` 和系统 `TYPE_TELEPHONY` 路由在内存中转发双向 PCM，不保存通话音频。

## 系统架构

推荐的 Standalone 架构在同一个 APK 中运行 Bridge 与 Agent：

```text
iPhone / Apple Watch
        │  VoWLAN、VoBLE 或 Cloudflare Relay
        ▼
Android AirSIM Standalone APK
        ├─ 内置 Agent：身份、心跳、命令和媒体编排
        ├─ Android Telecom / 短信
        └─ Shizuku 通话 PCM 桥
```

旧 AVF 架构继续保留用于兼容和回退，但不再是新安装的推荐路径。

维护者当前使用 `https://airsim-push.remotepilot.site`，只允许 `com.eric3u.airsim`。DJOneHub 继续使用 `https://push.remotepilot.site`；两个域名背后是相互独立的 Worker、KV、Durable Objects 和 Dashboard token，禁止交叉复用。其他签名身份必须使用自己的域名、Cloudflare 资源和 APNs 凭据。

每通电话在建立时选择 VoWLAN 或 Relay，并在本次通话结束前保持同一传输路径，避免媒体和控制面在通话中途漂移。

### VoBLE 蓝牙模式

VoBLE 是与 VoWLAN、云端 Relay 并列的模式选项，不是现有 Wi-Fi 链路的必需组件。选择“蓝牙直连”后，iPhone 与 Android 使用一次性短码确认的临时密钥完成配对，控制消息和 G.711 μ-law 8 kHz 单声道音频均使用 AES-256-GCM 认证加密；通话期间绑定同一个 `call_id` 和 generation，避免重连后误操作另一通电话。短暂断链只允许在三秒内、同一通电话和同一 generation 上恢复。

蓝牙模式只传送 AirSIM 控制与通话音频，**不会把 Android 的移动网络通过 Bluetooth PAN 共享给 iPhone**。需要上网时仍应单独使用 Android 热点、Wi-Fi 或 iPhone 自身蜂窝网络。iOS 端继续使用 CallKit 展示和管理通话，但本地蓝牙模式不需要 PushKit 或 Relay；App 被用户强制退出后，iOS 不保证 BLE 后台唤醒，来电前应重新打开 AirSIM。Apple Watch 可镜像 iPhone 的 CallKit 来电和控制状态，实际音频路由仍由 iPhone/watchOS 系统决定，并不是 Watch 直接连接 Android BLE。

实现与验收边界见 [VoBLE 设计](docs/superpowers/specs/2026-10-12-voble-bluetooth-call-design.md) 和 [VoBLE 真机测试矩阵](docs/voble-real-device-test-matrix.md)。

## 仓库结构

| 目录 | 组件 | 主要职责 |
| --- | --- | --- |
| [`android-standalone`](android-standalone/README.md) | Android Standalone APK | 推荐入口；把 Agent、Telecom、短信、VoWLAN、Relay 和媒体编排合并为单一 APK |
| [`android/phone-control-app`](android/phone-control-app/README.md) | Android 控制 App | 默认电话角色、Android Telecom、配对、短信、VoWLAN 与守护服务 |
| [`android/phone-audio-bridge`](android/phone-audio-bridge/README.md) | 三星通话音频桥 | 通过 Shizuku 提供双向 PCM，并限制在 AVF 私网接口 |
| [`module/module-agent`](module/module-agent/README.md) | Android AVF Agent | 控制 API、设备状态、Relay 心跳、命令与媒体编排 |
| [`module/avf-installerd`](module/avf-installerd) | AVF 救援安装服务 | 校验签名 Debian 包、健康检查与失败回滚 |
| [`module/packaging`](module/packaging/README.md) | AVF Debian 发布 | 构建单一 `arm64` 包、systemd 单元和首次安装脚本 |
| [`iOS`](iOS/README.md) | iPhone / Apple Watch App | CallKit、PushKit、VoWLAN、短信、实时活动与通话媒体 |
| [`push-relay-worker`](push-relay-worker/README.md) | Cloudflare Relay | 设备注册、APNs、云端命令、Dashboard 与公网媒体 |
| [`docs`](docs) | 协议与设计文档 | VoWLAN / VoBLE 设计、三星热点配对协议与安全边界 |

## 快速开始

### 当前发布基线

| 组件 | 当前版本或地址 |
| --- | --- |
| Android Standalone / AVF Bridge | [`v0.9.8.20 (125)`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.8.20)，推荐安装 Standalone |
| iPhone / Apple Watch App | `0.9.8 (152)`，随 [v0.9.8.20](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.8.20) 提供 full／sideload unsigned IPA；TestFlight 状态见发布说明 |
| Android AVF Linux Agent | [`v0.4.7`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.7)（Debian 包版本 `0.4.7-1`） |
| AirSIM Relay | `0.2.1` · [`https://airsim-push.remotepilot.site`](https://airsim-push.remotepilot.site/healthz) |
| DJOneHub Relay | `https://push.remotepilot.site`（独立服务，AirSIM 不得使用） |

### 应用发布包

当前版为 [Apps v0.9.8.20（Android 125 / iOS 152）](docs/releases/0.9.8.20.md)，重点包含：后台接听音频启动、VoWLAN 恢复、独立 Push 注册与号码显示修正。纯本地跨端功能仍属实验阶段。

- `AirSIM-Android-Standalone-0.9.8.19-build124.apk`：推荐新安装，内置 Agent，不依赖 AVF Linux。
- `AirSIM-Android-AVF-0.9.8.19-build124.apk`：旧 AVF 部署的 Android Bridge；不包含新的 Linux Agent。
- `AirSIM-iOS-0.9.8-build148-unsigned.ipa`／`-sideload-unsigned.ipa`：公开未签名包，必须用部署者自己的 Team、Bundle ID 与 profiles 重签，不能直接安装或上传 TestFlight。
- TestFlight：独立生产配置的 build 149 已上传成功、Apple 正在处理；不要使用 APNs 配置错误的 TestFlight 148（GitHub unsigned 148 不受影响）。上传成功不等于 Apple 处理完成、外测审核或测试者可更新。

正式 APK 使用既有 AirSIM Release 证书，可覆盖同包名、同签名安装；不要先卸载或清除配对数据。历史版本与旧 Android 10–13 修复包仍保留在 [Releases](https://github.com/kai-wu-cortex/AirSIM/releases)。Debug 包与正式包签名不同，不能直接覆盖。

### 1. 准备开发环境

- Android 测试手机，支持 Android Telecom、Shizuku 和无线调试；Standalone 不要求 Android AVF Linux 环境。
- Android 构建：JDK 17、Android SDK Platform 35 与 Build Tools 35。
- Apple 构建：Xcode；工程最低目标为 iOS 16.3 和 watchOS 10。
- Agent 构建：Go 1.24。
- Relay 部署：Node.js 20 或更新版本、Cloudflare Wrangler，以及部署者自己的 Cloudflare 和 Apple Developer 资源。

### 2. 构建 Android Standalone APK

```sh
./android-standalone/test.sh
./android-standalone/build.sh
```

安装 APK 后，将 AirSIM Standalone 设为默认电话 App，启动 Shizuku 并向 AirSIM 授权。小米 HyperOS 无法显示系统角色选择页时，App 会在 Shizuku 授权后自动设置。完整步骤见 [Android Standalone 文档](android-standalone/README.md)。

### 3. 可选：安装旧 Android AVF Agent

新设备请优先使用上一节的 Standalone APK。只有需要兼容旧部署或回退时，才使用以下 AVF 流程。

首次安装时进入 Android AVF Linux Terminal，确认 Debian 提示符可用后执行（`pipefail` 会让下载失败明确报错）。已有 `0.4.4-1` 的设备不能用首次安装命令升级，应使用下一段的一次性密钥迁移命令：

```sh
bash -o pipefail -c 'curl -fsSL --connect-timeout 10 --max-time 90 --retry 2 --proto =https --proto-redir =https --tlsv1.2 https://github.com/kai-wu-cortex/AirSIM/releases/download/v0.4.7/install-avf.sh | sudo sh'
```

已安装 `0.4.4-1` 的设备必须在同一个 AVF Terminal 中执行一次签名密钥迁移；脚本先核对旧包摘要、验签新包、保留旧包，失败时尝试回滚。**不要在 App 中直接点“更新到最新版”：旧 installer 尚不信任新公钥。**

```sh
curl -fsSL --connect-timeout 10 --max-time 90 --retry 2 --proto =https --proto-redir =https --tlsv1.2 -o /tmp/airsim-rotate-v0.4.5.sh https://github.com/kai-wu-cortex/AirSIM/releases/download/v0.4.5/rotate-avf-key.sh
printf '%s  %s\n' '9ae6b8c69d5d9877638a50240282a67d06b73d807dba444c816c5efb9c5ec04d' /tmp/airsim-rotate-v0.4.5.sh | sha256sum -c - && sudo sh /tmp/airsim-rotate-v0.4.5.sh
```

App 仅复制命令，必须在 Debian Terminal 中粘贴执行。安装器只接受匹配的 `arm64` Debian 包和 Ed25519 签名。**只有 Agent 与 installerd 健康检查均通过才算安装完成。**修复版引导脚本遇到已有 `current.deb` 时优先恢复服务，必要时从保留包重装，不再把“已安装”变成无法修复的死路。随后在 Terminal 运行 `sudo airsim-avf-pair`，把控制 token 保存到 Android App；AVF 地址取当前设备动态分配的来宾私网地址，不能照抄示例网段。后续更新、修复和回滚由独立的 `airsim-installerd` 完成。若 App 显示“尚未配对”或 `8576` 不可用，见 [AVF 安装与无损排障指南](docs/AVF_INSTALL_GUIDE.md)；包细节见 [AVF Debian 发布文档](module/packaging/README.md)。仓库源码的修复须重新签名并发布 GitHub Release，才会进入上述在线安装命令。

如果 `apt` 报 `udev` 与 `libudev1` 版本不一致，先按安装指南模拟系统依赖修复，不要直接运行可能删除系统组件的 `apt --fix-broken install`。修复版引导脚本会在安装 Agent 前拦截已有的 Debian 依赖故障。

同一 AVF 内可以保留 DJOneHub：AirSIM 专用 Agent / installer 端口为 `8575` / `8576`，不占用 DJOneHub 的 `7575`。安装前核对 GitHub Release 已包含这次端口迁移；旧版在线安装包仍会监听 `7575`，**不要在 DJOneHub 并存环境运行旧版命令**。

0.4.5 的修复、密钥迁移和验收步骤见 [Release Markdown](docs/releases/0.4.5.md)。

### 4. 配置并签名 iPhone / Apple Watch App

```sh
open iOS/AirSIM.xcodeproj
```

使用自己的 Apple Developer Team，为主 App、Watch App 和 Live Activity Extension 设置唯一 Bundle ID，并重新生成 provisioning profile。仓库中的 `com.example.airsim` 只是占位符，不能直接用于发布或 APNs。签名、CallKit、PushKit 与 APNs topic 的对应关系见 [iOS / watchOS 文档](iOS/README.md)。

### 5. 可选：部署 Cloudflare Relay

维护者部署信息：

| 项目 | 当前值 |
| --- | --- |
| Worker | `airsim-push-relay` |
| AirSIM 地址 | `https://airsim-push.remotepilot.site` |
| 允许的主 Bundle ID | `com.eric3u.airsim` |
| DJOneHub 地址 | `https://push.remotepilot.site`，保持独立 |
| 必需 Secret | `APNS_P8`、`DASHBOARD_TOKEN`，只保存于 Cloudflare Secret |

截至 2026-10-08，AirSIM 与 DJOneHub 的 `/healthz` 均返回各自服务名，AirSIM Dashboard 已验证匿名 `401`、正确 Bearer token `200`。AirSIM 新环境尚无设备注册，因此真实 PushKit、APNs、Agent 心跳和云端 PCM 仍属于待验收项。

上表不是公共接入承诺。使用自己 Apple Developer Team 和 Bundle ID 重签时，应按下面的流程部署自己的 Relay：

```sh
cd push-relay-worker
npm ci
cp wrangler.example.toml wrangler.toml
npm test
npm run check
npx wrangler deploy --dry-run --config wrangler.toml
```

部署前必须创建自己的 KV、配置 Durable Objects 与自定义域名，并将 `APNS_P8`、`DASHBOARD_TOKEN` 作为 **Worker Secret** 添加，不能写入 Git 或 `[vars]`。完整教程见 [Cloudflare Relay 部署手册](push-relay-worker/README.md)。

## Apple 自有签名要求

AirSIM 不附带原作者的 Apple Developer Team、App ID、证书或 provisioning profile。每位使用者必须：

1. 将主 App 的 `com.example.airsim` 替换为自己控制的唯一 Bundle ID。
2. 将 Watch App 和 Live Activity Extension 分别设置为主 Bundle ID 加 `.watchkitapp` 与 `.liveactivity`。
3. 使用自己的 Apple Developer Team、开发/分发证书与 provisioning profile 重新签名。
4. 在 Relay 中把 `ALLOWED_BUNDLE_ID` 设置为同一个主 App Bundle ID。
5. 分别验证 APNs sandbox 与 production 环境中的 PushKit、通知、Watch 和 Live Activity topic。

只替换签名证书而保留他人的 Bundle ID，不能获得对应 App ID 或 APNs topic 的权限。

## 文档导航

| 文档 | 适用场景 |
| --- | --- |
| [Android Standalone APK](android-standalone/README.md) | 推荐安装、构建、签名、HyperOS 权限、迁移与真机验收 |
| [旧 Android 控制 App](android/phone-control-app/README.md) | AVF 兼容模式、默认电话角色、配对与厂商兼容性 |
| [三星通话音频桥](android/phone-audio-bridge/README.md) | Shizuku 音频桥构建、运行和 PCM 边界 |
| [Android AVF Agent](module/module-agent/README.md) | Agent 配置、API、安全与启动探针 |
| [AVF Debian 发布](module/packaging/README.md) | `.deb` 构建、签名、首次安装、升级与回滚 |
| [AVF 安装与无损排障](docs/AVF_INSTALL_GUIDE.md) | Terminal、控制令牌、双服务健康检查与启动冲突恢复 |
| [iOS 与 watchOS](iOS/README.md) | Xcode、Bundle ID、Apple 签名、CallKit、PushKit 与真机测试 |
| [Cloudflare Relay](push-relay-worker/README.md) | Wrangler、KV、Durable Objects、APNs、Secret 与自定义域名 |
| [VoWLAN 设计](docs/2026-09-11-vowlan-design.md) | 本地传输设计与协议边界 |
| [VoBLE 真机测试矩阵](docs/voble-real-device-test-matrix.md) | 蓝牙模式配置、自动化结果、设备矩阵与尚未完成的硬件验收 |
| [Shizuku 13.6.0 PCM 回归](docs/shizuku-13.6.0-pcm-regression.md) | HyperOS 3 上升级 Shizuku 后 PCM 反复启动即退出；13.5.4 临时恢复 |
| [三星热点配对协议](docs/samsung-hotspot-pairing-protocol.md) | 配对、密钥派生、HMAC 与防重放 |
| [Codex 部署辅助](codex.md) | 面向 Codex 的全项目构建、验证与部署规则 |
| [Claude 部署辅助](claude.md) | 面向 Claude 的全项目操作顺序与安全约束 |
| [通用 LLM 上下文](LLM.txt) | 供其他 AI 工具读取的机器友好项目契约 |

## 全项目验证

```sh
./android-standalone/test.sh
./android/phone-control-app/test.sh
./android/phone-audio-bridge/build.sh
./android/phone-control-app/build.sh
(cd module/module-agent && go test ./...)
(cd module/avf-installerd && go test ./...)
./module/packaging/test.sh
(cd push-relay-worker && npm test && npm run check)
xcodebuild -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

自动化验证不能代替 Android、iPhone、Apple Watch、AVF Linux、APNs sandbox/production 和公网 Relay 的真实链路验收。

## 安全与隐私

- AVF Agent、安装服务和 PCM 端口只能监听设备内部私网或 loopback。
- VoWLAN 控制请求必须验证时间戳、nonce 与 HMAC，配对密钥保存在平台安全存储中。
- 设备 Secret、Agent token、APNs `.p8`、`DASHBOARD_TOKEN`、签名私钥、真实号码和生产配置不得提交到仓库。
- 通话 PCM 只在内存和网络中处理，不落盘；日志不得包含 PCM、完整短信、Push token 或认证材料。
- 紧急呼叫必须交回系统电话能力；AirSIM 不能作为紧急通信保障。
- Android App 无法绕过 OEM 固件或系统签名限制，强制开启被隐藏或移除的 AVF Linux 功能。

## 项目状态

AirSIM 当前处于主动开发阶段。仓库已整合 Android Standalone、旧 AVF Agent / Installer、iOS / watchOS 与 Cloudflare Relay 源码，并提供本地自动化验证。发布编号为 Android `0.9.8.19 (124)` 与 iOS `0.9.8 (148)`；其基础提交曾以旧编号覆盖安装并启动，但新编号发布包仍待完整真机验收。纯本地跨端协商、零 Relay 流量、云端接听、短信、锁屏与重启恢复仍需联合验证；不同 OEM、后台推送与长期稳定性不能仅凭构建通过确认。

## 项目趋势

[![AirSIM Star History Chart](https://api.star-history.com/svg?repos=kai-wu-cortex/AirSIM&type=Date)](https://www.star-history.com/#kai-wu-cortex/AirSIM&Date)

## 许可证

AirSIM 采用 [PolyForm Noncommercial License 1.0.0](LICENSE)：

- 允许个人学习、研究、实验、测试、业余项目，以及许可证列明的其他非商业用途。
- 允许在非商业目的下查看、修改和再分发，但必须随附许可证与 [Required Notice](NOTICE)。
- **不允许任何商业用途或预期商业应用**；商业授权需另行取得版权所有者的书面许可。
- 该许可证包含贡献者可授权范围内的专利许可，但不提供任何担保。
- 第三方组件继续适用其自身许可证，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

禁止商业用途意味着本项目不符合 OSI 的 Open Source Definition。请使用“源码可见”或 “source-available”描述 AirSIM，而不要将其标注为 OSI 开源软件。
