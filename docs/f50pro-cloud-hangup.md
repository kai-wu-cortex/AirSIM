# F50 Pro 云端远端挂断同步

日期：2026-11-17。基于 Android 0.9.8.25（140）的本地签名 F50 兼容分支，配套用户已安装的 iOS 0.9.8（176）。这是未发布候选，不是作者的新正式版。

## 问题与改动

现场香港卡云端通话双向声音正常，远端挂断后 F50 Telecom 已记录 ended，iPhone 仍显示等待 Agent 控制通道恢复。源码中 HTTP `/v2/events/call-state` 只保存生命周期并更新 Live Activity；关闭 Android 媒体 socket 本身不会发送 iOS 所需的终态控制。

仅在已匹配本通 Android 通话 ID 的 ended 事件到达后，使用已有、已认证的媒体 WebSocket 发送 `status=ended` 及原 call_id、call_uuid、generation；发送在 HTTP 请求之前。其他通话的迟到事件、普通连接丢失、服务关闭均不能产生此消息。写失败保留原 HTTP 重试与关闭逻辑，不新建会话、不绕过认证。iOS 176 已支持该消息，无须更换作者的 iPhone 签名或 Relay。

## 验证

新增实际媒体管理器边界测试：另一通/非终态不发 ended；完整身份；终态先于 HTTP 和关闭；HTTP 失败后仍先通知且后续重试可清理；socket 写失败不阻止 HTTP/清理；普通 close 不声称远端挂断。

本地 Android 单元/回归、CloudTelecomControlTests、CloudCallManagerTests、CloudOutgoingObservationTests、网关生命周期、owned-dial、pure-local 集成均通过。Standalone 测试脚本最末步骤因 PATH 缺少 apkanalyzer 退出 1；使用本机 SDK 的绝对路径单独补跑相同 manifest 验证通过，未把原脚本记为退出 0。APK 构建与签名核验通过。

已保留数据覆盖安装到装有香港和英国 SIM 的原机：新旧 APK 证书一致，配对设置摘要安装前后一致，安装后 APK 回读 SHA-256 匹配。候选 APK：`ccbc903c6c08d372d19b3848c9646fc198371de0447bc4943595e7357693d75a`。版本号仍为 0.9.8.25（140），通过摘要区分本地候选；另一台设备未更新。

现场日志在 2026-11-17 09:05:39.392 UTC 记录原生 ended，09:05:40.256 UTC 记录终态控制已发送（约 0.86 秒）；用户随后确认 iPhone 在对方挂断后正常自动结束。该证据覆盖本次香港卡外呼，不能泛化为来电、Watch、断网等全部场景。

英国 CMLink 卡已由用户放在普通手机验证可注册、通话和收发短信，放回 F50 后卡槽已加载但仍无服务。不能再以卡本身无法漫游解释；F50 的网络/IMS 兼容问题尚未解决。

## 安装和回退

仅覆盖安装与目标设备原 APK 签名完全一致的构建。先备份当前 APK，核对包名、签名、版本及新包摘要，再 `adb -s SERIAL install -r APK`。保留所有配对、Wi-Fi、USB ADB 及默认电话恢复设置。恢复旧 APK 同样保留数据，不卸载或清除数据。诊断日志不记录音频、完整号码、短信或密钥。

最终候选重启复验（2026-11-17）：ADB 可读设备采样 18 次、覆盖启动后 25.96 至 214.82 秒，两卡均 LOADED，所有可读双卡值均为 1，香港卡已注册，英国卡仍无服务。配置服务状态、默认电话恢复、控制桥和本次启动后的云端命令连接通过；USB ADB 写入/读回通过。此轮是接 Mac 的正常重启，不能替代独立电源冷启动。
