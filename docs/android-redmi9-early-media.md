# Redmi 9 运营商下行与早期媒体（试验性）

2026-11-04，VoBLE 工作树，Android Standalone Debug 130。

## 实机基线与本次范围

用户已确认 Debug 129 + 官方 Shizuku 13.5.4 下，Redmi 9 与 iPhone 的通话双向都有声音。这是用户手动通话的反馈，不代表所有联发科设备已兼容。

本次复用 iOS/U30 Air 已有的 `AIRSIMEM1` 协议，在 Redmi 9 的 Standalone VoWLAN 网关增加接通前只收下行的通道。仅匹配 Xiaomi/Redmi、lancelot、mt6768。未更改 iOS、U30 Air、AVF、云端 Relay 或 VoBLE 音频协议；旧客户端继续使用原通话路径，其他安卓设备不开放本试验接口。

两个用户场景分别处理：

- **未接通、对方拒接或暂时无法接通：** 在本次已认证呼出仍处于 Telecom DIALING 时接收真实 Telephony Rx。Android 没有在此路径提供已经验证的“运营商公告正在播放”标志，因此获得通道不等于必然有公告；初始无信号帧不发送给 iPhone，避免仅因静音帧提前覆盖本地等待音。
- **已经接通、对方挂断：** 保留既有通话下行，系统仍提供通话媒体时可继续播放；收到 DISCONNECTING / DISCONNECTED 后立即收尾。不延长已结束通话、不继续开启录音、不伪造 active、不合成“暂时无法接通”。如果系统先断开音频，不能保证听到挂断后的公告。此部分保留原状态与媒体行为，尚无新增“结束后媒体”能力证据。

## 认证及通话身份约束

1. 只有经过现有 HMAC/nonce 校验的 WLAN 拨号回执，成功取得确切 Android call ID 与 Agent backend call ID 后，才登记该配对客户端拥有的早期媒体会话。不会为探测再发一次拨号。
2. `GET /api/calls/early-media?call_id=<backend ID>` 沿用已配对请求认证。200 返回 version、agent_id、call_id、session_id、expires_at、state=`early_media`、direction=`recvonly`、format=`s16le-8000-mono` 和 proof；暂未进入 DIALING 或桥尚未运行返回 202；设备不支持返回 404；失效/非所属会话返回 410。
3. proof 为配对密钥 HMAC：`AIRSIM-EARLY-MEDIA1`、请求 nonce、agent、call、session、expires、early_media、recvonly、s16le-8000-mono，按 LF 分隔。与现有 iOS 验证格式一致。
4. PCM 前言使用 `AIRSIMEM1`，绑定上述 agent/call/session/expires/direction/format，签名路径 `/v1/pcm/early-media`。拒绝错误签名、重放 nonce、错配通话、其他配对所有者和 duplex 降级。
5. 每次 grant 20 秒，可续租且 session 稳定；登记后总窗口最多 120 秒（单调时钟）。每 100 ms 检查当前通话、有效期和配对是否仍存在。仅单一、未接通过的呼出符合资格；接通、结束、取消配对、断开客户端或发送上行字节均撤销通道。
6. 早期通道与普通通话共用音频独占门闩。关闭早期通道释放资源，不调用挂断；接通后交回原双向 PCM 流程。不会为了换媒体通道结束蜂窝电话。

## 音频边界

特权桥新增本地 `AIRSIMRX01` 握手，只创建 `VOICE_DOWNLINK` AudioRecord，绑定 Telephony Rx，8 kHz mono PCM16。没有 AudioTrack，也不回退到麦克风或 VOICE_CALL 混音。网络侧只传下行；iPhone 的既有接收路径不提前开启麦克风，不标记接通或开始计时。

收到首个非静音样本后才开始转发，随后保留连续 PCM。阈值仅用于忽略初始全零/近零帧，不是语音识别或“公告存在”的证明。路由异常仍按原严格 Redmi 检查处理。诊断只记状态、路由及字节计数，不保存音频。

## 自动化验证与安装

