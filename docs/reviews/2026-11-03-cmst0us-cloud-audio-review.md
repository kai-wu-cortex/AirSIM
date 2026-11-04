# CmST0us/AirSIM 云端媒体优化评审

日期：2026-11-03（Asia/Shanghai）。本轮为源码比较与定向自动化验证，不合并代码、不部署、不安装、不发起真实电话。

## 比较范围

- 当前工作树：`VoBLE`，`1f353767faaf26d764f2e359b962e5104d8b693c`，已包含于主项目 `main` 的 `71006f4`；两者程序代码相同，main 另保留 README 删除赞助区块的修改。
- Fork：[`CmST0us/AirSIM`](https://github.com/CmST0us/AirSIM)，main `aafb2036e40bcebf6452531f4020ef6fe3931da9`。
- 共同祖先：`454a2bb`（2026-10-12）。从该祖先起当前 VoBLE 独有 224 个提交，fork 独有 126 个提交。这不是基于当前版本的一组小补丁。
- 只读引用：`review-cmst0us/main`；审阅副本在 `/tmp/airsim-cmst0us-aafb203-review`，未加入生产构建。
- 使用现有 VoBLE 工作树；原主目录的未提交修改仍保存在原保留分支，没有切换或覆盖它。

## 结论

值得吸收，但不建议整分支 merge，也不建议直接 cherry-pick 整个 WebRTC 提交。最有价值的是媒体/控制生命周期分离、可归因的卡顿统计、成熟的编解码与抖动处理，以及验证这些行为的测试夹具。

Fork 已从 v1 演进到 v2：iOS libwebrtc + 模块 Pion + 原生 Opus helper + ECS control/PostgreSQL/TURN。其优化主要服务于 EG25/RM500。相对共同祖先，`android/`、`android-standalone/`、旧 `push-relay-worker/` 没有对应改动；不能把模块测试结果当成三星 Standalone 的性能验证。

## 当前项目已有的能力

当前云端仍是 WebSocket/TCP 上的 8 kHz、16-bit 单声道 PCM，20 ms/320 字节一帧。两端已有：

- 有界接收缓冲、初始 80 ms 预缓冲、自适应目标、稳定后回落；硬队列上限 12 帧。
- 发送队列上限 12 帧、250 ms 过期丢弃、短缺帧衰减补偿及边界平滑。
- Android 采集/发送/接收/播放分离、写阻塞看门狗；iOS 独立媒体队列、受限播放器排队。
- 通话身份/代次隔离、云端连接重建和质量计数。

不能把 fork 的“80 ms 缓冲、12 帧上限、自动重连”当作本项目完全缺失的新功能。另有一个文档偏差：`docs/cloud-pcm-resilience.md` 写目标最多 10 帧，实际 iOS `CloudPCMAdaptiveJitterBuffer` 目标最高 12 帧，Android 最高 10 帧；后续应按代码及测量统一说明。

源码：`iOS/AirSIM/IPhoneCloudCallSession.swift`、`CloudPCMAudioQueue.java`、`CloudPCMMediaPump.java`、`StandaloneCloudMediaManager.java`。

## 值得移植的方向与边界

| 方向 | Fork 的实现 | 对当前项目的建议 |
| --- | --- | --- |
| 分段媒体诊断 | helper 等待、RTP 写入、收包间隔、播放节拍分别计数；记录最大停顿、GC、FEC/PLC、队列裁剪，iOS 记录 RTT/NetEQ | P0。保留现有统计，新增采集间隔、发送耗时、播放间隔与排队时长的分布；先区分设备调度、网络、播放端。raw PCM 当前不能凭到达序号推断网络丢包率 |
| 媒体失败不等于电话结束 | 媒体由 Agent 生命周期持有，控制连接重建不取消媒体；iOS 同一通话用新媒体 session 恢复 | P0/P1。保留本通 call ID/UUID/generation 与 CallKit 所有权，明确显示“音频恢复中”；短暂控制失败不关闭健康媒体。当前多次媒体重连失败会结束本机 CallKit，应拆开媒体故障与权威电话终态 |
| 同通话会话替换 | 新 session 替换旧 session，等旧 helper 退出再启动新 helper；保持静音与输出路由 | P1。只重建媒体，不重新拨号；使用独立 media session ID，不能更换拨号 operation ID 绕过幂等控制；对旧连接迟到回调继续做代次隔离 |
| 播放时钟与延迟回落 | 固定 20 ms 网格；持续深队列逐帧回落；超过 12 帧回到 4 帧；RTP 序号排序/FEC/PLC | P1。参考目标延迟控制与可测时钟；不要直接抄 5 ms 追赶发送策略，它与我们“恢复后不突发发送”的现有策略不同，可能改变听感或造成新积压 |
| 音频线程调度 | 原生模块线程尝试 SCHED_FIFO 10；减少控制热路径重复验签/JSON 分配 | P1。三星路径优先调查普通线程调度、分配和锁等待，采用 Android 可用的音频线程优先级并记录实际结果。模块 root 实时调度不能照搬进普通 APK；不得降低实时鉴权要求 |
| WebRTC/Opus | 20 ms、16 kHz 输入、32 kbps VBR、FEC/PLC、DTLS-SRTP、iOS NetEQ，TURN UDP 为主/TCP 回退 | P2。最有结构性价值，需 iOS、Android、信令和 TURN 一起实现，先做可选择的实验媒体传输，保留原 PCM。旧 Agent 和 Watch 必须继续可用 |
| 正确重采样 | 模块 16→8 kHz 有低通处理；16 kHz 原生设备可保留更多频带 | 独立音质改进。当前 iOS 的云端重采样为线性插值，未见专用抗混叠滤波，可评估系统转换器或正确的有状态重采样；与卡顿原因分开评估 |

Fork 关键源码：

- [媒体统计与独立生命周期](https://github.com/CmST0us/AirSIM/blob/aafb2036e40bcebf6452531f4020ef6fe3931da9/module/airsim-agent/internal/cloud/bridge.go)
- [模块抖动缓冲与时钟](https://github.com/CmST0us/AirSIM/blob/aafb2036e40bcebf6452531f4020ef6fe3931da9/module/airsim-agent/internal/cloud/jitter.go)
- [iOS 媒体协调器](https://github.com/CmST0us/AirSIM/blob/aafb2036e40bcebf6452531f4020ef6fe3931da9/iOS/AirSIM/CloudV2/V2MediaCoordinator.swift)
- [iOS 通话归属与恢复](https://github.com/CmST0us/AirSIM/blob/aafb2036e40bcebf6452531f4020ef6fe3931da9/iOS/AirSIM/CloudV2/CloudV2Model.swift)
- [WebRTC 接入](https://github.com/CmST0us/AirSIM/blob/aafb2036e40bcebf6452531f4020ef6fe3931da9/iOS/AirSIM/CloudV2/V2WebRTC.swift)
- [Opus 配置](https://github.com/CmST0us/AirSIM/blob/aafb2036e40bcebf6452531f4020ef6fe3931da9/module/rm500/audio/src/opus_codec.c)

## 当前代码中具体需要关注的位置

1. `IPhoneCloudCallSession.swift:1378` 的 `recoverConnectionIfNeeded()`：重连重试耗尽后发出 `.failed`、结束 CallKit 并 `stop()`。这是可确认的代码行为，不等于设备端运营商电话已挂断。应增加“媒体不可用、电话状态待确认”的有界恢复状态；保留用户挂断与原呼叫身份，禁止自动第二通。不能无期限保留已经结束但缺终态的电话。
2. `IPhoneCloudCallSession.swift:1853`：iOS 给收到的 raw PCM 分配本地到达序号，发送也仍为裸 PCM。Android 可选 `airsim-pcm-v1` 帧头含序号/时间戳，但当前 iPhone 未协商使用，Android 解码也只取出 PCM。建议先做向后兼容、经能力协商的双向媒体帧元数据。采集时间应使用明确时基；没有时钟同步不能直接相减冒充端到端时延。
3. `CloudPCMMediaPump.java` 的循环通过 `CloudPCMAudioQueue.nextTickNanos()` 调度，过时后从当前时间重新起一个 20 ms 周期；可以测试连续迟醒带来的节奏变化。Fork 保持网格且有限追赶，但不是可直接替代的算法。
4. `StandaloneCloudMediaManager.java` 通过共享线程池跑媒体任务；桥接 `PhoneAudioBridge.java` 建立普通 Thread，所审阅路径未见显式音频优先级设置。这是调度优化候选，尚无本机负载数据证明它是用户卡顿主因。
5. `CallMediaSession` 直接转发 WebSocket 消息；端点限制队列无法控制所有 TCP/系统/中继内部排队。增大缓冲只是在卡顿与延迟之间交换，不能消除 TCP 重传队头阻塞。
6. 当前 `CloudMediaTransport.webRTC` 与协商类型属于预留结构；没有实际调用协商器的生产路径，不能把枚举存在描述为已经支持 WebRTC。

## 推荐架构

近期保留现有 Worker/APNs/控制协议，先实施诊断、音频调度与“媒体故障独立恢复”。

下一阶段新增可选媒体通路：

```text
iPhone ── 原 Worker：身份、通话命令、APNs、SDP/会话协商 ── Android
   └────── WebRTC / DTLS-SRTP / Opus / TURN ───────────┘
```

这是针对主项目的建议，不是 fork 当前架构；fork 使用自己的 ECS control/PostgreSQL/TURN，并且模块云端强制 relay 候选，不是已经实现无服务器 P2P 的免费通话方案。

- 不必为移植媒体能力一并迁移用户、短信和配对数据库；但 Worker 需要新的、带通话归属校验的信令与会话接口。
- 现有 Worker WebSocket 端点不是 TURN；需要另有 TURN 基础设施或合适的托管服务。具体供应商/计费本轮未做评估，不能承诺免费额度覆盖。
- Android 需要真正的 WebRTC/Opus 媒体适配，接入 Shizuku 获取的通话 PCM，不能使用默认手机麦克风轨道冒充运营商音轨。Watch 保持旧媒体能力或另行验证，不能假定 iOS 的 WebRTC 依赖支持 watchOS。
- codec/transport 能力须双端协商。回退仅在安全的会话建立边界执行；活动通话不能让旧/新媒体同时持有音频设备或让迟到回调改变通话归属。
- 保留纯本地的 Relay 出口限制；不得因为新增信令/统计又访问 Relay。保持用户手动上传反馈的规则。
- 8 kHz/16-bit PCM 载荷为每方向 128 kbps；32 kbps Opus 的名义载荷约为四分之一，网络封装、VBR/FEC、TURN 和计费口径另算，不能等同于总流量/费用下降 75%。
- 当前三星桥固定 8 kHz。先升级传输可改善抗抖动和带宽，但将 8 kHz 插值为 16 kHz 不会恢复高频；真正宽带需先证明目标 Android 音频路径提供原生 16 kHz。

## 不应直接采用的内容

- 整套 v2 配对/单永久手机/证书与数据库替换，会改变主项目多设备、Watch 和现有配对兼容性。
- 前台 3 秒 presence 窗口抑制 VoIP Push：与主项目近期后台 CallKit 修复存在交互，不属于卡顿优化。需单独验证快速退后台/锁屏边界，不能顺手加入。
- 当前 fork 只为 active 通话启动媒体；不支持主项目现有受认证和短租约约束的接通前只收音频语义。迁移必须另外设计 recv-only→duplex，不提前采集麦克风或启动接通计时。
- Fork 单媒体会话最多 30 分钟，且当前恢复不使用 ICE restart 而是完整新会话；长通话续租/换网恢复成本需要重新设计和验收。
- Fork 的 SCHED_FIFO 调用未检查返回值，可能退回普通调度；其文档也明确实时优先级变更后的停顿尚待下一次真机通话验证。不能承诺设置后必然不卡。
- LC3 是它的历史中间路线，最新实现已切换 Opus；不建议同时引入两套新 codec。

## 其他可借鉴功能

- 媒体重连保留静音和听筒/扬声器/外部音频路由；适合主项目单独补充回归测试。
- 后端 SMS 存储满时只清理已解码的完整旧消息，保留分片/异常/本轮新到；六位短号和 PDU 用例值得 U30Air 端参考。其 EG25 AT 逻辑不适用于直接移植三星 SMS Provider；转发“已读到”也不等于所有客户端可靠落盘，回收前需定义持久化确认。
- 固定错误阶段/错误码、只读诊断、崩溃自启动/原子回滚可参考，但不连带部署其服务、改名或复制环境配置。
- 源端序号回绕、乱序、欠载、会话替换、旧 helper 退出等自动化夹具很值得移植，且比仅调节几个毫秒参数更可靠。

## 验证结果与未验收项

本轮在独立审阅副本实际执行：

```sh
go test ./internal/cloud \
  -run 'Test(Jitter|Paced|StreamMedia|MediaOutlives|RunMediaThroughRelay|LocalMediaStats|MediaOwner)' \
  -count=1 -timeout=90s -v
```

14 个顶层用例通过（40.116 秒，不含下载/编译），含 TURN UDP/TCP 回环双向数据、控制断线媒体保持、新会话替换旧会话、首个失败原因、统计、序号回绕、FEC 选择和缓冲回落。这里的 FEC 测试验证取下一包交给 decoder 的决策，不是对真实运营商声音的音质评分；未运行本轮 iOS 实机/全量 fork 测试，未对麦克风或真实电话做操作。

Fork 自述的实机依据是 EG25 与 iPad mini 约一分钟双向来电，报告入站丢包约 2.9%、iPad 缓冲约 205 ms，以及模块调度停顿。它同时列出去电、长通话、锁屏、USB、控制断线恢复及实时调度后复测等未验收项。属于对方报告，未由本轮重现，不能推广为三星/U30Air或全网络环境已验证。见 [WebRTC 音频说明](https://github.com/CmST0us/AirSIM/blob/aafb2036e40bcebf6452531f4020ef6fe3931da9/docs/WEBRTC_AUDIO.md)。

后续最低测试矩阵：相同设备/路由/蜂窝条件下记录首音时间、每分钟欠载/裁剪、发送与播放间隔 p95/p99、排队时长；合成 1/3/5% 随机丢包及突发丢包、50/100/200 ms 抖动；CPU 压力、Wi-Fi/蜂窝/VPN 换网；分别中断控制和媒体；两端静音、蓝牙耳机、CallKit 后台与用户主动挂断；连续 30 分钟以上通话；U30Air 的早期媒体→接通双向另行验收。真实拨号仍由用户进行。

实施顺序：**诊断与当前 PCM 修正 → 同通话媒体恢复 → 可选 WebRTC/Opus 原型 → 真机对比达标后灰度**。不是整体合并 fork。
