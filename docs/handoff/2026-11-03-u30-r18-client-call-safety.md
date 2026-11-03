# U30 Air R18 / AirSIM iOS 通话终态与拨号安全交接

> 最新实机反馈：设备终态到达后 iPhone 仍计时，验收 FAIL，R18 暂停发布。客户端终态入口缺陷复现与候选修复见 [终态入口调查](2026-11-03-r18-terminal-ingress.md)，不能将此前自动化通过解释为实机已修复。

> 最新状态（2026-11-03）：用户要求取消两分钟限制后，U30Air 已在 `ce198d0` 移除同号码冷却。设备线程的 `out/r18-no-cooldown-installed-status.json` 记录 `installed=true`、`released=false`、`manual_acceptance=pending`。本线程只读核对代码、安装记录与设备线程进度，未另行操作 USB。原通话确认结束且基带空闲后，可用新的人工拨号意图立即重拨；原 operation ID 持久去重仍保留。下文涉及旧候选“保留两分钟保护/未安装”的描述属于此前阶段。客户端新增只读恢复仍未安装，early media 仍未实现。

本轮仅修改 `/Users/kyle/.codex/worktrees/voble/AirSIM` 的 iOS 客户端、测试与本文档。保留既有未提交改动。没有修改 U30Air 工作树，没有真实拨号、短信、录音、设备安装、重启、Worker 部署或 Release/TestFlight 发布。R18 仍暂停发布。

## 基线与证据边界

用户手机为 AirSIM 0.9.8 (158)，`docs/widgets.md` 有该 build 的安装记录。当前脏工作树不是已安装二进制的完整可复现快照：本文记录当前源码路径与本轮验证，不能证明已安装 158 的每一行源码。

只读参考：U30Air `/Users/kyle/codex project/U30Air/out/openwrt-sms/docs/R18_REDIAL.md`；交接提供 HEAD `45ec46c`，固定 Agent 基线 `cc2ade3124ac34bec7d8c441f4b66a57a6dfec62`。没有与对端拒接瞬间同步的客户端/基带采样，不能把全部延迟归因于 iOS。

## 当前路径及修复

- App 拨号：`AppModel.dial` → `CallKitController.startOutgoingCall` → `callKitStart`。纯本地模式直接调用后者。标准本地双通道经过 `DeviceCallActionRouter`，先锁定 Agent/通话身份，再提交一次拨号。云端只允许在发送本地拨号之前选定。
- 通用 `OutgoingCallRouteCoordinator` 原先允许非 API 类型错误（包括超时）之后再拨云端，原测试甚至要求该行为。本轮删除此回退：一旦调用本地 `dial`，任何错误都不能触发另一路 `dial`。这是一项明确代码风险，不等于现场重复拨号来源已被抓到。
- 旧 `AirSIMAPI.dial` 也带 operation ID；取消“同号码恰好正在拨号就当作本请求成功”的无身份恢复。后台 CallKit 与 Watch 请求保留各自原始 UUID/request ID。
- 一次 App 点击的 UUID 同时作为 CallKit UUID、本地 `operation_id` / BLE operation ID，或云端 command ID。CallKit 重复回调与并发调用在任何 await 前经过意图门禁。失败/未知结果不释放同一个 ID 的执行资格；只有新的明确点击/系统呼叫动作产生新意图。已确认终态可以释放在途门禁，晚到旧请求的 defer 不会释放新请求。
- 旧协议 `LegacyAgentPoller` 不再先等短信状态才交付通话终态。AppModel 在历史合并/ACK 前应用终态；目录订阅也先发布通话事件再存历史。历史 await 后再次核对生命周期快照，防止操作旧快照覆盖新电话。
- `ended_at` 或明确 `state=ended/failed` 都可表示终态；设备时钟落后于 App 的乐观状态时，同一 UUID/ID/generation 的可信终态仍可收尾。非终态旧快照仍被拒绝。不同电话的终态不能终止当前电话。
- 接受终态立即取消音频启动任务、停止 PCM/等待音、停止显示计时、清理媒体占用并结束匹配的 CallKit/UI。多设备路径先清除 presentation key 再通知 CallKit，避免其同步回调重入 Router。
- 未接通的呼出收到可信终态时只播放一次短双音，文字为 **“呼叫未接通，通话已结束。”**。主动取消、已经接通、重复结束、替换电话后的旧事件不播；不合成“暂时无法接通”，不从单纯 `ended` 推断拒接/忙线/无人接听。

## 后端两分钟保护与替代协议要求