- `sh android/phone-control-app/test.sh` 通过：早期租约 20 项断言（含固定 HMAC 向量）；真实 TCP 网关测试覆盖错误签名、只收下行、上行拒绝、接通/结束/取消配对/关闭连接后的撤销、无误挂断及门闩复用；现有拨号、PCM 和短信回归通过。
- `sh android/phone-audio-bridge/build.sh` 通过：执行真实初始化代码的 Android 边界测试验证合成下行、没有创建 AudioTrack、上行拒绝及 AudioRecord 释放；原双向 Redmi 初始化和格式转换测试通过。
- Debug APK 构建成功，`git diff --check` 通过。测试仅使用合成 PCM，不等于运营商实机验收。
- 包：`android-standalone/build/redmi9-130/AirSIM-Standalone-Redmi9-130-debug.apk`。
- SHA-256：`b566efa5ef4fc88918d1a0e91f01de8c428789151c833161c76e5d0c1afbd6cf`。
- 已在 Redmi 9 通过 `install -r --no-incremental` 覆盖安装，未卸载或清除数据；设备报告 `0.9.8.21-redmi9-debug / 130`，启动成功，Shizuku 用户服务重新连接并出现 `bridge_listening`。空闲时 `pcm_initialized=false` 正常。
- 正式发布 manifest 未改，仅临时构建 manifest 增加测试 build。没有提交、推送、发布 Release 或部署 Worker。

## 待用户真机验收

1. iPhone 通过 VoWLAN 呼出，对端未接通即拒接：如运营商提供公告，应从 iPhone 听到；公告期间仍为未接通、不计时，真正结束后立即退出。
2. 呼出等待超过 20 秒：验证续租不中断媒体；对端接听后双向声音正常，iPhone 麦克风只在正常接通路径启用。
3. 正常接通后让对端挂断：系统仍提供的下行可听，系统结束后停止计时与音频。若没有公告，需结合状态/字节日志判断系统是否有提供，不能仅凭无声判定客户端失败。
4. 用户主动挂断、无公告、断网、取消配对均能释放资源；结束后新手动拨号不串音、不自动重拨。
5. 来电接听、正常双向通话与连续手动重拨不回归。

安装后的运营商公告尚待用户反馈。本轮没有代用户拨号、接听、发短信或录音。

## Debug 130 实机反馈与 131 修复

用户反馈对方挂断后 iPhone 仍未收到运营商公告。2026-11-04（北京时间）两端日志对齐结果：

- 01:40:44.440，安卓建立 owned dial receipt；01:40:44.899 再次报告 Telecom CONNECTING（9），随后变为 DIALING（1）。iPhone 01:40:46.750 记录早期媒体协商 `revoked`。
- 01:41:13.270，再次建立回执；13.523 / 13.596 / 13.636 重复 CONNECTING；13.652 变为 DIALING。iPhone 01:41:15.623 同样记录 `revoked`。
- 等待期间桥保持监听且未初始化采集；第二次通话接通后原双向 PCM 正常启动。这不能证明运营商没有提供早期语音，因为早期媒体没有建立。

根因：130 的 InCallService 把所有非 DIALING 回调都当作撤销条件，而回执可在 CONNECTING 建立。重复的连接/详情回调因此删除有效授权，iPhone 收到 410 后停止协商。

131 修复：统一准备状态判定，CONNECTING / SELECT_PHONE_ACCOUNT / DIALING 保留同一回执和 session；只有 DIALING 可真正打开只收下行通道。ACTIVE、DISCONNECTING、DISCONNECTED 等状态仍撤销；迟到的准备状态不能恢复已撤销授权。新增不含通话 ID、号码或密钥的探测结果日志（pending / ready / revoked / unsupported）。

回归覆盖真实重复 CONNECTING 顺序、准备阶段 session 稳定、三种接通/终态后不可复活，以及经过此顺序后的签名 TCP 下行。新构建使用通用命名 `AirSIM-Android-Standalone`、版本名 `0.9.8.21`，不设厂商版本。

这修复了已证实的授权时序缺陷；运营商语音实际可听仍需安装后手动复测。已接通后的终态处理保持不变，不为播放公告延迟结束。

`sh android/phone-control-app/test.sh` 全部通过，包含新增状态回归与真实 TCP 测试；APK 构建和 `git diff --check` 通过。已保留数据覆盖安装 `0.9.8.21 (131)` 并启动成功。包为 `android-standalone/build/candidate-131/AirSIM-Android-Standalone-debug.apk`，SHA-256：`f6eb82a332c1cd5d8daa5ece11a6c2a23d77080acd77a33f488e873f9ab97c89`。未更新 iPhone、发布或替用户发起通话。

用户随后手动复测并反馈“有了”，确认此次运营商音频可以听到。未单独确认的接通后挂断、所有运营商及不同机型仍不扩大为已验收。
