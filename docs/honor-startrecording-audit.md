# 荣耀/部分 OEM ROM 通话音频 0 字节问题：根因与修复

本文记录一个在 **HONOR AMG-AN00（Android 16 / SDK 36）** 上实测确认的故障：
AirSIM Android standalone 包信令完全正常（能呼出、能接通），但 PCM 双向均为 0 字节，
远端因无音频超时挂断。

修复位于分支 `fix/honor-startrecording-audit`，基线为 tag `v0.9.8.23`（`b845254`）。

---

## 1. 现象

早期日志表象容易把人带偏，先列清楚：

- `vowlan_early_media_probe result=ready` —— 探测显示就绪，但实际拿不到音频；
- `early capture unavailable` → `shell PCM handshake failed` 反复循环，无退避；
- 所有 PCM 会话 `uplink_bytes=0`、`downlink_bytes=0`，`pcm_initialized=false`；
- Shizuku / shell 权限全部正常，`com.android.shell` 的 `RECORD_AUDIO`、
  `CAPTURE_AUDIO_OUTPUT` 均已 granted，abstract socket 握手 `rejected_clients=0`。

也就是说：**不是权限问题、不是 socket 问题、不是后台进程被杀**。

## 2. 根因

在 helper 进程（`app_process`，uid 2000/shell，进程名 `<pkg>:pcm_shell`）里，
`register` 之后调用 `AudioRecord.startRecording()` **100% 抛 NullPointerException**。
一旦这一层失败，后面所有「握手失败」「会话重建」都是它的下游症状。

用 `dexdump -d` 反汇编设备固件 `/system/framework/framework.jar`（classes2.dex）
里的 `AudioRecord.startRecording()V` 得到确凿证据（方法起始偏移 `469d74`）：

```
0000  iget         mRecordSource                     // AOSP 行 1557
0004  if-eq  v?, 5, <跳过审计>                          // 源 == CAMCORDER 则跳过
0006  invoke-static ActivityThread.currentApplication() // OEM 新增，行 1559
000a  invoke-static Objects.requireNonNull(...)        // 抛点，行 1560
0035  ... HiLog.authPrintf("AudioRecord.startRecording", ...)
0056  /mState 检查                                    // AOSP 原逻辑，行 1571
```

`startRecording(MediaSyncEvent)` 重载里也有同样的审计块。

AOSP 主线（android16-release，`AudioRecord.java` L1491）的 `startRecording()`
**没有任何 `requireNonNull`**，坐实这段是 OEM 后加的隐私审计。

`app_process` 拉起的进程没有 `ActivityThread`，所以
`ActivityThread.currentApplication()` 恒为 `null` →
`requireNonNull` 必抛 → **除 `CAMCORDER(5)` 外所有采集源全部崩溃**。

设备探针实测 7 种源（3 / 4 / 7 / 1 / 0 / 6 / 9）全部 NPE，只有源 5 通过。
因此「换采集源」这条路救不了：`VOICE_DOWNLINK(3)` 和 `VOICE_CALL(4)` 崩在同一行。

## 3. 修复实现

文件：`android/phone-audio-bridge/src/com/airsim/bridge/PhoneAudioBridge.java`

新增 `startRecordingCompat(AudioRecord recorder, long started)`：

1. 反射取 `AudioRecord` 私有字段 `mRecordSource`（一次性解析并缓存，`Field` 静态持有）；
2. 调 `startRecording()` **之前**把该字段临时置为 `5`（`CAMCORDER`），使审计分支被 `if-eq 5` 跳过；
3. `startRecording()` 返回后在 `finally` 里**回填原值**；
4. 任一步反射失败（字段被改名/隐藏）→ 退化为普通 `recorder.startRecording()`，
   并在下一次失败时由既有诊断链路（`error_stack`）暴露真实栈；
5. 首次成功绕过时向 stdout 发一条一次性的结构化事件，便于从 logcat 确认修复生效：

```json
{"event":"capture_audit_bypass","builder":"HONOR/HNAMG",
 "capture_source_id":3,"bypass_source_id":5,"result":"ok"}
```

为什么不直接把对象建成源 5：`AudioRecord` 的构造参数会传到 native 层，
源的改变会影响音频路由决策（HAL 走麦克风/摄像头路径而不是通话下行），
所以对象仍按真实源 `VOICE_DOWNLINK` 构建，只改 Java 字段骗过审计。

调用点共两处（本版本只有两处 `startRecording()`）：

