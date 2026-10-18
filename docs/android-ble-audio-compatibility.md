# Android 配对与音频兼容修复（候选 build 87）

## 范围与证据

2026-10-16（Asia/Shanghai）反馈涉及多种问题，不能归为同一机型故障：

- vivo Y53s 截图：`XDH KeyPairGenerator not available`。旧实现依赖系统 XDH；Android 官方从 API 33 才列出支持。移除桌面 JVM 的 XDH Provider 后，真实配对代码复现同款异常。
- 一加 12 截图：发现设备后提示蓝牙特征不完整。代码确认 Android 在异步服务注册完成前广播；iOS 缺少服务失效恢复。但截图本身不能证明具体少了哪个特征。
- 用户反馈的小米 15 Pro／HyperOS 4／Android 17，一加 12／ColorOS 16／Android 16，一加 13／Android 16，及三星 Fold8，与 iPhone 15 Pro Max／17 Pro Max 的无声或双端出声：仍需对应机型日志与真实双向通话确认，不标为已实机适配通过。

## 参考开源实现

1. [Bouncy Castle X25519（固定 1.84）](https://github.com/bcgit/bc-java/blob/r1rv84/core/src/main/java/org/bouncycastle/crypto/params/X25519PrivateKeyParameters.java)：采用打包的 lightweight X25519，不注册或替换系统 Provider。继续使用现有 32 字节原始密钥、HKDF、SAS 与 AES-GCM 格式，保留旧配对。拒绝全零共享秘密。
2. [Google VR180 GATT server](https://github.com/google/vr180/blob/master/java/com/google/vr180/communication/bluetooth/gatt/BluetoothGattServerHelper.java)：参考以 `onServiceAdded` 作为异步操作完成边界；不是将其他示例原样复制进项目。
3. [scrcpy AudioDirectCapture](https://github.com/Genymobile/scrcpy/blob/master/server/src/main/java/com/genymobile/scrcpy/audio/AudioDirectCapture.java)、[音频来源](https://github.com/Genymobile/scrcpy/blob/master/server/src/main/java/com/genymobile/scrcpy/audio/AudioSource.java)：参考采集初始化检查、来源区分和失败处理。普通播放采集不等同于双向蜂窝音频注入；没有照搬麦克风／REMOTE_SUBMIX 回退，也没有将 scrcpy 的设备兼容性当作 AirSIM 适配结论。
4. [Android 服务注册说明](https://developer.android.com/reference/android/bluetooth/BluetoothGattServer#addService(android.bluetooth.BluetoothGattService))、[Apple 服务失效回调](https://developer.apple.com/documentation/corebluetooth/cbperipheraldelegate/peripheral(_:didmodifyservices:))、[Android XDH 支持版本](https://developer.android.com/reference/java/security/KeyPairGenerator)。

## 行为变化

- Android 仅在 GATT 服务注册成功后广播；注册／广播失败可清理后重试。服务代次隔离关闭实例的晚回调。自动测试运行真实 GATT 服务类，框架替身只代替蓝牙硬件边界。
- iOS 在服务失效时丢弃旧特征、旧认证状态和订阅，重新发现并认证；检查必需特征的 UUID 与读写／通知能力。发现不完整最多重试两次，最终显示缺少的具体通道，不忽略认证要求。订阅错误先核对特征对象身份，旧错误不能污染新连接。
- PCM READY 保持原报文，但延后至 AudioRecord／AudioTrack 初始化并启动成功。初始化失败不发 READY。上行厂商标签不再自动算作实际路由已验证，无法观测隐藏厂商路由时明确记为 unverified，不强拆可能仍工作的下行。
- 每通电话重置 PCM 音频统计，避免继承上一通非零峰值。区分 `not_observed`、`all_zero`、`observed`；后者只代表收到过非零采样，不能证明语音清晰或物理听筒静音。
- PCM 固定字段摘要经 Shizuku 状态查询／通话 Watchdog 进入现有有界 VERBOSE TXT。白名单仅保留事件、初始化、采样字节数／峰值和路由验证状态；不包含音频、号码、密钥或任意异常文本。普通 Debug 关闭时仍保留诊断；不新增 Relay 查询。
- iOS 本地音频展示同时要求引擎与 PCM transport 就绪，失败时展示已有音频错误，而不提前宣称链路已连接。

## 验收边界

没有新增跨机型通用的 HAL 注入能力，也没有承诺单凭 Shizuku 即可绕过所有系统音频限制。Watchdog 仍只检查系统静音标志，`acoustic_check=unavailable` 保持不变。不因纯零 PCM（可能是正常静音）自动挂断，不因未验证路由改录麦克风，不全局静音无关通话。

请在每台受影响设备上记录 App 构建号、系统版本、VoWLAN／VoBLE／云端模式，并做一次接通约 10 秒的双向通话，导出安卓状态页的 VERBOSE TXT。对照 `pcm_initialized`、`pcm_capture`、`pcm_route`、上下行字节／峰值、静音请求／恢复记录，再决定是否需要该机型专用路由修复。不需要提交电话号码或语音内容。

依赖固定为 bcprov-jdk15to18 1.84，下载 SHA-256 校验固定在 `crypto-dependency.sh`；许可随 APK raw 资源分发，支持打包全部 dex。真机安装、生产部署、提交推送与公开发布不属于本次代码修复的自动执行范围。

## 本次验证（2026-10-16）

- iOS 模拟器完整测试：148 项通过，0 失败、0 跳过，包括服务失效后重新认证、同 UUID 的旧订阅错误隔离。早期模拟器测试服务异常后重试成功，以最终结果为准。
- `sh android-standalone/test.sh` 完整通过：包括无系统 XDH 的真实配对代码、GATT 异步生命周期、PCM 证据与隐私、Watchdog、静音生命周期，以及原生 PCM 的 55 项检查。
- Standalone Debug APK：0.9.7.1（87），最低 API 29，签名验证通过，包含 X25519 依赖和许可。它是测试候选包，不是已公开发布的正式版。
- iOS 签名 Release 构建：0.9.7（87），深度签名检查通过；本机开发签名／sandbox 推送配置，不代表 TestFlight 已上传。
- `git diff --check` 通过。没有接入受影响安卓机型，未执行这些机型的真实拨号、声学静音或双向音质验收。
