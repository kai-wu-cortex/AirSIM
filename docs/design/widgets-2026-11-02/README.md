# AirSIM 全尺寸 Widget 概念方案

- [01 系统原生](01-native.png)：优先推荐，白底、清晰状态、蓝色入口。
- [02 连接仪表盘](02-dashboard.png)：深色、高信息密度、多设备概览。
- [03 轻玻璃](03-glass.png)：浅色半透明表面与柔和层次。
- [完整生成提示词与实现边界](prompts.md)。使用内置图像生成工具；接口无法指定或确认 image2.5。

涵盖桌面小、中、大、iPad 超大，以及锁屏圆形、矩形、内联。图片属于视觉探索，尺寸比例、字体、图标与锁屏单色渲染需在 WidgetKit 中重新验证。方案 01 已实现为 WidgetKit 小组件，见 [实现与配置说明](../../widgets.md) 和 [实际视图渲染](implementation/large-light.png)。其余两套保留为概念。

## 实时活动到期处理

2026-11-02 在 AppModel 启动和回到前台时增加立即刷新展示的入口，从现有设备/通话状态恢复卡片，不等待网络轮询结束。ActivityKit 活动结束不会改写设备在线状态，也不会调用 PushKit 停用或 CallKit 挂断。纯本地的云端禁用策略保持不变。

验证：iOS 构建通过；10 项 LiveActivityReconciliationTests 通过，包括过期卡片仅前台重建、保持在线状态、保留当前通话、清理重复卡片。Worker 的 `status-only clients keep CallKit delivery without starting or overwriting device activities` 定向测试通过。上述为本地模拟测试，未进行真实 8 小时过夜测试或真实 APNs/CallKit 来电验收，未安装/部署/发布。
