# 短信发送未确认：跨传输排查（2026-11-15）

## 结论与边界

用户报告文本来自 SMSPrivilegedResult.failureMessage，并不等同于未发送或接收方未收到。发送回执（sentIntent）与送达回执（deliveryIntent）不同：Android 官方文档 https://developer.android.com/reference/android/telephony/SmsManager 。本项目等待前者；没有确认时不得重发或伪造成功。

尚未取得故障用户的机型、Android/App 版本、权限模式及日志；无法断言实际命中了哪条原因。Redmi 上 Android 140 的仅 Shizuku 实测通过，不能覆盖所有权限通道和 OEM。

## 共用链路

- VoWLAN：StandaloneAgentGateway → AgentCommandDispatcher → SMSCommandExecutor.execute。
- 云端：StandaloneAgentService 的定向命令 → StandaloneAgentGateway.executeCloudCommand → 同一 executor。
- VoBLE：VoBLEGatewayService → SMSCommandExecutor.sendFromVoBLE → 同一 executor。
- AVF Bridge 的 AgentWatchdogService 也调用同一 executor。U30Air 独立设备 Agent 不属于此 Android executor，不能据此推断。
- iOS AppModel.sendSMS 优先可达 VoWLAN，再已就绪 VoBLE，最后允许的云端；通话连接偏好名称不等于实际短信路由。验收看 send_start 的 route，不仅看设置选项。

## 发现

1. **确定缺陷，已修**：Application 总是安装 RootSmsSender，默认 AUTO 先尝试 su。没有 su 时 start() 抛 IOException，被包装为 error:IOException，不在可安全回退白名单，导致尚未发送就提示未知且阻断 Shizuku/系统路径。Root 授权拒绝可能以 no_result 进入同样路径。
2. **已知未完成能力**：RootSmsMain 的 sentIntent 为 null；RootBridgeMain JSON 路径仍用旧 SEND_SMS transaction6。API 返回 ok 仅代表调用返回，不是系统发送确认；进入发送后异常或输出丢失仍必须保持未知。此次未新增 Root 回执协议。
3. **合理但仍需定位**：Shizuku 的 transaction11 已带 App 创建的逐段回执，等待45秒；回执缺失、只收到部分分段或等待中断仍为未知。之前小米已发出后抛 NPE 的情况可由迟到 RESULT_OK 对账，但其他机型是否回调尚无证据。
4. 系统直接发送等待45秒，超时为另一条文案。系统 send API 后抛异常尚不能像 Shizuku wrapper 一样继续对账，是后续可改善项；不能将所有异常视为确定未发送。
5. VoBLE 等待60秒、VoWLAN HTTP80秒、云端命令结果最长5分钟；这些传输期限不能替代 Android 发送确认。网络断开也有结果回传丢失的可能，应结合双端日志。

## 本次修复

新增 RootSMSPreflight：在写入短信载荷/启动发送进程前，仅执行 su -c 'id -u'，最多5秒。缺少 su、拒绝、非root、探测超时均明确为尚未发送，可沿既有回退链处理。用户选择仅 Shizuku 仍跳过 Root。探测取消不启动下一个发送者。

真正启动发送进程前的异常标记 prepare，可安全回退；启动后异常、no_result、timeout 仍不可回退。未通过更换命令ID、切换链路或重复发送来解决未知结果。Root/Shizuku 未确认日志新增受限原因码，不打印短信正文或号码。

## 验证

- phone-control-app/test.sh 全部通过，包括 Root 探测 absent/denied/非root/timeout、共享 executor 与 VoBLE 适配入口回退、发送后未知不再执行另一 sender、API29–35 与逐段回执等。
- Standalone Debug 完整构建通过，旧 Android Java API 检查通过；临时包 /tmp/airsim-sms-crossmode-build/AirSIM-Standalone-SMS-test-debug.apk。
- 未安装、未发起真实短信、未发布、未改 Worker 或独立 U30Air Agent。原工作树其他改动保留。

## 故障用户所需证据及实测

收集机型、Android/App版本、AUTO/仅Shizuku/仅Root，以及一次用户手动发送时 iOS route 与 Android sms_root_preflight、sms_send_root_unconfirmed、sms_privileged_wait/callback/resolved、sms_send_timeout。无需短信正文、完整号码或密钥。

分别在单链路可用条件下测试三种传输（确认 route）；测试未root+AUTO、仅Shizuku、已授权root；短短信及多段短信；用户核实收达且没有重复。Root真实回执、故障OEM回调及进程被杀后的结果恢复仍待完善/实测，不能宣称本补丁解决所有“未确认”。

## 三星用户手动实测（2026-11-15 12:42，Asia/Shanghai）

三星 SM-F766U / Android 16，从 Debug125 保留数据覆盖更新到含本补丁的 Debug140，AUTO、SEND_SMS 已授权。用户从 iPhone 手动发送，反馈“已发，正常”。

本次发送实际发生于采集基线建立前约14秒；采集窗口内 iPhone 复制曾不可用。随后成功补取两端持久日志，以下不是整个窗口连续采样的声明。

- Android 12:42:28.401：sms_root_preflight unavailable dispatched=false；随后 root_fallback。
- 12:42:28.689：Shizuku dispatch=ok:1，trace=5704cc41。
- 12:42:29.146：segment0 result=-1（RESULT_OK）。
- 12:42:29.147：resolved ok:1 callbacks=1；随后 shizuku accepted segments=1。
- iOS trace 0c17cf5c：route=vowlan，POST /api/sms/send 返回 HTTP200，elapsed877ms；12:42:29.706 记录“短信已发送”、segments1。

这次明确验证了 AUTO 无Root → Shizuku → 系统发送成功回执 → iPhone确认的 VoWLAN 链路。两端时钟未额外同步，不用跨端时戳计算精确网络延迟。未观察到本次重发，但不把发送回执等同于运营商送达回执；用户未单独说明接收方收达。尚未独立实测纯VoBLE、纯云端、多段短信、Root回执或其他机型。
