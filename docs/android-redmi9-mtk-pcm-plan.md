# Redmi 9 联发科 PCM 桥：安装记录与适配方案

后续进展：2026-11-03 已在 VoBLE 工作树实现限定 Redmi 9 的试验性通话端口绑定和 48k stereo 上行格式适配，尚待新包实机验收，见 [实现与验收说明](android-redmi9-pcm-adaptation.md)。下文保留最初安装 / 只读检查阶段的记录。

日期：2026-11-03。工作树：VoBLE，提交 `1f35376`。用户请求安装最新版 Android Standalone，并核查联发科 PCM 适配、给出方案；本轮不修改通话音频实现、不改系统 audio policy、不拨号、不录制音频。

## 安装结果

- 设备：Redmi 9，型号 M2004J19C / lancelot，厂商 Xiaomi，平台与 hardware 均为 `mt6768`，arm64。
- 系统：Android 12 / API 31，MIUI `V13.0.5.0.SJCCNXM`，安全补丁 2022-09-01。
- 原安装：Standalone `0.9.7.1 (81)`。
- 已通过 `adb install -r` 覆盖为 **`0.9.8.21 (126)`**，包名 `com.airsim.phonecontrol.standalone`；未卸载、未清除数据，firstInstallTime 保持不变。
- 安装包来自本机既有 Release 资产，SHA-256 与 [GitHub v0.9.8.21](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.8.21) 一致：`2c7dff44a660c4a1433a84bc11c4b7f9f548a69083bb1753a61fc6e52401e537`。安装后设备上 base.apk 的摘要也再次匹配。
- 新旧签名 SHA-256 相同：`cde660af4c3e053615a4967e5188ca29eee084e50958ead1fd5cc80837b0965b`。
- MainActivity 启动返回 Status ok，后续进程仍在；检查窗口 AndroidRuntime 未输出崩溃。这里只证明安装/启动，不是通话验收。
- GitHub 的 latest 指针仍指向较旧的 v0.9.8.16；已另外查发布列表和指定 tag，确认最新发布的非草稿、非预发布应用版本为 v0.9.8.21。本轮未修改 Release 的 latest 标记。

## 结论

**不是完全没有联发科可用的通路，而是已有通用 Android Telephony 桥，尚无这台 Redmi 9 的完整适配和双向验收证据。** 当前源码没有 MediaTek 专用后端或根据端口 profile 选择采样率/声道的逻辑。不能仅凭“MediaTek”判定不支持，也不能凭端口存在判定已适配。

`PhoneAudioBridge.java` 当前：

- 下行固定 `VOICE_DOWNLINK`（source 3），8 kHz / 单声道 / PCM16。
- 上行先尝试三星 `semAddAudioTag(VOICE_TX)`；无该方法时枚举 `TYPE_TELEPHONY` sink，并调用 `AudioTrack.setPreferredDevice()`。
- AudioTrack 同样固定 8 kHz 单声道，usage 为 VOICE_COMMUNICATION。
- 已有 `getRoutedDevice()` 上行观测和 `voice_tx_route_unverified` 日志，但只在开始写入后验证。未验证路由时继续降级运行，以兼容部分三星隐藏路由；这不能对所有厂商等价表示“双向正常”。
- 没有下行实际 routed device 的同等完整证据，也没有将 HAL profile 与桥协议格式解耦。

源码位置：[PhoneAudioBridge.java](../android/phone-audio-bridge/src/com/airsim/bridge/PhoneAudioBridge.java)；通话静音策略见 [LocalOutputMuteController.java](../android/phone-control-app/src/com/airsim/phonecontrol/LocalOutputMuteController.java)。当前策略统一保持通话流最低非零且不 mute，避免连带压低采集；本轮不改这条策略。

## 只读真机证据

读取 `/vendor/etc/audio_policy_configuration.xml`、`dumpsys media.audio_policy`，再用一个临时 shell Java 程序运行与桥相同的 `AudioManager.getDevicesStatic()` 查询。程序没有创建 AudioRecord/AudioTrack，没有打开麦克风、播放或采集；完成后停止并移除设备端临时 JAR。

| 方向 | 查询结果 | 原生 profile |
| --- | --- | --- |
| 上行 | TYPE_TELEPHONY sink，运行时 id 10 | 48000 / 44100 Hz，2 声道；包含 PCM16 |
| 下行 | TYPE_TELEPHONY source，运行时 id 16 | 8000 / 16000 / 32000 / 48000 / 44100 Hz，1 / 2 声道，PCM16 |

端口 ID 会变化，**不能写死 10/16**。静态配置与运行时枚举结果一致；`Telephony Tx` 可由 `incall_music_uplink` 输入，后者带 `AUDIO_OUTPUT_FLAG_INCALL_MUSIC`；`Voice Call In` 路由到 `voice tx` 输入。

因此，“找不到 Telephony Tx”并不是当前只读检测发现的问题。**8 kHz 单声道与上行原生 44.1/48 kHz 双声道的差异是优先排查项，不是已证实的失败原因**：系统可能重采样/重建 Track，必须在真实通话中检查实际输出、flags 和对端听感。

Shizuku 已安装 13.6.0，服务以 root UID 运行，升级后 App 日志有 `shizuku_binder_received uid=0 version=13`。binder 可达不等于 UserService/PCM 已授权并完成音频初始化。本机是 MIUI 13，不能直接套用 HyperOS 3 的 Shizuku 13.6.0 回归结论，也没有擅自降级 Shizuku。

## 适配路径：先证据，再按能力选择后端

### 阶段 0：用已安装正式版建立通话基线

由用户手动发起/接听测试电话。首次先测本地 VoWLAN，排除 Relay 与 VPN 抖动；通话过程中只记录元数据，不保存 PCM。