| 位置 | 用途 |
|---|---|
| `streamEarlyAudio()` 的 `phase="start_capture"` | 早媒体只收下行（receive-only） |
| `streamCallAudio()` 的 `phase[0]="start_capture"` | 完整通话（双向） |

诊断增强：`android/phone-audio-bridge/src/com/airsim/bridge/AudioStartupFailure.java`
的 `diagnosticFields()` 增加 `error_stack` —— 取异常 origin 的前 8 帧，
格式 `类.方法:行号`，用 ` <- ` 连接。只导出类名与行号，不导出 OEM 异常正文，
避免把厂商内部信息或用户数据带出特权进程边界。

## 4. 真机验证

设备：HONOR AMG-AN00，SDK 36，包名 `com.airsim.phonecontrol.standalone.rongyao`，
versionCode 132（debug 签名）。

### 4.1 v0.9.8.23 + 修复（首次验证）

| 通话 | 下行 | 上行 |
|---|---|---|
| A | 649,280 B / 2029 帧 / 峰值 21,489 | 649,600 B / 2030 帧 / 峰值 24,459 |
| B | 805,440 B / 2517 帧 / 峰值 31,111 | 804,800 B / 2515 帧 / 峰值 16,911 |

### 4.2 重打 v132（改包名后再次验证）

挂断前最后一帧累计：

| 项 | 值 |
|---|---|
| `pcm_initialized` | `true` |
| `pcm_capture` | `observed` |
| `pcm_route` | `verified`（telephony） |
| 下行 | 668,160 B / 峰值 26,055 |
| 上行 | 666,560 B / 峰值 20,366 |
| `pcm_failure_count` | 1（`downlink_error: SocketException`，挂断瞬间正常现象） |
| `session_error` | 0 |

同一进程内可见 `capture_audit_bypass`（`builder=HONOR/HNAMG`），确认绕过生效。

### 4.3 附带观察

`v0.9.8.23` 去掉了 `Redmi9PCMProfile` 机型白名单，receive-only 早媒体路径改为通用
`TelephonyDownlinkProfile.supports(...)`。因此这台荣耀第一次拿到早媒体数据
（16,320 B / 51 帧 与 51,840 B / 162 帧），并触发 `early_media_signal_observed`。
早媒体阶段 `uplink_bytes=0` 属设计（只采下行）。

## 5. 构建

环境要求（macOS / Linux 均可）：

| 组件 | 版本 |
|---|---|
| JDK | 21（`JAVA_HOME` 指向 JDK 21） |
| Android SDK | `platforms/android-35`、`build-tools/35.0.0` |
| `ANDROID_SDK_ROOT` | 指向 SDK 根目录 |

```bash
export JAVA_HOME=/path/to/jdk-21/Contents/Home
export ANDROID_SDK_ROOT=/path/to/android-sdk

# 1. 音频桥 + 桩测试（先跑这个，确认宿主 JVM 上逻辑自洽）
sh android/phone-audio-bridge/build.sh

# 2. standalone APK（注意：不是 android/phone-control-app/build.sh，
#    那个打出的是 com.airsim.phonecontrol，不是 standalone 包）
sh android-standalone/build.sh
# 产物：android-standalone/build/android/AirSIM-Android-Standalone-debug.apk
```

### 5.1 依赖（内网/受限网络必读）

`android/phone-control-app/build.sh` 会去 `repo1.maven.org` 与 `dl.google.com`
下载 5 个依赖并校验 sha256。这两个源在国内经常不可达，可预先从镜像下载到
`android/phone-control-app/build/dependencies/`：

```bash
mkdir -p android/phone-control-app/build/dependencies
cd android/phone-control-app/build/dependencies
curl -fsSL "https://maven.aliyun.com/repository/public/dev/rikka/shizuku/api/13.1.5/api-13.1.5.aar" -o shizuku-api.aar
curl -fsSL "https://maven.aliyun.com/repository/public/dev/rikka/shizuku/aidl/13.1.5/aidl-13.1.5.aar" -o shizuku-aidl.aar
curl -fsSL "https://maven.aliyun.com/repository/public/dev/rikka/shizuku/shared/13.1.5/shared-13.1.5.aar" -o shizuku-shared.aar
curl -fsSL "https://maven.aliyun.com/repository/public/dev/rikka/shizuku/provider/13.1.5/provider-13.1.5.aar" -o shizuku-provider.aar
curl -fsSL "https://maven.aliyun.com/repository/google/androidx/annotation/annotation/1.3.0/annotation-1.3.0.jar" -o androidx-annotation.jar
curl -fsSL "https://maven.aliyun.com/repository/public/org/bouncycastle/bcprov-jdk15to18/1.84/bcprov-jdk15to18-1.84.jar" -o bcprov-jdk15to18-1.84.jar
```

