# VoBLE 电量展示与旧 Android 短信能力误判

## 实机证据与原因

用户确认：桌面小组件及 App 内均没有看到安卓电量；Redmi 9 短信发送提示“不支持系统短信发送”。
连接设备为 M2004J19C，API 31（Android 12）。只读查询得到电量约 60%，系统声明
android.hardware.telephony / gsm / cdma / ims，没有 android.hardware.telephony.messaging。
后者从 API 33 才新增，原 SMSCommandExecutor 不分系统版本强制要求它，导致在选择
SIM、调用 SmsManager 或特权发送之前就被误拒绝。此问题不限 Redmi/联发科或 VoBLE。

电量已有 AndroidBatteryStatus → 已认证 VoBLE device_info → AndroidAgentMetadata →
AppModel 的数据通路。但 App 设置首页/设备详情没有绘制电量；中、小尺寸 Widget
也没有电量视图。大尺寸已有电量。用户反馈主要涉及缺少展示入口，此外增加采样/解析/
Widget 发布的脱敏日志以验证实际数据是否到达，避免将字段存在等同真机成功。

## 修改

- SMS：API 33+ 检查 FEATURE_TELEPHONY_MESSAGING；API 32 及以下检查
  FEATURE_TELEPHONY。继续执行 SEND_SMS 权限、SIM、系统服务、回执和操作去重逻辑。
  不自动重发失败短信；与厂商无关。相关提示去除“三星”限定。
- 设置首页设备卡和设备详情增加百分比与充电状态；共用原 Widget 的按设备身份、
  认证 BLE 状态和样本时效过滤规则。纯本地模式不使用 Relay 样本。
- 小/中尺寸 Widget 增加紧凑电量，大尺寸保留原显示；无数据/超过五分钟不冒充实时电量。
- 脱敏诊断：Android voble_battery_sample；iOS BATTERY_METADATA / METADATA_FAILED；
  Widget BATTERY_SNAPSHOT。只记录电量、是否新鲜、计数和错误类型，不记录号码或密钥。
- 未更改 Worker、HTTP/POST、U30Air 或 BLE 媒体协议；保留此前早期媒体优化。

## 验证

SMSCompatibilityTests 先在 API 29 旧系统误判处失败，修复后 API 29/30/31/32/33/35
通过；验证现代系统不能仅凭通用 telephony 标志绕过 messaging 要求，无电话能力设备
仍被拒绝。测试不发送短信。Android Standalone 完整 test.sh 通过（含 APK 构建与
manifest 检查）。iOS 构建与真实媒体/协调器回归、安装后电量采样结果补记如下。

参考：https://developer.android.com/reference/android/content/pm/PackageManager#FEATURE_TELEPHONY_MESSAGING

### 安装与实机读取

- iOS build-for-testing、codesign、媒体 parity 与 8 项协调器/5 项恢复回归通过；
  完整 XCTest 未运行，不以编译替代运行结果。
- Redmi Standalone Debug 覆盖安装并启动成功；APK SHA-256：
  582b19454dcf433a1a3aacd553bca4bb39b45259d14f2e39fa7aba1191729b78。
- iPhone Air 覆盖安装并启动成功，安装 UUID 8B57D44E-C23C-4306-BEF1-8F70F82851F7，
  数据库序号 3544。保留配对与设置。
- 19:13:42 Android 已认证 VoBLE device_info 路径：voble_battery_sample present=true percent=59。
- 19:14:18 iPhone BATTERY_SNAPSHOT：devices=1、battery_count=1、selected_percent=59，
  证明实际 Widget 快照已保存有效电量。该日志未标明样本来源，不能仅据它宣称
  这次保存只经过蓝牙而未使用其他已验证来源。新 UI 的最终显示由用户查看确认。
- 未自动发短信；修复的是发送前能力误判，真实短信送达仍待用户手动验收。
- 未提交、推送、发布或部署 Worker。
