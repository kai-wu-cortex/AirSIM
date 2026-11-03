# R18 客户端只读拨号恢复（2026-11-03）

> 最新实机反馈：设备终态到达后 iPhone 仍计时，验收 FAIL，R18 暂停发布。客户端终态入口缺陷复现与候选修复见 [终态入口调查](2026-11-03-r18-terminal-ingress.md)，不能将此前自动化通过解释为实机已修复。

> 最新状态（2026-11-03）：用户要求取消两分钟限制后，U30Air 已在 `ce198d0` 移除同号码冷却。设备线程的 `out/r18-no-cooldown-installed-status.json` 记录 `installed=true`、`released=false`、`manual_acceptance=pending`。本线程只读核对代码、安装记录与设备线程进度，未另行操作 USB。原通话确认结束且基带空闲后，可用新的人工拨号意图立即重拨；原 operation ID 持久去重仍保留。下文涉及旧候选“保留两分钟保护/未安装”的描述属于此前阶段。客户端新增只读恢复仍未安装，early media 仍未实现。

承接 U30Air 本地候选提交 `8041906` 的 `docs/handoff/2026-11-03-r18-device-call-safety.md`，并只读核对了 `internal/gateway/operations.go` 的实际签名代码。此次仅修改 AirSIM VoBLE 工作树的 iOS 客户端和测试，保留原有改动。

## 部署状态必须分开说明

此前 AirSIM 的终态/防自动重拨修复已按本线程用户授权覆盖安装到 iPhone Air，沿用 `0.9.8 (158)`。**本次新增 operation 查询恢复代码尚未安装。** U30Air 交接说明设备仍为 `45ec46c` 候选，新增持久回执候选 `8041906` 尚未安装；客户端未另行验证或操作该设备。没有提交、推送、Release/TestFlight、真实拨号、短信、录音或设备重启。

R18 继续暂停发布。同号码两分钟保护仍保留；Relay/WLAN 配对身份未可靠统一，不能宣称跨路由持久去重已完成。early media 仍未在 U30 实现，404 和拒绝 `AIRSIMEM1` 应安全回退，不能宣称运营商公告已经可听。

## 客户端入口

`AppModel` 已认证目录 → 带固定 Agent ID 的 `WLANDeviceCallBackend` → `AirSIMAPI.dialOwnedCall`。

一次原 POST 的结果未知（网络异常、HTTP 5xx、损坏/不可信回执）时：

1. 仅在拥有原配对 Agent ID 时，在原地址、原凭据上查询一次：`GET /api/calls/operation?operation_id=<原操作 ID>`，请求超时 3 秒，使用全新 nonce 和原 VoWLAN HMAC。
2. 不重发 POST、不更换 operation ID、不修改号码/SIM、不切换 Relay，也不根据同号活动通话认领结果。取消请求和明确 4xx 拒绝不触发恢复查询。
3. 查询 404/超时/401/503 等失败不证明原拨号未执行；保持错误结果，不触发重拨。不用新 nonce 重试该状态查询的 401，因为响应 proof 必须绑定发出的具体 nonce。
4. 缺乏可信 Agent ID 的旧接口、后台旧接口与旧 Watch 路由仍不自动认领未知结果。现有稳定操作 ID 保留，但不能虚构认证能力。

## 响应验证

`DialOperationStatus` 精确解析设备文档字段；`VoWLANHealthProof.verifyOperationStatus` 在返回调用方之前执行：

- `version=1`；Agent ID 必须等于发出原请求时的配对 Agent，operation ID 必须等于原意图。
- 状态只接受 `confirmed / unknown / rejected`；call_state 只接受 `unknown / dialing / alerting / active / held / ended`。
- ID 长度最多 128 UTF-8 字节，非空且无 CR/LF/NUL；结束时间最多 64 字节、无 CR/LF/NUL，`ended` 时必须有可解析的 ISO8601 时间，其他状态不得有结束时间。
- unknown/rejected 不能带通话身份或旧拨号 proof，call_state 必须为 unknown。
- 首先验证完整 `status_proof`（配对密钥 HMAC-SHA256，base64url），原文按 LF 拼接这九个字段：`AIRSIM-OPERATION1`、本次 GET nonce、agent_id、operation_id、status、android_id 或空、backend_id 或空、call_state、ended_at 或空。没有额外追加 LF；最后字段为空时分隔符自然成为末尾 LF。
- confirmed 还必须验证同一 nonce 下原有 `AIRSIM-DIAL1` operation_proof。仅有旧拨号 proof 不足以信任现态。

