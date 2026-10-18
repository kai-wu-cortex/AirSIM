# 远程通话接管后的安卓本机静音（候选 build 86）

Android Standalone／Bridge 候选版本 `0.9.7.1 (86)`。本次没有更改 iOS、Relay 协议、配对凭据或 PCM 编解码。不安装、不发布、不提交代码；真机通话验收需另行进行。

## 触发条件

只有以下条件同时成立，才向已授权 Shizuku 请求本机通话输出静音：

- 当前只有一通未结束的原生 Telecom 通话。
- 已认证的远程控制确认了这通 Android call ID，且所属 PCM 会话已就绪。
- 状态为拨号、已接通或保持；准备来电媒体并不代表已经接听。

VoWLAN 通过 DirectCallOwnership 的控制／媒体租约确认，VoBLE 使用当前已确认 Android call ID 和媒体会话，Standalone 云端通过会话中的 androidID 绑定。蓝牙仅配对、HTTP 成功或云端在线都不是静音依据。旧 AVF 云端没有精确媒体身份时不自动静音；`remote_silent` 仍控制通知呈现，但不再单独授权静音所有电话。

## 静音与恢复

复用 Shizuku shell/root 身份的 `AudioManager.STREAM_VOICE_CALL` 输出控制，保存初始静音标志和音量，操作后回读。不调用麦克风静音、不修改 PCM／AudioTrack 增益，不关闭系统音频服务或自动挂断电话。

媒体释放、通话结束、原生状态进入 DISCONNECTING、出现另一通未结束电话或 InCallService 销毁时恢复初始状态。原本已静音的手机保持其初始静音状态；不会强制把用户之前的静音取消。服务销毁后排队的旧策略刷新不能重新静音。

VoBLE 音频泵遇到 EOF／异常时，即使 GATT 控制仍在线，也只释放发生故障的媒体所有者。清理在控制队列执行并校验对象身份，旧会话延迟回调不能停止新会话。启动时同步检查 PCM 状态与注册所有权，避免刚断开的会话被重新注册为就绪。

网关退出与媒体发布共用生命周期锁，退出先标记销毁再释放当前媒体。退出之后才完成的 TCP 握手会关闭，不能再次登记媒体；排队的通话状态事件也必须在媒体锁下确认 `ready()`，不能复活已失败 PCM 的所有权。

## 诊断

复用“Debug 诊断 → 保存音频 Watchdog TXT”。静音和恢复的完成结果均写入本机轮换 VERBOSE 日志，即使普通 Debug 已关闭。授权未就绪的排队意图、厂商接口拒绝或回读失败不算静音成功。现有有限次 Watchdog 复检和恢复重试仍保留。

`acoustic_check=unavailable` 表示日志只能证明系统静音状态，不能证明物理听筒／扬声器无声。不能以构建、JVM 测试或 OS 标志替代实际双向语音验收。

## 验证

新增 `RemoteCallMuteLifecycleTests` 运行真实 InCallService、媒体身份注册和静音控制器，仅替换 Android OS／Binder／事件上报边界。覆盖普通电话不静音、两种通知模式下三条媒体链路的接管和断开恢复、未接听来电、第二通电话、DISCONNECTING、服务销毁、排队旧回调，以及真实 TCP 握手后 EOF 的蓝牙恢复。原有静音失败、原音量恢复、厂商调用超时、PCM 双向编解码和队列测试继续运行。

`VoBLEGatewayMuteLifecycleTests` 直接运行生产网关的媒体启动／状态发布／退出方法，替换 Android Service 外壳，使用真实 TCP 握手，分别复现并覆盖“退出后握手完成”和“失败后排队状态重新绑定”。只读审查指出的这两项 Important 风险均据此修复；声学、OEM 路由和旧版 Watchdog 的完整实现仍不以本轮审查代替真机验证。

真机需要分别检查三种链路的拨出／接听、安卓本机无通话播放、iPhone 双向声音仍正常、挂断／断开恢复，以及新的一通普通安卓电话可正常使用。不得自动拨打真实号码代替用户操作。

本轮本地验证：`sh android-standalone/test.sh` 完整通过，其中新增 13 组通话生命周期场景和 2 组真实网关并发场景；Android 29–35 短信兼容、旧 API 检查、PCM 桥及其他原有测试通过。Standalone 与 AVF Bridge 的 debug APK 均完成构建和签名校验，Manifest 版本为 `0.9.7.1 (86)`、最低 API 29。构建仍有已有 Android API 弃用和工具链提示，没有构建错误。

产物：

- Standalone：`android-standalone/build/android/AirSIM-Android-Standalone-debug.apk`；SHA-256 `d1462571794e50b0d1df368786aee5a4375ce73eb506d7d7536922fc82e07f6d`。
- AVF Bridge：`android/phone-control-app/build/android/AirSIM-Phone-Bridge-debug.apk`；SHA-256 `03f58a535a5fe9d664040bb9f326c4dfe9cac75f033712a0781c9e8e46c4fd13`。

测试记录：`/tmp/airsim-remote-mute-86-final-tests.log`、`/tmp/airsim-remote-mute-86-bridge-build.log`。未覆盖安装、未执行真实电话或短信、未再次部署生产 Relay。