收集以下证据：

1. Shizuku 授权、UserService 存活及 PCM startup 的具体阶段/错误码。
2. 当前唯一已认证 call ID，Telecom 状态；没有 active 时不把媒体初始化当作接通。
3. AudioRecord/AudioTrack 请求格式与实际格式、上下行 routed device、audio policy 中实际 output、`INCALL_MUSIC` 标志、读写错误及帧计数。
4. A→B 与 B→A 分别人工确认可听；路由正确且非零帧也不足以单独证明对端听见。
5. 若现有版本已双向正常，优先补诊断/兼容性记录，不强行引入联发科专用数据通路。

### 阶段 1：增加能力探测与诚实的就绪状态

建议在音频桥层增加 `AudioRouteCapabilities` / `TelephonyPCMProfile`（新设计名，尚未实现）。优先探测实际端口、profile、AudioRecord source 权限及格式；SoC/厂商只作辅助匹配，不按芯片拆 APK。

保持三星 `SAMSUNG_TAG` 路径与现有接口不变；非三星路径区分“端口发现”“初始化成功”“路由验证”“双向人工验收”，不能统一显示已就绪。空闲时 `bridge_listening` / `pcm_initialized=false` 仍是正常状态，不反复重启。

### 阶段 2：必要时添加 MTK Telephony 格式适配

如果阶段 0 证实固定格式或路由失败，在通用 Telephony 后端内增加能力驱动 profile：

- 桥网络协议继续 8 kHz / mono / PCM16 / 20 ms，每帧 320 字节，保持 VoWLAN、VoBLE 和云端兼容。
- Redmi 9 的上行候选优先 48 kHz / stereo / PCM16，显式选择探测到的 Telephony Tx；如 HAL 仅允许 44.1 kHz，使用经测试的连续分数重采样或明确不支持，不用简单整数抽样凑数。
- 单声道上行经连续重采样并复制到左右声道；处理器保留跨包状态，控制缓冲上限，不能通过扩大队列掩盖卡顿。硬件量化不代表源语音质量提升。
- 下行优先使用其已声明支持的 8 kHz mono VOICE_DOWNLINK。若实际只在更高采样率工作，再加低通抗混叠降采样；VOICE_CALL 会混合上下行，不能无条件作为“修复”回退以免回声。
- 使用 VOICE_COMMUNICATION + 明确 Telephony Tx 选择，让 AudioPolicy 选择 incall music 路径；不猜测 MTK 私有 audio parameter，不直接修改 mixer/SELinux/vendor XML。
- 未接通时不因探测自动启动采集或注入；会话创建、替换、取消与现有认证 call ID 生命周期绑定，不影响 early media/计时规则。

### 阶段 3：路由安全与资源收尾

MTK 路径若实际路由为 Speaker/Earpiece，应立即停止其上行 Track 并报错，不把远端语音播放到手机外放；三星隐藏路由另保留原兼容分支，不能全局改变现有策略。路由返回 null 时给有界验证窗口并显示“待验证”，不要宣称已验证；已知错误路由立即关闭。

补充 downlink routed-device 观测；通话终态、鉴权撤销、切模式、网络断开和异常都释放录放端点并恢复原音量。Shizuku 以 shell/root 运行的差别记入诊断，不能靠关闭 SELinux、任意提权或改私有 HAL 参数作为默认方案。

### 阶段 4：只有框架路径被实证否定后才评估厂商通路

若权限、路由和格式均匹配但实际仍无上行，再对照该 ROM 的 MTK HAL 实现/公开厂商资料，评估是否缺少 incall-music 注入能力。根权限与 `/dev/snd` 可见不代表可直接绕过通话 DSP；直接 ALSA、厂商服务或系统补丁属于另一阶段，需要单独设计与验收，不在本轮安装中执行。

## 测试与验收矩阵

- JVM：端口选择、profile 匹配、无端口/权限拒绝/未知格式，三星路径不回归；重采样的分块连续性、频率/幅度、单声道复制、欠载静音、积压丢旧帧，错误与取消不泄漏端点。
- 真机：用户呼出与来电各测；对端听到 iPhone、iPhone 听到对端；本机不意外外放；静音、扬声器/耳机、挂断恢复、拒接后不自动重拨。
- 通路：VoWLAN 基线通过后再测 VoBLE 和云端 PCM。先不要把尚未验收的 AirSIM Cloud WebRTC 加入同一轮排障。
- 生命周期：锁屏、返回前台、Shizuku 重启、Wi-Fi 切换、连续 30 分钟；短信/默认电话角色不回归。

完成判据是当前 ROM 的可重复双向语音与正确收尾，而不是日志仅出现 `AIRSIMREADY`、`route_verified` 或进程存活。本轮只完成正式 APK 无损升级和只读设备检查；音频方案未实施，真实通话待用户手动验收。

## 官方依据

- [Android AudioRouting](https://developer.android.com/reference/android/media/AudioRouting)：preferred device 不保证就是实际设备，routed device 需在播放/录制过程中查询。
- [Android VOICE_DOWNLINK](https://developer.android.com/reference/android/media/MediaRecorder.AudioSource#VOICE_DOWNLINK)：通话下行采集依赖特权 CAPTURE_AUDIO_OUTPUT，普通应用权限不是充分条件。
- [AOSP Android 12 AudioPolicyManager](https://android.googlesource.com/platform/frameworks/av/+/refs/tags/android-12.0.0_r1/services/audiopolicy/managerdefault/AudioPolicyManager.cpp)：显式 Telephony Tx、线性 PCM、可访问通话音频以及相应 usage/stream 满足时才选择 IN-CALL MUSIC；小米厂商实现是否完全一致仍需实测。
