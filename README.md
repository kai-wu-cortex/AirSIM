# AirSIM — 三星 Android 与 iPhone / Apple Watch 跨设备通话、短信和 VoWLAN

[![Samsung Android](https://img.shields.io/badge/Samsung%20Android-Phone%20Bridge-3DDC84?logo=android&logoColor=white)](android/phone-control-app/README.md)
[![iOS](https://img.shields.io/badge/iOS-16.3%2B-000000?logo=apple&logoColor=white)](iOS/README.md)
[![watchOS](https://img.shields.io/badge/watchOS-10%2B-000000?logo=apple&logoColor=white)](iOS/README.md)
[![Android AVF](https://img.shields.io/badge/Android%20AVF-Linux%20arm64-FCC624?logo=linux&logoColor=black)](module/packaging/README.md)
[![Cloudflare Workers](https://img.shields.io/badge/Relay-Cloudflare%20Workers-F38020?logo=cloudflare&logoColor=white)](push-relay-worker/README.md)
[![Project status](https://img.shields.io/badge/status-active%20development-1f6feb)](#项目状态)

**AirSIM 是一个以三星 Android 手机为蜂窝通信终端，让 iPhone 和 Apple Watch 远程拨打、接听电话与收发短信的开源跨设备通信项目。** 三星端负责 Android Telecom、短信和系统通话音频；Android AVF Linux Agent 负责设备状态与命令编排；Apple 客户端使用 CallKit、PushKit、ActivityKit 和 VoWLAN；可选的 Cloudflare Workers Relay 提供公网事件、APNs 推送、命令队列与媒体中继。

AirSIM is an open-source cross-device calling and messaging project that connects Samsung Android, iPhone, Apple Watch, Android AVF Linux, CallKit, PushKit, VoWLAN, APNs, and Cloudflare Workers.

> 本仓库包含完整源码、构建脚本与部署文档，不提供可复用的 Apple Developer 身份、生产 APNs 密钥、Cloudflare 账户资源或托管 Relay。项目仍处于主动开发阶段，不能替代紧急呼叫能力，生产使用前必须完成目标三星手机、iPhone 和 Apple Watch 的联合验收。

**Tags / Topics:** `Samsung Android` · `iPhone` · `Apple Watch` · `CallKit` · `PushKit` · `VoWLAN` · `Android AVF` · `Cloudflare Workers` · `APNs` · `SwiftUI` · `Go`

## 核心能力

- **跨设备电话**：在 iPhone 或 Apple Watch 上拨号、接听、拒接、挂断、静音并发送 DTMF，由三星 Android 手机完成运营商通话。
- **跨设备短信**：同步短信状态、发送短信并通过 APNs 通知 Apple 客户端。
- **CallKit 与 PushKit**：在 iPhone 上呈现系统来电界面，并支持 VoIP push 唤醒与来电上报。
- **VoWLAN 本地直连**：iPhone 与三星手机处于同一局域网或三星热点时，使用经过 HMAC 认证的控制与 PCM 链路。
- **云端 Relay**：通过独立部署的 Cloudflare Worker、KV 与 Durable Objects 连接 Android AVF Agent 和 Apple 客户端。
- **AVF 一键安装与救援**：首次在 Android AVF Linux Terminal 执行单行命令；后续由 Android App 管理签名 Debian 包的更新、修复和回滚。
- **三星通话音频桥**：通过 Shizuku `UserService` 在内存中转发双向 PCM，不保存通话音频。

## 系统架构

局域网模式优先使用 VoWLAN：

```text
iPhone / Apple Watch
        │  VoWLAN 控制、通话状态与 PCM
        ▼
三星 Android AirSIM App ── Android Telecom / 短信 / Shizuku 音频桥
        │  AVF 私网
        ▼
Android AVF Linux Agent
```

远程模式通过部署者自己的 Relay：

```text
iPhone / Apple Watch ⇄ Cloudflare Relay ⇄ Android AVF Agent ⇄ 三星 Android
```

每通电话在建立时选择 VoWLAN 或 Relay，并在本次通话结束前保持同一传输路径，避免媒体和控制面在通话中途漂移。

## 仓库结构

| 目录 | 组件 | 主要职责 |
| --- | --- | --- |
| [`android/phone-control-app`](android/phone-control-app/README.md) | 三星 Android 控制 App | 默认电话角色、Android Telecom、配对、短信、VoWLAN 与守护服务 |
| [`android/phone-audio-bridge`](android/phone-audio-bridge/README.md) | 三星通话音频桥 | 通过 Shizuku 提供双向 PCM，并限制在 AVF 私网接口 |
| [`module/module-agent`](module/module-agent/README.md) | Android AVF Agent | 控制 API、设备状态、Relay 心跳、命令与媒体编排 |
| [`module/avf-installerd`](module/avf-installerd) | AVF 救援安装服务 | 校验签名 Debian 包、健康检查与失败回滚 |
| [`module/packaging`](module/packaging/README.md) | AVF Debian 发布 | 构建单一 `arm64` 包、systemd 单元和首次安装脚本 |
| [`iOS`](iOS/README.md) | iPhone / Apple Watch App | CallKit、PushKit、VoWLAN、短信、实时活动与通话媒体 |
| [`push-relay-worker`](push-relay-worker/README.md) | Cloudflare Relay | 设备注册、APNs、云端命令、Dashboard 与公网媒体 |
| [`docs`](docs) | 协议与设计文档 | VoWLAN 设计、三星热点配对协议与安全边界 |

## 快速开始

### 1. 准备开发环境

- 三星 Android 测试手机，支持 Android Telecom、Shizuku、无线调试和可用的 Android AVF Linux 环境。
- Android 构建：JDK 17、Android SDK Platform 35 与 Build Tools 35。
- Apple 构建：Xcode；工程最低目标为 iOS 16.3 和 watchOS 10。
- Agent 构建：Go 1.24。
- Relay 部署：Node.js 20 或更新版本、Cloudflare Wrangler，以及部署者自己的 Cloudflare 和 Apple Developer 资源。

### 2. 构建三星 Android App

```sh
./android/phone-control-app/test.sh
./android/phone-audio-bridge/build.sh
./android/phone-control-app/build.sh
sh ./android/phone-control-app/verify-apk.sh
```

安装 APK 后，将 AirSIM 设为默认电话 App，启动 Shizuku 并向 AirSIM 授权。完整步骤见[三星 Android 控制 App 文档](android/phone-control-app/README.md)。

### 3. 首次安装 Android AVF Agent

进入 Android AVF Linux Terminal，执行：

```sh
curl -fsSL --proto '=https' --tlsv1.2 \
  https://github.com/kai-wu-cortex/AirSIM/releases/latest/download/install-avf.sh \
  | sudo sh
```

安装器只接受匹配的 `arm64` Debian 包和 Ed25519 签名。完成后，将显示的 AVF 地址与控制 token 保存到三星 Android App。后续更新、修复和回滚由独立的 `airsim-installerd` 完成；详见 [AVF Debian 发布文档](module/packaging/README.md)。

### 4. 配置并签名 iPhone / Apple Watch App

```sh
open iOS/AirSIM.xcodeproj
```

使用自己的 Apple Developer Team，为主 App、Watch App 和 Live Activity Extension 设置唯一 Bundle ID，并重新生成 provisioning profile。仓库中的 `com.example.airsim` 只是占位符，不能直接用于发布或 APNs。签名、CallKit、PushKit 与 APNs topic 的对应关系见 [iOS / watchOS 文档](iOS/README.md)。

### 5. 可选：部署 Cloudflare Relay

```sh
cd push-relay-worker
npm ci
cp wrangler.example.toml wrangler.toml
npm test
npm run check
npx wrangler deploy --dry-run --config wrangler.toml
```

部署前必须创建自己的 KV、配置 Durable Objects 与自定义域名，并将 `APNS_P8`、`DASHBOARD_TOKEN` 作为 **Worker Secret** 添加，不能写入 Git 或 `[vars]`。完整教程见 [Cloudflare Relay 部署手册](push-relay-worker/README.md)。

## Apple 开源签名要求

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
| [三星 Android 控制 App](android/phone-control-app/README.md) | 安装、默认电话角色、AVF 引导、配对与厂商兼容性 |
| [三星通话音频桥](android/phone-audio-bridge/README.md) | Shizuku 音频桥构建、运行和 PCM 边界 |
| [Android AVF Agent](module/module-agent/README.md) | Agent 配置、API、安全与启动探针 |
| [AVF Debian 发布](module/packaging/README.md) | `.deb` 构建、签名、首次安装、升级与回滚 |
| [iOS 与 watchOS](iOS/README.md) | Xcode、Bundle ID、Apple 签名、CallKit、PushKit 与真机测试 |
| [Cloudflare Relay](push-relay-worker/README.md) | Wrangler、KV、Durable Objects、APNs、Secret 与自定义域名 |
| [VoWLAN 设计](docs/2026-09-11-vowlan-design.md) | 本地传输设计与协议边界 |
| [三星热点配对协议](docs/samsung-hotspot-pairing-protocol.md) | 配对、密钥派生、HMAC 与防重放 |
| [Codex 部署辅助](codex.md) | 面向 Codex 的全项目构建、验证与部署规则 |
| [Claude 部署辅助](claude.md) | 面向 Claude 的全项目操作顺序与安全约束 |
| [通用 LLM 上下文](LLM.txt) | 供其他 AI 工具读取的机器友好项目契约 |

## 全项目验证

```sh
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

自动化验证不能代替三星 Android、iPhone、Apple Watch、AVF Linux、APNs sandbox/production 和公网 Relay 的真实链路验收。

## 安全与隐私

- AVF Agent、安装服务和 PCM 端口只能监听设备内部私网或 loopback。
- VoWLAN 控制请求必须验证时间戳、nonce 与 HMAC，配对密钥保存在平台安全存储中。
- 设备 Secret、Agent token、APNs `.p8`、`DASHBOARD_TOKEN`、签名私钥、真实号码和生产配置不得提交到仓库。
- 通话 PCM 只在内存和网络中处理，不落盘；日志不得包含 PCM、完整短信、Push token 或认证材料。
- 紧急呼叫必须交回系统电话能力；AirSIM 不能作为紧急通信保障。
- Android App 无法绕过 OEM 固件或系统签名限制，强制开启被隐藏或移除的 AVF Linux 功能。

## 项目状态

AirSIM 当前处于主动开发阶段。仓库已整合 Android、AVF Agent / Installer、iOS / watchOS 与 Cloudflare Relay 源码，并提供本地自动化验证；生产 Relay、Apple 正式签名、目标三星机型兼容性、真实双向通话、后台推送与长期稳定性仍需由部署者在自己的环境中验收。

## 许可证

仓库当前尚未包含 `LICENSE` 文件。维护者在对外发布或接受第三方分发前，应明确选择并提交开源许可证；在此之前，请勿仅凭“源代码可见”推断获得了复制、修改或再分发授权。
