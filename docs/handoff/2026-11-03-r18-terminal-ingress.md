# R18 客户端终态入口调查与候选修复

## 证据与结论边界

用户报告：设备已经返回 ended，iPhone 仍继续计时。U30Air 线程提供的脱敏文件：

- `out/r18-iphone-terminal-trace-safe.json`：2026-11-02 17:22:24.629857Z `/api/events`、17:22:24.648918Z `/api/calls/events` 完成 HTTP 200。
- `out/r18-refusal-identity-evidence.json`：设备 17:22:24.557532919Z 的终态中，backend/canonical ID 与 17:21:49.236310063Z 拨号回执均匹配，state=ended，ended_at 完整。

这些记录证明终态接口网络响应及时到达，不包含手机解码、Registry 接受及 UI 清理事件，**不能独立证明手机已消费终态，也不能证明以下缺陷就是该次实机故障的唯一根因**。用户确认拒接到基带释放另有约 23 秒延迟，由 U30Air 线程继续调查；EARLYMEDIA 不等于拒接或公告内容证据。

## 可复现的客户端缺陷

已有通话通过 canonical WLAN 拨号并保存明确回执后，`LocalDeviceDirectory.metadata` 在重新验证健康信息期间可能返回 nil。此时：

1. 主轮询 `poll` 因 `ownsLocalCallPresentation` 进入本地归属分支，但 `canonicalSource == nil`，不递交通话终态。
2. 即使直接递交给 `applyAgentCallRecord`，该方法也因同一发现信息检查而返回 false。
3. 明确属于当前通话的 ended 被丢弃，生命周期仍 connecting，界面与媒体租约保留，随后手动拨号被 busy 拒绝。

新增 XCTest `testAuthenticatedTerminalSurvivesUnavailableDiscoveryMetadata` 在修改生产代码前已实际执行并失败：终态未接受、界面未关闭、Registry/media 未释放、再次手动拨号 busy。修复前日志 `/tmp/airsim-terminal-regression-before2.log`。这是一项有失败复现的入口缺陷，不是对设备本次未记录状态的猜定。

## 修复边界

- 已取得回执的 WLAN 终态优先使用 Router 保存的归属：匹配 Agent、canonical ID、backend ID、锁定 WLAN 通道；不得以相同号码、空 active 列表或另一个设备的发现记录推断。
- 长轮询开始前优先从锁定通话捕获来源，必须匹配完整 API route（包含配对凭据），不单靠 IP 或发现列表反推设备。
- 不依赖临时健康元数据继续关闭已绑定通话。主轮询先递交终态，随后才处理非终态；旧 active 不能复活已结束记录。
- 不把该入口用于 BLE 锁定通话，不接受无回执或尚待拨号确认的操作。
- 沿用 Registry / onFinish / CallKit / UI 正常清理及一次性提示策略，不发起第二次 dial 或额外 hangup。
- 新增本机 Verbose 诊断：decoded_terminal、decode_failed、router_terminal、receipt_terminal、lifecycle_terminal、presentation_cleared。仅记录端点路径、状态、数量、epoch 和身份是否匹配；不记录号码、实际 call ID、Agent ID、密钥或音频。不增加自动反馈上传。

## 验证与待办

验证结果：

- 修复前的新增 XCTest 实际失败，保留了界面、媒体及 busy 复现证据。
- 第一轮修复后 DeviceCallActionRouterTests：32 项通过。
- 补齐锁定来源后，最终 iOS 27 模拟器执行 DeviceCallActionRouterTests、DeviceCallRegistryTests、DialOperationRecoveryTests，共 **47 项通过、0 失败**；日志 `/tmp/airsim-terminal-regression-final.log`。此次实际执行到 XCTest，不只是编译或原生 host adapter。
- `python3 scripts/tests/r18-call-safety/run.py`：**50 项生产通话策略断言通过**。
- `git diff --check` 通过。

新增回归覆盖健康信息不可用、重复终态、替换电话、错误设备／canonical ID／backend ID、BLE 通道隔离、接通后结束不播失败音，以及相同 IP 下不同配对凭据不能认作同一轮询来源。正常音频的真实双向传输不在这些模拟测试的证明范围内。

本轮没有安装、真实拨号、录音或设备操作，没有改 U30Air 工作树。用户手机仍不能视为已获得这次候选。R18 实机验收仍 FAIL，继续暂停发布；需在后续另行安装后，按双方同一通话时序核对解码 → Registry → lifecycle → presentation 清理，并分别验收立即手动重拨及正常双向语音。

## 2026-11-03 用户授权覆盖安装

本节取代上文“本轮没有安装”的阶段状态。用户明确要求“安装”后，已将 iPhone Air 从 0.9.8（158）覆盖更新至 **0.9.8（159）**，未卸载或清除数据。devicectl 确认安装成功、手机版本为 159，并成功启动主 App。

主 App、小组件和内嵌 Watch 包的 build 均为 159；这不表示手表已独立安装或验收。包含终态入口修复、原请求只读结果查询及新版功能介绍，保留工作树已有改动。构建日志 `/tmp/airsim-terminal-build159.log` 显示 BUILD SUCCEEDED，codesign 深度签名校验通过。安装参数为 CURRENT_PROJECT_VERSION=159，没有创建 Release。主可执行文件 UUID：21F53D93-0CF7-3325-8B28-32F054C12DBC。

仍需用户手动测试拒接后收尾、一次提示、明确手动重拨、正常双向语音及主动挂断。基带释放前的延迟需单独记录；运营商早期媒体仍未验收。安装成功不等于实机通话修复已通过，R18 继续暂停发布。