现有 R18 的同号码两分钟保护保留。客户端没有改号码、变换参数、循环重试或自动更换 ID 绕过保护。当前立即人工重拨仍可能被后端拒绝。

后端要取消粗粒度时间限制，必须先与客户端协同验收以下语义：

1. 对 `(配对身份/客户端身份, operation_id)` 持久去重；在执行 ATD **之前**保存占位及参数摘要。进程崩溃或响应丢失不能让同一意图再执行 ATD。
2. 同 ID、同参数返回同一通话回执/最终状态；同 ID、不同号码或 SIM 返回冲突，不执行。超时是“结果未知”，不能自动视作“未执行”。
3. WLAN、BLE、Relay 路由须使用同一意图语义；本客户端在提交后根本不换路执行。旧客户端、其他入口仍须安全处理。
4. 回执至少绑定 operation ID、Agent ID、backend call ID、canonical/Telecom ID；保留现有 `AIRSIM-DIAL1` 签名绑定。结束事件必须指向原通话；不能用电话号码、槽位或“当前通话”替代身份。
5. 新 ID 本身不是人工点击的证明。需要结合客户端入口代码/计数追踪、后端持久去重和双方时序证据验收后，再决定是否移除保护；不要仅凭新 ID 放行。
6. 若要恢复未知结果，增加按 operation ID 的只读状态查询，返回同一已签名回执；不能通过“同号码当前存在通话”推定归属，更不能重新发送拨号来探测。

## early media v1：客户端已集成、后端未验收

这是新协商协议，不是声明现有 U30 已支持。仅对配对、已鉴权、已取得拨号回执的 canonical WLAN 呼出启用探测；BLE、云端、无身份的旧 PCM 保持现状。未提供端点/有效授权时继续本地等待音。探测不阻塞拨号或终态；后续已加入有上限的 202 等待与租约续期，完整当前契约见 [早期媒体联调说明](2026-11-03-early-media.md)。

### 控制端协商

客户端用现有 VoWLAN HMAC 请求签名发送只读请求：

```
GET /api/calls/early-media?call_id=<URL encoded backend call ID>
```

同一已配对 Agent 的控制地址，3 秒请求超时；不接受响应中指定任意媒体 URL/主机/端口。缺失能力可返回 404/409/501。支持端返回 JSON：

```json
{
  "version": 1,
  "agent_id": "paired-agent-id",
  "call_id": "exact-backend-call-id",
  "session_id": "unique-per-call-media-session",
  "expires_at": 1793664000,
  "state": "early_media",
  "direction": "recvonly",
  "format": "s16le-8000-mono",
  "proof": "base64url-hmac-sha256"
}
```

`expires_at` 为后端 epoch 秒，示例需换成实时值；客户端使用配对 clockOffset 校时，授权必须未来有效且不超过 30 秒。身份与字段不许包含换行；session ID 长度不超过 128 字节。proof 使用配对密钥，签名原文为以下 UTF-8 内容（各字段 LF 分隔，最后无 LF）：

```
AIRSIM-EARLY-MEDIA1
<此次 GET 的 X-AirSIM-VoWLAN-Nonce>
<agent_id>
<call_id>
<session_id>
<expires_at 十进制>
early_media
recvonly
s16le-8000-mono
```

后端必须仅为当前仍属于该配对方、未接通且具备真实下行音频的同一通话签发，不得因为收到探测就重拨、接听或改成 active。客户端验证 proof、nonce、Agent、通话、有效期及所有固定参数；未通过则不打开音频。

### 独立 PCM 握手与权限

使用配对端点原有 PCM 端口，但握手版本独立，禁止降级成旧双向 `AIRSIMVWL1`：

```
AIRSIMEM1 <timestamp> <nonce> <signature> <base64(binding)>\n
```

binding 原文（LF 分隔，最后无 LF）：`agent_id / call_id / session_id / expires_at / recvonly / s16le-8000-mono`。以上斜线表示字段分行，不是原文字节。signature 使用现有 `VoWLANRequestSigner`，method=`PCM`、path=`/v1/pcm/early-media`、body=binding UTF-8、全新 timestamp/nonce。后端需要验证时钟窗口、防 nonce 重放、授权仍有效、会话归属和当前 call ID，再返回已有 `AIRSIMREADY` ACK 与 S16LE/8kHz/mono 下行 PCM。

