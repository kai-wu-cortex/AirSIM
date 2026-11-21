# 云端 SIM 标识兼容修复（2026-11-15）

## 原因

Android DefaultCallAccount 使用 ComponentName.flattenToString() + LF + opaque ID + LF + UserHandle.toString()。v0.9.8.25 Relay 的列表和命令校验拒绝所有控制字符，错误地拒绝两个结构分隔 LF。之前测试仅用单行模拟标识，未覆盖真实格式。

## 修复

src/sim-slots.mjs 导出 validSIMAccountID，SIM 列表和 dial/send_sms 命令共用。保持原始字符串和 512 UTF-8 字节上限；兼容单行 opaque ID。多行只接受恰好三段：合法 package/class（含缩写类名）、非空 opaque account ID、UserHandle{非负整数}。拒绝任意换行、CRLF、空段、非法组件/UserHandle、其他控制字符和超长值。label 等展示字段仍禁止控制字符。命令未提供/空字符串仍遵循原默认策略。鉴权、Agent 隔离和同一 command_id 换卡的 409 保护不变。

iOS 自检增加“云端 SIM 确认”，检查绑定 Agent（不能以其他在线设备代替）、列表缺失/为空及已保存所选 SIM 的精确匹配。失败不再显示全部通过。不会在诊断文字中打印原始 account ID 或号码；无卡槽元数据的旧 Agent 也会提示未确认，不意味着默认拨号必然失败。

## 验证与部署

- Worker 83 项、自托管 5 项、iOS 生产模型/自检独立回归通过。
- iOS 模拟器完整构建通过，未安装或上传 TestFlight。
- Cloudflare 版本 c8250384-03eb-4271-a712-7bb4508dce0f；上一版 aa4d2c26-d546-4225-9eb5-21397425826d。
- ECS current 切换到 /opt/airsim-relay/releases/20261115-sim-id；上一版 20261115-991162c 保留。停服后完整数据与配置备份在 /opt/airsim-relay/backups/20261115-sim-id/state-and-config.tar.gz。
- 上传包 SHA-256 de22dbb0382c37920f140bb029b088a40fdfc720b1e9787781aca6f360a45317；源码摘要匹配。AirSIM Cloud/TURN 进程未重启。
- ECS 公网使用 Android 三段格式合成验证：列表上报、拨号/短信选卡透传、同一意图换卡 409、非法 LF 400、注册鉴权、心跳、双向 PCM。随机测试设备注册已清理；无真实设备命令或推送。

现有客户端不需要改变标识或重新配对；等待安卓下一次心跳或手动“立即发送云端心跳”，然后 iPhone 刷新云端状态并重选卡复测。新增自检需安装新 iOS 包。真机拨号/短信尚待用户验证；本次源码尚未提交推送。
