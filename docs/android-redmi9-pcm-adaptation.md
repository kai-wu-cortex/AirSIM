# Redmi 9 通话 PCM 试验性适配

2026-11-03，VoBLE 工作树。用户反馈：通话声音只留在 Redmi 9，iPhone 没有收到透传音频。

## 证据与限制

- 实机仍是正式版 0.9.8.21 / 126，尚未包含本工作树的音频诊断与 Root 生命周期修复。
- 本轮读取的日志仍有两个 Root supervisor 交替杀死、重启 PCM 子进程，因此不能从当前日志断言“稳定媒体会话中 VOICE_DOWNLINK 一定全零”或“iPhone 播放一定有问题”。[Root 生命周期问题](android-root-pcm-lifecycle.md) 必须一并修复后建立新基线。
- Redmi 9 / lancelot / mt6768 / MIUI 13 的已枚举端口支持通话下行 8 kHz mono PCM16，上行支持 44.1 / 48 kHz stereo PCM16。[原始只读检查记录](android-redmi9-mtk-pcm-plan.md)。端口存在、创建成功不等于实际可听。

## 本次实现

仅匹配 Xiaomi / Redmi、lancelot、mt6768 三项的组合，作为试验性适配，不扩展到所有联发科机型。

1. 继续使用 `VOICE_DOWNLINK` / 8 kHz mono PCM16，下行显式绑定枚举到的 `TYPE_TELEPHONY` source。无匹配端口、格式或系统拒绝绑定时清理资源并报告阶段，不退回手机麦克风或 `VOICE_CALL` 混音。
2. 上行优先采用端口明确声明的 48 kHz stereo PCM16。网络的 8 kHz mono PCM16 经有状态 6 倍线性插值、左右声道复制后写入 AudioTrack。跨包保留一个输入样本的历史，无额外包队列；这只是格式适配，不提高原始窄带音质。若端口明确支持原网络格式则使用原格式；仅有 44.1 kHz 等未实现格式时明确失败。
3. iPhone / VoWLAN / VoBLE / Relay 的线格式保持不变：8 kHz、mono、PCM16，每 20 ms 为 320 字节。统计仍计算网络字节，不把扩展后的 HAL 字节误计为链路吞吐。
4. Redmi 9 会话中每秒观察 AudioRecord 实际路由与系统采集静音状态。已知输入落到非通话设备时停止该音频会话；上行同样对已知错误路由停止写入。null / 无权限读取诊断保持未知，不冒充路由验证。
5. 首页「Agent 自动检测」显示下行路由异常、系统静音、未确认路由等结果；静音音频的峰值为零仍只是待人工判断，不能据此自动替换采集源。
6. 三星及其他未匹配设备保留原采集、路由和缓冲策略。认证握手、通话状态、计时与早期媒体语义不变；不会为测试自动拨号、接听或录音。

日志新增 `audio_profile`、`capture_route_observed`。只输出固定能力标签、格式、路由类别与静音状态，不保存音频或在诊断里写入号码 / 配对密钥。

## 验证

- 纯 JVM：机型范围、端口格式选择、无法支持的编码 / 44.1k profile 拒绝、转换输出时长、任意分包连续性、立体声相等、正负满幅、静音、非完整样本及输出容量边界。
- 使用 Android 边界测试桩执行真实 `streamCallAudio` 初始化路径：验证 Redmi 9 下行 source 仍为 3 / 8k、绑定通话输入、AudioTrack 请求 48k stereo；READY 写入失败和 Rx 缺失 / 拒绝时释放所有录放资源。
- 核心状态测试验证系统采集静音、下行错误路由和 Redmi 9 未确认路由不会显示双向正常。
- 完整命令：`sh android-standalone/test.sh`。这些测试只处理合成 PCM，不等于实机声音验收。

