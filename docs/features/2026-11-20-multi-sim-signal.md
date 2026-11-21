# 多 SIM 信号：灵动岛与桌面小组件

## 行为

- 安卓 `SimSlotJson` 为每个已解析的 subscription 单独读取系统信号等级（0–4）。不使用默认卡信号替代其他卡；读取失败不会隐藏卡槽或影响拨号／短信。
- 复用 VoWLAN health/device info、VoBLE device_info、Standalone Relay 心跳中的 `sim_slots`。没有新增通话期间的 BLE 轮询、定位权限、Root 或 Shizuku 请求。
- iPhone 从当前已认证设备、可用通道的 SIM 列表生成展示快照。卡槽为空时不从旧选择缓存复活；信号数据不参与选卡、路由、认证或在线判定。
- 灵动岛展开及锁屏活动显示当前设备的分卡信号；收起时并排显示最多两组信号条，更多卡显示数量提示。最小岛继续显示连接模式，避免挤占系统区域。
- 桌面小／中／大／超大小组件显示各自设备的分卡信号，宽度不足时使用紧凑布局。锁屏 accessory 的现有极简布局保留。
- 每个设备最多展示四张已启用的卡，按物理卡槽排序。没有可靠卡槽编号时显示“卡 1”等，不猜测订阅号或电话号码。
- `0` 格与未知不同：未知、旧版本未上报、采样超过 5 分钟均显示灰色横线。小组件时间线在采样到期时更新；Live Activity stale 只清除信号，不把设备误报成离线。
- 为控制 ActivityKit 载荷，仅当前设备带信号详情；其他设备继续显示原状态与号码。

## 可选协议字段

```json
{
  "sim_slots": [
    {"id":"原有不透明账号标识","label":"SIM 1","slot_index":0,
     "signal":{"level":4,"observed_at_ms":1795150000000}},
    {"id":"另一张卡的原有标识","label":"SIM 2","slot_index":1,
     "signal":{"level":1,"observed_at_ms":1795150000000}}
  ]
}
```

字段完全可选，旧客户端可忽略；旧安卓／Agent／Relay 未提供时显示未知。Relay 只保留整数 0–4 等级与正整数毫秒时间戳，不改变 SIM ID 验证及命令语义。

Android 30+ 将系统信号采样的单调时钟时间转换为 Unix 毫秒；Android 29 不提供该公开时间戳，使用读取时间，系统内部缓存年龄无法进一步确认。参考 [Android SignalStrength](https://developer.android.com/reference/android/telephony/SignalStrength)。

## 验证

- `sh android/phone-control-app/test-sim-signals.sh`：执行生产 SimSlotJson，模拟 API 29/30/35/36 的平台边界；双卡不同信号、0 格、空测量、过期／未来时间戳、权限失败、未解析订阅、移除卡槽通过。
- Android Standalone Debug 完整构建通过：`/tmp/airsim-sim-signals-android/AirSIM-SIM-Signals-debug.apk`。
- `node --test push-relay-worker/test/relay.test.mjs`：69 项通过，包含双卡信号经过真实 Worker 心跳与 status 的往返，以及非法数据过滤。
- iOS `SIMSignalDisplayTests` 覆盖旧字段兼容、逐卡映射、0 格／未知、过期、Widget 编解码及时间线、Live Activity 到期不误报离线；同时运行现有 `AirSIMWidgetTests`，16 项通过。
- `sh iOS/scripts/test-cloud-sim-roster.sh` 通过，旧 SIM 选择／诊断协议保持兼容。
- 最终完整 iOS/Watch/Widget 测试构建成功：`/tmp/airsim-sim-signals-final-build.log`。
- 最终原生测试结果：`/tmp/airsim-sim-signals-final-tests.xcresult`（16 项，0 失败）；检查了小／中／大尺寸双卡浅色与深色渲染，SIM 标签与信号条无重叠。
- `git diff --check` 通过。

## 尚待真机联测

需要更新 iPhone、安卓 Standalone；云端模式还需同步部署 Cloudflare 和 ECS Relay。此改动未自动安装、部署或发布。

1. 双卡手机确认两卡信号不同，VoWLAN、VoBLE、云端逐一检查映射。
2. 禁用／移除其中一张卡，确认无旧卡残留；切换设备确认信号不串机。
3. 保持手机连接但暂停快照刷新，5 分钟后信号变未知，在线状态和 PushKit／CallKit 不受该到期逻辑影响。
4. 在正常通话中验证音频与蓝牙控制；VoBLE 信号复用原有仅前台空闲时每分钟 device_info 查询，通话中不增加查询。
5. 旧版安卓、没有信号 API／权限的 OEM、U30Air 未上报逐卡字段时不得显示假满格。本次不修改 U30Air Agent；既有单卡 modem dBm 兼容保留。

模拟平台测试不等同于所有 OEM 双卡真机验收；桌面 Widget 刷新频率仍受系统预算控制。
