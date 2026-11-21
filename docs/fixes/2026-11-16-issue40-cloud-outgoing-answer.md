# Issue #40：Standalone 云端呼出媒体确认

日期：2026-11-16。基于 `develop` 工作树，保留已有短信、Relay 和 iOS 未提交修改。

## 原因与复现

Issue：https://github.com/kai-wu-cortex/AirSIM/issues/40

iPhone 云端呼出调用 `IPhoneCloudCallSession.answer(outgoing)`，先提交 HTTP `call_control/answer`，再以同一 command ID 在媒体 WebSocket 上确认。Standalone 原先将两条入口都转入系统来电接听逻辑；Telecom 处于 DIALING 时返回 `IllegalStateException: call is not answerable`。网关缓存该失败，后续 ACTIVE 状态也无法通过相同 ID 恢复。

新增测试在修复前调用真实 StandaloneAgentGateway、StandaloneCloudMediaManager、CallRepository，复现了完全相同的错误。替换的是 Android 系统边界及网络传输，不是真实电话。原有早期媒体测试直接设置 mediaStarted，未覆盖这个入口，本次改为通过真实控制消息启动。

## 修复方案与实现

- 单独处理云端 `answer`，不改变拨号、短信、DTMF、结束命令的既有缓存执行路径。
- 使用 Agent 已持有的通话描述解析方向，并校验 call_id、call_uuid、generation。忽略控制消息自报的方向，不按“当前任意电话”选择目标。
- 呼出在 CONNECTING、SELECT_PHONE_ACCOUNT、DIALING、ACTIVE、HOLDING 时可以确认媒体准备；不会调用 Telecom.answer，不修改电话状态。结果为 `media_prepared: true`，不伪装成 `answered: true`。
- Telecom 创建事件尚未绑定时返回 `call_not_ready`。同一 ID 后续可重新读取状态，允许 HTTP 首次未就绪后由媒体通道恢复；不重新执行拨号。
- 呼入仍执行原接听逻辑。已执行但结果未知时保存结果，不盲目重发系统接听；之后观察到同一电话 ACTIVE/HOLDING，可无副作用确认成功。
- answer 意图绑定完整通话身份；同一 command ID 不允许改通话、generation 或改成其他动作。缓存有界，最多 128 条。
- 尚未确认的意图保留最早 expires_at，重试省略或延长该字段不能绕过有效期。已经确认且仍有效的同一通话允许恢复媒体，即使命令执行期限已过；这是兼容 iPhone 在整通电话中复用 answer ID，不是允许再次接听或恢复已结束电话。
- 失败与成功重试都检查当前通话状态。DISCONNECTING、DISCONNECTED、移除、身份不匹配、纯本地策略或失效配置拒绝处理；媒体循环在 ACK 后再次检查 socket、通话状态和 Relay generation，防止旧成功结果重开媒体。

## 兼容与安全边界

继续使用现有 `answer` 控制消息及 `answer_ok` 状态，无需新增客户端命令。`answer_ok` 只确认媒体准备，不代表运营商接通。原 PCM 状态门控保留：早期媒体须协商能力且仅下行，真实 ACTIVE/HOLDING 才开放双向媒体。缺少 early_media_version 的旧客户端仍不能启动早期媒体。

HTTP 命令持久化记录的 failed 是历史结果，Relay 不会被本次改动自动重新打开；恢复依据现有 iPhone 的媒体 WebSocket 有界握手重试。不能将 Relay 中所有 failed 改成自动重执行，否则可能重复拨号或发送短信。

本次只修改 Android Standalone 云端命令/媒体确认和测试。没有修改 iOS、Worker、独立 AVF 或 U30Air Agent 的协议；之前这些目录里的未提交内容不属于本次修复。实际使用修复需更新 Android Standalone。未安装、未部署、未提交、未发布。

## 自动化验证

- `sh android/phone-control-app/test.sh`：通过，含短信兼容、防重复、只接收 PCM 拒绝上行等既有回归。
- `sh android/phone-control-app/test-cloud-call.sh`：通过，运行 CloudCallManagerTests 和 CloudOutgoingObservationTests。
- 新增/扩展覆盖：DIALING 媒体确认不调用接听；等待绑定后同 ID 从 HTTP 失败转为媒体成功；正常呼入只接听一次；未知结果不重复接听且后续 ACTIVE 可确认；错误身份/generation、过期、纯本地/旧配置拒绝；成功后挂断/移除拒绝迟到握手；重复握手只启动一次 PCM；长通话重连；旧客户端不启用早期媒体；真实握手后先 RX01 下行再按 Telecom ACTIVE 切换 PCM1 双向；原有拨号去重与结束不复活。
- Standalone Debug 全量编译、DEX、签名及 `verify-apk.sh`：通过。
- `git diff --check`：通过。

构建包：`/tmp/airsim-issue40-standalone-build/AirSIM-Standalone-Issue40-debug.apk`。这是包含当前工作树既有修改的本地测试包，不是独立发布快照；没有递增发布版本。

测试日志：`/tmp/airsim-issue40-before.log`（修复前复现）、`/tmp/airsim-issue40-regression.log`、`/tmp/airsim-issue40-core.log`、`/tmp/airsim-issue40-build.log`。

## 待真机验收

1. 使用现有 iPhone 与新版 Standalone，云端呼出；确认不再停在“模块未确认接听”，早期音频不提前计时或打开麦克风上行。
2. 正常接通双向讲话，再双方分别挂断；确认无第二通自动拨号。
3. 呼入接听、拒接、未接，以及呼出拒接/挂断后的迟到网络消息，确认不复活通话。
4. 通话超过命令有效期后模拟媒体断开重连，确认恢复的是原电话，不产生新的系统接听/拨号动作。
5. Pixel 6 等反馈机型仍需用户实测；自动化测试和作者报告均不等于本次已经实机验收。
