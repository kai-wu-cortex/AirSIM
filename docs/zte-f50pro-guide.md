# 中兴 F50 Pro (MU3356) 及无屏随身 Wi-Fi 适配与使用指南

本文档介绍如何在不刷机、不修改系统分区的前提下，将 **AirSIM Standalone** 部署到 **中兴 F50 Pro（`MU3356`，Android 15 SDK 35）** 等无屏 5G 随身 Wi-Fi 设备上，实现 iPhone 跨设备拨打/接听电话（VoLTE/VoNR）与收发短信。

---

## 1. 适配背景与技术原理

无屏随身 Wi-Fi 出厂固件通常针对纯数据热点场景进行了裁剪，直接安装标准电话应用会遇到以下限制，AirSIM 已内置完整适配：

1. **无语音能力标志（`config_voice_capable=false`）导致来电被拦截**：
   - 在 F50 Pro 的 `framework-res.apk` 中，`config_voice_capable` 为 `false`（`TelephonyManager.isVoiceCapable() == false`）。
   - 当外部电话呼入时，底层 `ImsPhoneCallTracker.onIncomingCall` 已创建 `ImsPhoneConnection` 并挂载至 `ImsPhone.mRingingCall`（主叫方听到回铃音），但 `Phone.notifyNewRingingConnectionP` 因 `!mIsVoiceCapable` 提前返回，导致 `TeleService` 的 `PstnIncomingCallNotifier` 从未调用 `TelecomManager.addNewIncomingCall`。
   - **AirSIM 解决方案**：通过 `HeadlessIncomingCallBridge` 与 `AirSIMCallManagerService`，利用 `UID 2000`（持有 `MODIFY_PHONE_STATE`）注册 `PhoneAccount.CAPABILITY_CONNECTION_MANAGER`（`SimCallManager`）。当 `PhoneStateListener` 捕获到 `TelephonyRegistry` 广播的 `CALL_STATE_RINGING` 时，立即以 PSTN `PhoneAccountHandle` 调用 `TelecomManager.addNewIncomingCall`；随后在 `AirSIMCallManagerService` 中返回 `DisconnectCause.CONNECTION_MANAGER_NOT_SUPPORTED`（`10`），触发 `Telecom` 自动回退至系统原生 `TelephonyConnectionService.onCreateIncomingConnection`，直接接管 `ImsPhone.getRingingCall()` 中的振铃连接。
2. **缺失 `ROLE_DIALER` 角色定义**：
   - 随身 Wi-Fi 的 `RoleManager` 不包含 `android.app.role.DIALER`，AirSIM 自动回退检查 `TelecomManager.getDefaultDialerPackage()`，支持通过 `cmd telecom set-default-dialer` 绑定 `InCallService`。
3. **`br0` 网桥热点接口识别**：
   - 随身 Wi-Fi 将无线热点与 USB RNDIS 桥接在 `br0`（如 `192.168.0.1/24`）上，`VoWLANNetworkPolicy` 与 `PairingServer` 已原生支持 `br*` 接口。
4. **免 Root（ADB Shell `UID 2000`）音频桥常驻守护进程**：
   - 出厂固件无 `su`，AirSIM 的 `RootBridgeMain` 支持以 `setsid app_process` 方式在 `127.0.0.1:27580` 启动带随机 Token 鉴权的 `UID 2000` 守护进程，提供 `TYPE_TELEPHONY` 上下行双向 PCM 音频流。

---

## 2. 一键编译与安装步骤

### 第一步：开启 F50 Pro 网络 ADB
1. 将电脑或手机连接到 F50 Pro 的 Wi-Fi 热点（默认网关 `192.168.0.1`）。
2. 在中兴管理后台开启 USB / 网络 ADB 调试（端口 `5555`）。

### 第二步：执行一键部署脚本
在仓库根目录运行 [`install-f50pro.sh`](../install-f50pro.sh)：

```bash
./install-f50pro.sh 192.168.0.1:5555
```

该脚本会自动完成以下操作：
1. 检查并准备 Android SDK 35 构建环境。
2. 编译 `airsim-phone-audio-bridge.jar` 与 `AirSIM-Android-Standalone-debug.apk`。
3. 通过 ADB 安装 APK 并授予运行时权限，将其设为 `Telecom` 默认电话应用。
4. 启动 `airsim-root-bridge` 特权音频守护进程（`127.0.0.1:27580`）。
5. 触发后台一次性配对会话，并在终端输出 **6 位配对码**与**配对端口**。

> 如需在安装后随时重新生成配对码，可执行：
> ```bash
> adb connect 192.168.0.1:5555
> adb -s 192.168.0.1:5555 shell "run-as com.airsim.phonecontrol.standalone touch files/request-pairing.flag && sleep 6 && cat files/pairing-session.txt"
> ```

---

## 3. iPhone 连接与网络方案

配对只需完成一次，日常可根据使用场景选择以下连接方式：

### 方式 A：连接 F50 Pro 随身热点
- iPhone 直接连接 F50 Pro 的 Wi-Fi 热点，在 AirSIM 中自动发现或手动填入 `192.168.0.1` 与配对端口完成配对。

### 方式 B：在家连接宽带 Wi-Fi（Tailscale 异地/跨网组网，推荐）
如果 iPhone 在家需要连接家庭宽带 Wi-Fi，或者出门在外使用蜂窝流量远程连接放在家里/包里的 F50 Pro：
1. 通过 ADB 在 F50 Pro 上安装 Tailscale APK 并登录账号（F50 Pro 使用自身 SIM 卡流量保持在线）。
2. 在 iPhone 上安装 Tailscale 并登录同一账号。
3. 在 iPhone 端 AirSIM 选择 **手动地址配对（私网 IP）**，填入 F50 Pro 的 Tailscale IPv4（`100.x.y.z`）、配对端口及 6 位配对码即可。

### 方式 C：让 F50 Pro 接入家庭路由器 Wi-Fi
- 通过中兴后台的「Wi-Fi 扩展 / 无线中继」或 `adb shell cmd wifi connect-network "<SSID>" wpa2 "<密码>"` 让 F50 Pro 接入家庭路由器，iPhone 与 F50 Pro 处于同一家庭局域网即可直接通信。

---

## 4. iPhone 锁屏秒收来电设置

iOS 系统默认会在锁屏约 25 秒后挂起后台 App 的长连接。为确保锁屏状态下外部来电能立即弹出 CallKit：

- **纯本地 / Tailscale 模式（未配置云端 APNs Relay）**：
  请打开 iPhone 端 **AirSIM -> 设置 -> 通知 -> 后台保活**，开启 **「后台静音音频保活」**。开启后 AirSIM 在后台维持零音量静音播放，防止 iOS 挂起 `/api/calls/events` 来电轮询。
- **云端通知模式（已配置 Cloudflare Relay + Apple PushKit）**：
  在 **AirSIM -> 设置 -> 通知** 中开启 **「云端通知」**，并在配对时取消勾选「仅本次配对不写入云端」，即可通过 Apple PushKit VoIP 推送在锁屏时唤醒 CallKit。