实际结果：完整 Standalone 回归通过；最终核心测试重新通过，检测策略 43 项断言通过；桥单元 71 项断言、Redmi profile / 合成 PCM 转换 15 项断言及真实初始化路径测试通过。另覆盖“8k mono 输出缓冲查询不被支持，但 48k stereo 可用”的情形，避免在选择原生格式之前就失败。

最终开发包：`android-standalone/build/redmi9/AirSIM-Standalone-Redmi9-127-debug.apk`，包名 `com.airsim.phonecontrol.standalone`，版本 `0.9.8.21-redmi9-debug (127)`，SHA-256 `f911e2c700c893e3969283bbf6214d10d814c31eac403fbb8e532e2513d27bab`。使用临时 manifest 递增测试 build，仓库正式发布版本未改动；已核对最终编译字节码包含原生格式查询修正。

## Debug 安装与实机验收

手机现有正式包与本机 Debug 证书不同，不能 `install -r` 覆盖。需要原正式签名，或用户明确允许卸载原应用（会清除 AirSIM 配对 / 设置 / 本地缓存）后安装 Debug；不能静默卸载、伪造同证书或宣称保留数据。

安装后，用户授权所选 Root / Shizuku 通道，先观察 PCM 进程至少 60 秒稳定且不再交替重启，再进行本地 VoWLAN 配对与手动通话：

1. 对方说话 → iPhone 是否听见；记录对应会话的下行字节、峰值、实际路由、系统静音状态。
2. iPhone 说话 → 对方是否听见；确认上行实际 Telephony Tx，不能仅看非零字节。
3. 若下行数据非零且输入路由正确、iPhone 仍静音，再对齐 iPhone 的 PCM 接收 / 音频会话日志；若系统静音或全零，继续定位 ROM 采集策略，不靠增加音量、关闭 SELinux 或修改未知 mixer 参数猜测修复。
4. 呼出、接听、静音、挂断恢复与再次拨号分别验收。禁止用扩大缓存掩盖掉流。

尚无包含此改动的新包实机双向可听证据，状态为“已实现试验性路径，待安装验收”。

用户随后明确允许卸载正式版、安装 Debug 并重新配对。卸载成功后，前两次安装被 MIUI 返回 `INSTALL_FAILED_USER_RESTRICTED`；用户确认继续，2026-11-04 00:01 已通过 `adb install --no-incremental` 安装成功。核对设备版本为 `0.9.8.21-redmi9-debug (127)`，启动 Status ok，MainActivity 和 Agent / VoWLAN / VoBLE 前台服务在运行。

首次启动仍需重新授权：观测到 `root_bridge_unavailable IOException`，随后用户授予 Shizuku 权限。检查窗口仍有旧版 Root supervisor 残留，首页为“等待音频桥检测”，尚未确认新版特权服务接管或 PCM 稳定。下一步需在 Root 管理器允许新版 AirSIM，再在设置中点击“Root 授权 / 重试”，观察旧 supervisor 迁移退出，然后重新配对、由用户手动通话验收。此次未替用户拨号、接听或录音，不能把安装成功称为音频修复已验收。

## Android 官方依据

