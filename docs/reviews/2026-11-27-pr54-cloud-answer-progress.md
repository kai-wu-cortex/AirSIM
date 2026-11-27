# PR #54：云端接听进度的选择性整合

## 基线与范围

- develop 基线：`82787f600e00e0c53ba61bd26b2b48227718a190`。
- PR #54 审阅版本：`52355ed87b91c207afb6acd1757e520aa1bac1ae`。
- 原 PR 包含 #52（`950737419c492052a2c2b51a4ffe604fb8910e9c`）。本次从二者差异中选取 #54，并修正其接线与失败判定；不直接合并整个 PR 分支。
- 不引入 #52 的局域网等待策略、CallKit accepted-answer 回调或 Watch answered-on-phone 同步。保留当前 develop 的自动选路、冷启动接听、通话身份与联系人显示。

## 最终行为

1. 实际选择云端并开始接听后，App 内显示连接云端、等待设备、设备接听、连接语音四个阶段，以及等待时间。前三阶段各 10 秒，等待首个本地播放回调阶段 15 秒；重复回执不延长当前阶段。
2. HTTP 提前接听与媒体 WebSocket 并行。单次 HTTP 429／5xx 只记录诊断证据，保留 WebSocket 的完整等待窗口，不提前终止另一条正在成功接听的通道。
3. `answer_ok`、`active`、`pcm_first_frame` 只说明设备或桥的状态。完成进度、记录耗时须收到 iPhone 音频播放器的下行播放回调；这证明本地下行开始播放，不等同于双向通话验收。
4. 失败任务绑定 agent ID、call ID、UUID、generation；替换通话、取消和旧回调都不能结束新通话。最终清理还检查当前云端会话和系统 CallKit 所属通话。
5. 不改写 CallKit 来电姓名。失败后提供中文 App 状态和本地通知；音频故障建议检查设备音频桥及权限，不预设所有机型都使用 Shizuku。
6. Android Standalone 在真正接听前对本地 PCM 监听器做最多三次有限探测。探测只检查 TCP 可达性，不发送或记录 PCM。等待后重新检查命令期限、配置与原通话状态。桥不可达时不接起运营商通话，返回 `audio_bridge_unavailable`，媒体通道发出 `answer_unavailable`。
7. Watch 识别新的拒接原因，但要求消息包含当前接听的完整身份；迟到的拒绝不会结束已经 active 的通话。既有本地媒体失败处理保留。

## 协议与兼容

`answer_unavailable` 沿用原媒体 WebSocket 状态封装，携带 `call_id`、`call_uuid`、`generation` 和错误原因；不新增 REST 接口或改变 Relay／Worker 报文格式。本仓库云端服务无需随此次修改部署。

旧 Android、AVF、U30 Air／MU300 不必为了 iPhone 进度展示升级协议；缺少新拒绝状态时，iPhone 仍由现有回执和实际播放／超时判断。它们没有本次 Standalone 的接听前监听器探测，不能把这一能力视作已在这些 Agent 上实现。

## 验证

- Xcode iPhone／Watch `build-for-testing` 成功；Watch 身份过滤补充后再次编译成功。
- XCTest：`AirSIMTests`、`DeviceCallActionRouterTests`、新增 `CloudAnswerProgressIntegrationTests` 合计 **205 项通过**，含 9 项新的接听进度与所有权回归。
- 直接编译生产进度模型的 smoke：**42 条断言通过**。
- 直接编译 Watch 生产策略的 smoke：**354 条断言通过**。
- Android `phone-control-app/test.sh`、`android-standalone/test.sh` 通过；新增探测后状态复核的五种情况后，重新编译运行 `test-cloud-call.sh`，通话管理与呼出观察测试通过。
- 完整 Android Standalone Debug APK 构建及签名校验成功；未安装。
- `git diff --check` 通过。

尚未在实体 iPhone／Watch／Android／MU300 上拨号验收。仍需手动覆盖：锁屏冷启动、HTTP 故障但 WebSocket 成功、桥未启动、正常双向通话、快速挂断后再次来电，以及 VoWLAN／VoBLE 选路保持不变。
