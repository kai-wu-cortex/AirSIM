# AirSIM 三星通话音频桥

该组件运行在三星 Android 的 Shizuku `UserService` 中，以 shell UID 访问系统通话音频，并向 AirSIM 控制 App 与 AVF Agent 提供双向 PCM。

## 音频方向

- 下行：`AudioRecord.VOICE_DOWNLINK` → Agent / Relay → iPhone 或 Apple Watch
- 上行：iPhone 或 Apple Watch 麦克风 → Agent / Relay → `USAGE_VOICE_COMMUNICATION` 与三星 `VOICE_TX`
- 格式：8 kHz、单声道、PCM16LE、每帧 320 字节
- 握手：`AIRSIMPCM1\n` / `AIRSIMREADY`

音频桥不保存 PCM。JSONL 日志仅包含生命周期、路由、帧数、字节数、峰值与错误信息。

## 构建与测试

```sh
./android/phone-audio-bridge/build.sh
```

构建会同时运行 JVM 单元测试，并输出：

```text
android/phone-audio-bridge/build/airsim-phone-audio-bridge.jar
```

## 三星设备运行

音频桥必须绑定 Android AVF 私网接口。每次 AVF 启动后先解析当前地址：

```sh
adb -s DEVICE shell 'ip -o -4 addr show avf_tap_fixed'
ssh -p 2222 droid@127.0.0.1 'ip route'
```

启动和检查：

```sh
ADB=/path/to/adb ADB_SERIAL=DEVICE LISTEN_HOST=AVF_ANDROID_IP \
  ./android/phone-audio-bridge/run-device-bridge.sh start
ADB=/path/to/adb ADB_SERIAL=DEVICE \
  ./android/phone-audio-bridge/run-device-bridge.sh status
ADB=/path/to/adb ADB_SERIAL=DEVICE \
  ./android/phone-audio-bridge/run-device-bridge.sh logs
```

Runner 会拒绝通配地址、外部 Wi-Fi、热点、蜂窝和其他非 AVF 私网接口。

## Agent 配置

systemd 环境示例：

```ini
[Service]
Environment=AIRSIM_VOICE_BACKEND=samsung_android
Environment=AIRSIM_SAMSUNG_PCM_ADDRESS=AVF_ANDROID_IP:7580
```

启动前可执行握手探针：

```sh
AIRSIM_RUNTIME_PROFILE=android-avf \
AIRSIM_VOICE_BACKEND=samsung_android \
AIRSIM_SAMSUNG_PCM_ADDRESS=AVF_ANDROID_IP:7580 \
/usr/local/bin/airsim-agent --startup-probe voice-backend
```

## 运行边界

- 仅允许一个已认证客户端占用当前通话的 PCM 会话。
- 通话结束、热点变化或任一方向断开时立即关闭双向流。
- Android 可能回收 shell 进程；控制 App 的 Shizuku 管理器负责检测并重启服务。
- 真实双向语音必须与 Android Telecom 控制面、AVF Agent 和 iOS/watchOS 客户端联合验证。