- [AudioRecord](https://developer.android.com/reference/android/media/AudioRecord)：preferred device 是路由请求，实际路由需录制过程中读取；`getActiveRecordingConfiguration()` 提供当前采集配置。
- [Sharing audio input](https://developer.android.com/media/platform/sharing-audio-input)：系统可能使采集客户端静音；通过 `isClientSilenced()` 区分系统静音与普通无声输入。


## 2026-11-04 后续安装状态

Root 在 Debug 127 授权后已成功启动 PCM，并清除旧 supervisor；随后切换仅 Shizuku 时 Root 正常停止。Shizuku 用户服务启动超时的处理详见 [权限通道生命周期记录](android-root-pcm-lifecycle.md)。

Debug 128 已覆盖安装且启动成功，保留 127 数据。安装包为 `android-standalone/build/redmi9-128/AirSIM-Standalone-Redmi9-128-debug.apk`，SHA-256 `81b96be2800737af826604ff4c1920a8a73ca1d4916c97481371ccfaf7830780`。新增权限通道状态刷新与绑定超时处理；Shizuku 底层服务启动和实际双向可听仍未通过验收。此前“待安装”记录由本节替代，不能把安装完成当作音频兼容性验收完成。


## 2026-11-04 Shizuku 启动根因与 Debug 129

本机 Shizuku `13.6.0.r1086.2650830c` 的用户服务启动器在构造 AirSIM 服务之前崩溃：

```text
ShizukuServiceStarter: unable to start service ...ShizukuBridgeUserService
Caused by: java.lang.NullPointerException:
  Attempt to invoke virtual method 'boolean java.lang.String.equals(java.lang.Object)' on a null object reference
  at android.app.LoadedApk.makeApplication(LoadedApk.java:1395)
```

通过同一手机、同一 AirSIM APK 的限时启动探针验证：13.6.0 出现该异常；官方 13.5.4 能执行到服务构造 `created uid=0`。探针使用未注册的诊断 token，不连接真实会话、不启动音频端点、不拨号。该结果与 [Shizuku #1198](https://github.com/RikkaApps/Shizuku/issues/1198) 的上游加载问题一致；不是 PCM 初始化失败，也不能用改采样率修复这个启动器异常。

用户明确授权后，官方 `13.5.4.r1049.0e53409` 通过 `adb install -r -d --no-incremental` 降级成功，无需卸载。官方 APK 来自 [v13.5.4 Release](https://github.com/RikkaApps/Shizuku/releases/tag/v13.5.4)，签名 SHA-256 与原安装一致：`268b5590e868fb08bae7e0ac413564cd1ff88f5ccff74af9dbd0dc918e30db30`。重启 Shizuku 后，实际客户端绑定成功并启动 PCM。AirSIM 保持仅 Shizuku，没有切换为 Root 通道（Shizuku 自身以 UID 0 运行）。

随后 Debug **129** 覆盖安装成功，版本 `0.9.8.21-redmi9-debug`，保留应用数据。安装包 `android-standalone/build/redmi9-129/AirSIM-Standalone-Redmi9-129-debug.apk`，SHA-256 `9761756cc0459f3bf1f6c74aebed825ab3dc21213a20dd61ba4ac84581201896`。

- 首页能单独报告“Shizuku 用户服务未启动 · 尚未进入音频检测”。检测到 MTK + 13.6.0 时提示上游已知风险，不将版本匹配或超时当作该设备音频硬件不兼容的证明。
- 真实服务连接后使用实时 PCM 检测报告，不再显示旧的启动失败。
- 保留前述 Redmi 9 的 Telephony Rx 绑定、48 kHz 双声道 Tx 格式转换、错误路由终止及帧/路由诊断。
- 实机已观察 `shizuku_user_service_connected`、`bridge_listening`、`capability_query=ok`、`tx_route=telephony`、`rx_route=present`、`tx_format=conversion`。空闲 `pcm_initialized=false` 正常；不为测试进程状态主动打开录音。

完整 `sh android-standalone/test.sh` 通过；检测策略 51 项、绑定期限 12 项、Redmi 格式/转换 15 项断言及桥初始化/释放回归通过。`git diff --check` 通过。未发布 Release、未提交或推送。

**后续用户验收：** 用户在 Debug 129 + 官方 Shizuku 13.5.4 上完成手动通话并反馈“都有声音了”，确认本机 iPhone 与蜂窝对端双向可听。此结果不扩展到所有 MTK ROM；来电、拒接、挂断恢复与连续重拨仍需分别验证。

随后按用户需求增加接通前运营商下行，并覆盖安装 Debug 130。协议、只收下行约束、已接通后挂断提示的系统限制及待验收清单见 [Redmi 9 早期媒体](android-redmi9-early-media.md)。不能把 129 的双向通话结果作为 130 运营商公告已经通过的证据。
