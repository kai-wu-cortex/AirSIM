# PR #47 视觉整合撤回

用户要求：撤回 PR #47 及后续三张参考图引入的全部 UI，恢复客户熟悉的界面，保留已发布的功能修复。

## 范围

- PhoneViews.swift、RootView.swift、WatchCallView.swift 和 SMSNavigationUITests.swift 恢复至整合前 `991162c`，逐字节比较一致。
- 恢复拨号设备卡片、原拨号键与清空入口、最近通话布局及操作、线性 Tab 图标、原通话背景/按钮/录音入口和 DTMF 样式。
- 移除本次 UI 引入的通话收起/恢复界面与新增联系人菜单，回到原先的界面交互；不修改底层通话状态机或系统 CallKit。
- 撤回手机/Watch 服务号码品牌图标、匹配显示代码和工程资源引用；保留历史资源来源说明。
- 删除开屏 callVisuals 页面及其 SVG，更新本地版本介绍。保留独立的多 SIM 信号介绍。

## 保留

AppModel、AudioSessionController、CallKitController、VoIPPushController、WatchCallSession、Watch 启动注册、网络/VoBLE 协议、安卓/Relay、短信回执与多 SIM 信号代码均与撤回前 HEAD `1a5138f` 相同。工程中的 PushKit 共享源码引用与 build 185 未回退。

## 验证

- 旧 UI 四个文件逐字节比对通过；变更范围白名单检查通过。
- Swift 语法、工程 plist、git diff --check 通过。
- 更新策略及生命周期 39 项检查通过。
- PushKit 手机/Watch 26 项拒绝/错误路径、同步上报、completion 与 UUID 隔离检查通过。
- iPhone + Watch 及扩展完整 Debug 真机目标构建通过（/tmp/airsim-pr47-ui-rollback/build.log）；未以源码比对或构建代替真机视觉验收。

未覆盖已发布的 v0.9.8.26 附件或 TestFlight 185；未发起真实通话/短信、部署或发布。

## 用户后续授权安装

- 使用临时签名配置构建 0.9.8（186），主 App、Watch 与两项扩展版本一致；源码发布版本未变。
- 完整真机目标构建、深度签名校验通过。CoreDevice 确认在 iPhone Air 覆盖安装并启动成功，未卸载应用。
- 设备安装查询再次确认 186。旧 UI 的实际使用体验仍由用户验收。