镜像产物与官方一致，`build.sh` / `crypto-dependency.sh` 里的 sha256 校验可通过：

```
shizuku-api.aar      4def9bde498ef8626614c2fc5db9af4749c86f16f6c33e3f5658d35e70bab59b
shizuku-aidl.aar     33fe7191cdd69fcb66d649264f3b0c47acb2f3d6343afc05b98dbbff6f221963
shizuku-shared.aar   4659642c9339be0a26e9c65bb8648f7ad6d8f4a465f557993ccbc78802381635
shizuku-provider.aar b0f18cd9812464ec171c53cac93a819fe411718a3965c311f01eb4de265381b3
androidx-annotation.jar 97dc45afefe3a1e421da42b8b6e9f90491477c45fc6178203e3a5e8a05ee8553
bcprov-jdk15to18-1.84.jar a30777eebbd44aa1713c14ee04547de1df63ef3e383e910ed210e1d0f2c2ef92
```

### 5.2 签名

debug 构建每次由 `build.sh` 用 `keytool` 在 `android/phone-control-app/build/debug.keystore`
生成。若目录被清空，签名会漂移，**无法 `adb install -r` 覆盖旧包**。
判断是否同签名要用完整证书比对，不要看 `dumpsys package` 里的 `signatures=[xxxxxxxx]` 片段：

```bash
$ANDROID_SDK_ROOT/build-tools/35.0.0/apksigner verify --print-certs <apk>
```

签名不同时的选择：`adb uninstall <pkg>` 后重装（会清掉该包的 VoWLAN 配对记录与
Shizuku 授权），或改包名共存（见第 6 节）。

## 6. 安装与共存

本分支把 standalone 的 applicationId 改成
`com.airsim.phonecontrol.standalone.rongyao`（桌面显示「AirSIM 荣耀修改版」），
Shizuku provider authority 同步改为 `…rongyao.shizuku`，versionCode 132。
这样可与官方包并存，也便于一眼区分。

**重要：不要同时运行两个包。** PCM 端口在
`android/phone-audio-bridge/src/com/airsim/bridge/BridgeArguments.java` 里写死为
`7580`，后启动的那个 helper 会持续报：

```
listener_restarting error_class=java.net.BindException
error_message="bind failed: EADDRINUSE (Address already in use)"
```

排查提示：该桥绑的是 `::ffff:127.0.0.1:7580`（IPv6 映射环回），
`cat /proc/net/tcp` 里**看不到**，必须查 `/proc/net/tcp6`。
卸载旧包后其 `app_process` 子进程可能仍存活（uid 2000），
需要手动 `kill -9 <pid>` 才能真正释放端口。

若确需两包并存，必须把端口改为按包名派生（`BridgeArguments` 与
`VoWLANGatewayService` 两侧一致），当前分支未做此改动。

## 7. 与上游同步

基线选择 **tag `v0.9.8.23`**，而不是 `main`：该 tag 的 commit `b845254`
领先 `main`（`1855e43`）4 个提交，`main` 不是它的后代。

```bash
git remote add upstream https://github.com/kai-wu-cortex/AirSIM
git fetch upstream --tags
git checkout main && git merge --ff-only upstream/main && git push
git checkout fix/honor-startrecording-audit && git rebase main
```

或者直接在 GitHub 网页用 fork 仓库的 **Sync fork**，再 rebase 本分支。

## 8. 本分支不做的事

- 不改 `VoWLANPCMRelay` 的 `shell PCM handshake failed` 错误码透传；
- 不改 `/api/calls/audio/host/config` 的 `route_ready` / `route_listening`；
  因此日志里 `pcm_capture_route` / `pcm_capture_silenced` 仍是 `unknown`；
- 不加 `CAPTURE_SOURCE_LADDER` 采集源降级阶梯（实测无效：源 4 崩在同一 NPE）；
- 不信任 `vowlan_early_media_probe result=ready` 的返回值（已知与真实能力不符）。

## 9. 适用范围

任何在 `app_process`（无 `ActivityThread`）里跑 `AudioRecord` 的 OEM ROM 都可能命中，
包括但不限于荣耀/华为系。判断方法：看 helper 的 `session_error` 是否带
`error_stack` 且栈顶在 `android.media.AudioRecord.startRecording`，
若同时 `getClass().getSimpleName()=="NullPointerException"`，即为本文描述的审计 NPE。