- 不允许此握手启用麦克风或接收上行音频；后端也必须拒绝非预期上行数据。
- 客户端不请求录音权限、不创建 input node/tap，网络传输对象也直接拒绝 `sendPCM`。只启动播放器输出。
- Lifecycle 保持 connecting，不上报 CallKit connected，不启动接通计时。
- 到期/终态/替换电话关闭下行。收到真实 active 后关闭早期会话，再走原有麦克风授权、双向音频注册与握手；旧授权不能带到新通话。
- 每份授权最多 30 秒；后续客户端支持同 session 有效续期、独立到期停止，无有效续期时回到本地等待音。不能承诺每次拒接都有运营商公告。
- 待 U30Air 实现此端点、签名授权、receive-only PCM 会话和基带真实早期音频源，之后单独做声音验收。仅修改当前 active-only 的后端判断不够。

## 自动化与实际验收

- `python3 scripts/tests/r18-call-safety/run.py`：从生产源文件选择 Foundation/CryptoKit 声明直接编译运行，41 项断言通过。覆盖时钟偏差终态、重复/迟到/替换事件、正常 active→ending→ended、同意图单次提交、独立人工意图、超时不换路、预热后取消不再提交、提前交付旧协议终态、early media 的签名/nonce/身份/过期/方向限制。
- iOS Debug 设备目标构建通过（仅构建，未覆盖安装），日志 `/tmp/airsim-r18-client-build-2.log`。后续最终构建记录见下。
- 新增 iOS 集成回归：`DeviceCallActionRouterTests.testR18RemotePreconnectEndStopsPresentationAndCuesOnlyOnce` 和 `testR18LocalCancelDoesNotPlayFailureCue`；原“超时转云端成功”测试替换为“超时不重拨”。模拟器执行结果单独记录，不能把编译通过写成测试运行通过。

待用户真实测试（不能以模拟断言代替）：

1. 同步记录对端拒接时间、Agent ended/revision 到达时间、iPhone 收尾时间，核对一次提示、无第二通。
2. 终态后立刻人工重拨：`ce198d0` 已移除两分钟冷却，需确认设备实际空闲后能立即拨出，且原请求重放不会再次拨号。
3. 正常接听、双向声音、计时、主动挂断；本地/云端各测，不得串到下一通。
4. 网络超时/切换时确认设备只有一次 ATD，客户端不自动换路；迟到响应不重开界面。
5. early media 单独测真实公告、无麦克风上行、未 active 不计时、终态即停止；旧设备无能力时正常等待及接通。

### 集成运行记录

- 首轮 3 项定向 iOS 测试实际运行通过：`/tmp/airsim-r18-client-regression.xcresult`。
- 扩展回归首轮 55 项出现 1 项失败：终态取消被标成 callChanged 而非 callNotActive；已修正检查优先级，不放宽测试断言。随后 56 项（通话路由、迟到响应、媒体注册/取消、正常 BLE 呼出等）全部运行通过，结果 `/tmp/airsim-r18-client-final-regression.xcresult`。
- 上述模拟器测试仅使用 fixture，不是真实蜂窝拨号。它们验证客户端状态归并/动作次数，不能证明 R18 硬件已实现公告或解除手动重拨限制。
- 最后补充的旧接口稳定 operation ID / 不凭同号猜测成功、云端失败保留目标、结束音/主动取消 4 项测试全部运行通过：`/tmp/airsim-r18-client-legacy-and-tone.xcresult`。有限提示音有 650ms 自动会话清理，并在新通话开始时取消旧音效清理任务。
- 最终原生策略回归：41 项断言通过；`git diff --check` 通过。源码仍在 VoBLE 工作树，未提交或推送；没有将本次编译产物宣称为用户已安装的 158。
- 最终 iPhone/arm64 Debug 目标构建成功（包含上述最后补充修正）：`/tmp/airsim-r18-client-complete-build.log`，仅编译及签名，未安装。

## 后续授权安装：2026-11-03

用户在源码修复完成后明确要求“安装到 iPhone”。已将最终 Debug-iphoneos/AirSIM.app 覆盖安装到“楷的 iPhoneair”，未卸载应用，并成功启动。devicectl 安装与启动均返回成功，设备查询显示 `com.eric3u.airsim`、版本 `0.9.8`、build `158`。本地测试包沿用 158，不能仅凭版本号区分此前安装包；本次来源为上述 final 构建日志对应的修复产物。未操作 U30Air、未发布，真实通话验收仍待用户执行。

## 后续只读操作恢复

U30Air 候选 `8041906` 提供完整状态签名协议后，客户端继续接入原操作的只读恢复，详见 [2026-11-03-r18-client-operation-recovery.md](2026-11-03-r18-client-operation-recovery.md)。该后续客户端代码与设备新增持久回执候选均尚未联合安装验收，不属于上文已覆盖安装的那份 158。两分钟保护和 early media 阻塞状态不变。