## 归并行为

- confirmed + dialing/alerting：恢复同一回执身份的 connecting，不执行新的拨号。
- confirmed + active/held：按认证的真实状态恢复原通话；旧终态/已替换身份不能被重开。
- confirmed + ended：终止准确的原路由、释放媒体和 UI，最多一次通用未接通提示；不新建一通“正在连接”的电话，也不发送多余挂断。
- confirmed + unknown 或 status=unknown：提示“拨号结果尚未确认。未自动重拨，请先检查设备通话状态。”不启动媒体或伪造通话 ID。
- status=rejected：提示设备确认未执行；不会自动重拨，也不绕过保护。
- Router 明确区分设备确认终态与客户端错误清理：后者为 app 来源，不播放“远端已结束”提示；尚未确认身份的临时意图不写成后端已结束通话记录。
- 接收回执后先归并认证状态，再重放已有事件。晚到终态不能结束替换电话；已终止回执迟到时不再向设备发送挂断。

## 自动化验证范围

新增 HTTP fixture 覆盖：原 POST 超时后仅 GET 查询；恢复 dialing/active/ended 的原身份；unknown、rejected、confirmed+unknown、旧端点 404、查询超时与 401；缺少 status_proof、修改 call_state、错误 nonce、错误 Agent/operation、坏拨号 proof、unknown 携带 ID、ended 缺失日期、未知枚举、换行注入、未知版本；明确拒绝/无配对身份不查询。测试使用模拟传输，不访问真实号码或设备。

新增 Router 回归覆盖：认证 ended 回执立即收尾而无额外命令；未知提交仅清理本地界面、不伪造远端结束/历史。继续执行原有 Router 与音频启动/取消回归。

原生策略脚本直接提取生产 Foundation/CryptoKit 声明运行，增加与网关九字段格式、末尾空字段、双 proof、身份/nonce 绑定一致的断言。它不替代 AVAudioSession、CallKit 或基带联调。

执行结果见本文件后续记录。双方新候选尚未联合安装验收；需用户另行安排真实拒接、正常通话、请求丢回复/重启恢复与立即手动重拨验证。不能用 fixture 通过解除两分钟保护。

## 本轮执行结果

- `python3 scripts/tests/r18-call-safety/run.py`：50 项生产状态/签名策略断言通过，包含新九字段 proof 与末尾空字段的线格式。
- `python3 scripts/tests/r18-call-safety/run_operation.py`：4 组 HTTP fixture、22 种响应情形通过。直接选取生产 `dialOwnedCall`、`queryDialOperation`、字段校验与 proof 校验代码，以及同一份 XCTest fixture 方法体；仅用原生 host adapter 替代 URL/transport/trace 接线和 fail-fast assertion 运行器。它不执行 iOS XCTest，不验证 Network.framework 请求签名发送、CallKit 或 AVAudioSession。
- iOS 测试目标成功完成编译；两次模拟器测试宿主均未进入测试用例，已结束本轮挂起任务。**本次新增 UIKit/Router 集成运行不计为通过**；此前其他版本的 56 项通过也不能代替本次执行。日志 `/tmp/airsim-operation-recovery-v2.log`、`/tmp/airsim-operation-recovery-retry.log`。
- 最终 iPhone/arm64 Debug 目标构建通过（包含迟到回复后的 cancellation 检查）：`/tmp/airsim-operation-recovery-final-build.log`；`git diff --check` 通过。
- 客户端新增恢复版本未安装；U30Air `8041906` 未安装的状态来自设备线程交接，本线程没有操作或重新探测 USB 设备。没有提交、推送或发布。
