# 短信“结果尚未确认”发布版本回归审查

日期：2026-11-16。审查 develop / 991162c 及现有未提交短信修复；没有恢复 ANCS，没有安装、部署、发送短信或发布。

## 证据边界

故障截图来自其他用户的手机。iPhone 日志显示 route=vowlan，SEND_START 和 SEND_FAILED 分别为 2026-11-15T20:15:08Z、20:15:09Z，APIError 文案为“短信发送结果尚未确认；为避免重复发送，已停止重试，请先检查收件方”。秒级时间戳不等于精确请求耗时。尚不知道该用户两端版本、权限通道及收件方结果。

用户说上个 TestFlight 正常。此次选择相邻发布标签 v0.9.8.24（iOS 175 / Android 135）和 v0.9.8.25（iOS 176 / Android 140）比较；不能把它们当作已经核实的故障用户版本。自己的三星此前成功记录属于另一笔发送，不能替代故障用户的证据。

## P1：发布版将未启动 Root 误判为可能已发送，阻断正常回退

代码位置：SMSCommandExecutor.execute 的 Root 结果判断；v0.9.8.25 的 RootSmsSender.send 的 ProcessBuilder.start 与 catch。

StandaloneBridgeApplication 总是安装 RootSender。自动权限模式先尝试 Root；仅 Shizuku 才跳过它。发布版 RootSmsSender 在手机不存在 su 时，启动进程抛 IOException，返回 error:IOException。v0.9.8.25 新增 mayFallback 白名单，不接受这个结果，立即返回截图中的文案，后面的 Shizuku/系统路径一次也不会调用。

v0.9.8.24 遇到同样错误会继续下一条发送路径。因此这是确定的跨版本回归，且可以很快失败，无需等待 45 秒回执超时。它符合截图，但没有故障安卓日志，不能确认用户一定命中该分支。若只更新 iPhone、安卓和权限设置完全没变，不能单凭这个 Android 回归解释前后差异。

现有未提交 RootSMSPreflight 修复仍然保留：先做不含短信载荷的 id -u 探测；Root 缺失/拒绝/探测超时归为尚未发送；真正发送进程启动前的失败归为 prepare。启动后未知仍禁止切路径重发。这份修复不在 v0.9.8.25 标签中，仅更新 TestFlight 不能将其带给旧安卓 APK。

## P2：Root 两种发送入口仍未完整接入系统发送回执

RootSmsMain.java:37–43 的 sentIntent 为 null；API 调用返回即输出 ok。ShizukuBridgeManager.sendSms 的 rootTransport 分支也绕过 PrivilegedSmsConfirmation，RootBridgeMain 的 send_sms 使用旧 TRANSACTION_SEND_SMS，不携带逐段发送回执。

影响：Root 返回 ok 不能证明系统已确认发送；调用阶段异常或结果丢失时又无法用迟到的系统成功回执对账，可能出现实际已发送但 iPhone 报未知。它是现存能力缺口，不是本次已证明的 iOS 回归，也不能据此断言截图短信已发出。

后续修复应为两个 Root 入口统一补齐逐段回执、稳定操作身份和结果对账。只在证明未派发时回退；已派发、部分成功、回执缺失都不得通过改 ID 或换路径重发。不要恢复旧版“任意错误都回退”的行为。

## iPhone、SIM 与传输判断

- 对两个标签提取完整 AppModel.sendSMS 方法，5891 字节内容一致，SHA-256 为 b48d9f30c41071ba35515e612423bc6739475bf67aeb0db5a49d56bdadafac5f。
- AirSIMAPI.sendSMS 方法 337 字节内容一致，SHA-256 为 bbec1b043a8b81b689d0f2b1093fa3d6d9a948bd2c394728b19e4c25b3f6d56e。此结论只覆盖这两个函数，不代表整个 iOS 行为完全没变。
- 截图文案由 Android SMSPrivilegedResult.failureMessage 生成，不能单独区分 Root 启动失败、发送后异常、回执缺失等原因。
- bound=false 表示该发送调用未指定绑定 Agent ID，不等于没有配对。SIM 被移除有独立错误文案，截图不是该错误。
- 截图实际走 VoWLAN，不是 Relay 的 SIM 换行格式过滤分支。
- Android Standalone 的 VoWLAN、云端命令及 VoBLE 最终共用 SMSCommandExecutor，故 Root 问题并不局限于一种传输。U30Air 独立 Agent 不属于这份 Android 实现。
- Shizuku 的确认入口等待逐段回执，正常等待上限 45 秒。截图的快速错误优先指向提前失败路径，不宜未经核实解释为普通回执等待超时。

## 自动化验证

在隔离临时目录分别编译两个标签的真实 SMSCommandExecutor，以及当前工作树版本；模拟 Root 返回和 Shizuku 边界，未调用真实短信系统：

| 代码 | Root 返回 | 最终结果 | 后续发送器调用次数 |
| --- | --- | --- | --- |
| v0.9.8.24 | error:IOException | 成功 | 1 |
| v0.9.8.25 | error:IOException | 截图原文错误 | 0 |
| 当前工作树 | error:IOException（仍无法判断阶段） | 未确认，停止 | 0 |
| 当前工作树 | unavailable | 成功 | 1 |
| 当前工作树 | error:prepare:IOException | 成功 | 1 |
| 当前工作树 | error:send_unknown:IOException | 未确认，停止 | 0 |

重新编译并通过 RootSMSPreflightTests、SMSCompatibilityTests：覆盖缺 Root、拒绝、非 root、超时、取消、启动前后错误区别、共享 executor、VoBLE 适配入口、分段回执和禁止未知重发。Android API 29–35 为 JVM 边界模拟，不是各系统真机认证。

临时对照夹具：/var/folders/9l/mjbr42h15y5_pzgb7_gr414h0000gn/T/airsim-sms-release-review-bi5aq25b。

## 处理优先级

1. 将已保留且通过回归的 Root 发送前探测纳入下一次 Android 发布；不要只发 iOS 包。
2. 独立补全 Root 回执协议，并验证发送后异常、迟到回执、多段部分成功及无重复发送。
3. 维持未知结果不重发。若用户仅有 Shizuku 且授权正常，临时选择“仅 Shizuku”可避开第一个缺陷，但不能保证修复所有未知结果。

当前结论是代码回归已复现、故障用户具体分支尚未确认，不宣称其真机问题已修复。

后续：同日已实现 Root 系统回执与旧入口收敛，详见 [修复与验收记录](../fixes/2026-11-16-sms-root-confirmation.md)。上文 P2 描述的是审查时状态；当前未提交实现仍待 Root 真机验收。
