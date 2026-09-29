# AirSIM 三星 Android 控制 App

该 App 运行在三星 Android 手机上，是 AirSIM 的蜂窝通话与短信控制入口。Android Telecom 负责运营商通话状态和操作，App 负责将状态同步给 Android AVF Agent，并为 iPhone 与 Apple Watch 提供经过认证的 VoWLAN 服务。

## 主要职责

- 申请并维护默认电话 App 角色。
- 监听来电、拨出、接通、挂断和 DTMF 状态。
- 将通话与短信事件发送给 AVF Agent。
- 执行 Agent 下发的拨号、接听、拒接、挂断和短信命令。
- 提供限时配对窗口与六位确认码。
- 在三星热点接口上发布经过认证的 VoWLAN 控制与 PCM 服务。
- 维护前台守护服务、Shizuku 状态和故障诊断。

## 运行要求

- 三星 Android 测试手机，目标 SDK 35。
- 用户将 AirSIM 设置为默认电话 App。
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

## 三星手机配置

1. 安装 APK 并启动 AirSIM。
2. 在系统设置中选择 AirSIM 作为默认电话 App。
3. 启动 Shizuku，并在 AirSIM 的 Shizuku 区域完成授权。
4. 配置 AVF Agent 地址与 bearer token。
5. 确认 Agent、音频桥和 VoWLAN 状态均为就绪。
6. 打开两分钟配对窗口，让 iPhone 输入三星端显示的六位配对码。

## 通话与音频策略

普通来电默认使用 `remote_silent`：三星端保持受控静音，由 iPhone 或 Apple Watch 呈现来电并承载音频。紧急通话始终交回系统预装电话 App。Shizuku 服务以 shell UID 运行音频桥，并在通话结束时恢复先前的系统音量状态。

## 网络与安全

- Agent 配置仅接受 AVF 私网 `10.185.5.0/24` 内的地址。
- bearer token 只保存在 Android 私有偏好设置中，不写入日志。
- VoWLAN 仅绑定有效的三星热点地址，不监听通用网络接口。
- 所有控制请求均执行路由白名单、消息大小、时间戳、随机数与 HMAC 校验。
- 原始 PCM、配对明文和认证材料不得进入诊断日志。
