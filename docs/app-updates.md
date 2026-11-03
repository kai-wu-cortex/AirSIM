# 应用更新说明与新版检测

历史状态：2026-10-19，本功能纳入 [Apps v0.9.8.1 / build95](releases/0.9.8.1.md) 发布准备。此前本地候选已按用户要求保留数据安装到 iPhone Air 和三星 Flip7，并完成主 App 启动／进程复查；三星更新说明弹窗已通过 UI 层级确认，iPhone 弹窗布局仍待用户目视确认。构建及发布回执见版本说明，不能把准备状态当作已发布。iOS 和 Android 使用原生界面，不修改 Relay、Linux Agent、配对或通话协议。

## 2026-11-03 开屏介绍改版（未安装）

最新 iOS 源码的开屏轮播更新为四页：

1. **U30Air 支持**：设备与 iPhone 连接动画，介绍通话、短信及兼容设备端／配对前提。
2. **小组件**：展示设备状态、电量、设备／模式切换、最近通话及短信内容摘要；标明示意数据及系统刷新限制。
3. **TLS 公网（试验性）**：展示自建域名、TLS 网关与安卓的直连路径，介绍首次公网配对与已有设备公网入口；需要可入站网络、有效证书及独立音频转发，配置页提供教程。
4. **未读／未接提醒**：演示底部标签数字角标和具体记录标记，同时介绍小组件中的数量提醒。

插图全部打包在本机，用内嵌 SVG／CSS 动画，不请求外部资源，不使用用户真实号码或消息。切换到非当前页、App 进入后台或系统开启“减少动态效果”时停用动画；文字说明由原生界面供辅助功能读取。文字摘要与轮播同步。

该修改保留原有按版本／build 展示与确认机制，不清空已有已读标记，同一 build 可在「设置 → 关于 → 当前版本更新内容」重看。此次未安装或发布；已装的 160 不会自动获得新的介绍。U30Air 的早期媒体仅完成临时候选单次试听，不在开屏中宣称已正式开放，详见 [早期媒体交接](handoff/2026-11-03-early-media.md)。

验证：`iOS/scripts/test-app-updates.sh` 的 21 项发布策略检查与 39 项更新生命周期检查通过；iPhone 17e 模拟器目标完整构建通过（`/tmp/airsim-onboarding-features-build.log`）。本轮未覆盖安装用户设备，未执行真机视觉验收。

以下为此前介绍与安装历史，页面内容以上方最新改版为准。

## 2026-11-03 本地候选介绍

iOS 包内新功能轮播与文字摘要已更新，入口为「设置 → 关于 → 当前版本更新内容」。四页分别介绍：

1. 未接通呼出的通用结束提示，以及按通话身份处理重复／迟到的结束消息。
2. 网络失败不自动重复拨号；兼容设备支持只查询原拨号请求结果。
3. U30 Air 取消同号码两分钟冷却，上一通结束且基带确认空闲后允许明确的手动新拨号；不是绕过设备忙碌或重复请求保护。
4. 小组件电量、最近通话／短信、设备与模式切换，以及未读／未接数字和记录标记。

轮播插图与文案同步，示例数字标注为示意数据。电量需兼容 Android 上报，组件刷新受系统调度约束。通用结束提示不模拟运营商公告；接通前运营商媒体仍待设备端能力和独立联调验收。

**安装与验收边界：**本次只更新候选源码中的介绍，不代表已安装或发布。iPhone 先前已安装 0.9.8（158）的第一版通话修复；之后的原请求状态查询与此次介绍尚未安装。U30 Air 线程记录 `ce198d0` 已安装、未发布，立即重拨等真实通话验收仍待完成。详见 [客户端通话安全交接](handoff/2026-11-03-u30-r18-client-call-safety.md) 和 [拨号状态查询交接](handoff/2026-11-03-r18-client-operation-recovery.md)。不因文案更新清除已读标记；同版本／build 的用户可从设置手动重看。

## 用户行为

安装补记（2026-11-03）：用户后续授权安装后，包含原请求查询、终态入口修复和本次介绍的 **0.9.8（159）** 已覆盖安装到 iPhone Air 并启动。上文“尚未安装”是介绍修改时的阶段记录；实际安装与待验收项见 [终态入口交接](handoff/2026-11-03-r18-terminal-ingress.md)。

- 首次安装，以及版本名或 build/versionCode 变化后的首次前台启动，显示包内更新说明；不需要网络、Agent 或配对。点「知道了」后保存本安装版本的已读标记，后续启动不重复提示。更新说明内容随安装包发布，不拿网上最新说明冒充本机版本说明。
- 「设置 → 关于」提供「当前版本更新内容」「检查应用更新」及检查状态。手动入口始终可以重看说明和重新检查。
- 前台空闲时自动检查，每次尝试之前持久化时间，24 小时内不再次自动请求；失败也受限。不设后台定时器、不轮询 Relay。手动检查可以跳过每日冷却，但与自动检查共用单个在途请求。
- 自动检查只为未提醒过的新版显示提示；无新版或网络失败只更新状态。手动检查显示明确结果，失败不声称「最新版」。新来电／现有通话优先，不应由更新提示遮挡操作。
- iOS 首次说明在首次配对引导前显示；Android 在必需权限请求结束后、Shizuku／角色引导前显示。Android 检查结果归进程所有，Activity 重建仍能接收结果，不通过重复联网弥补旋转丢结果。

## 更新来源与边界

匿名读取 [GitHub Releases API](https://docs.github.com/en/rest/releases/releases) 的最近 100 项发布：`https://api.github.com/repos/kai-wu-cortex/AirSIM/releases?per_page=100`。每天的「检查」是一次有界 API 请求，不使用 `/releases/latest`：仓库 Latest 保留给 AVF Linux Agent，不能用于应用更新。响应上限 4 MiB，有限超时，无自动重试，不发送设备标识、号码、Push token 或 Relay 凭据。此 GitHub 访问独立于通话本地／云端模式；仅本地模式不等于禁用已确认的应用更新检查。

只接受非 draft、非 prerelease、数字版本 tag，并要求对应平台的已上传资产及官方仓库的 HTTPS 下载路径匹配。数字比较支持三段／四段版本，不按字符串排序。安装版本无法识别时不猜测；已知远端 build 小于或等于本机时不提示更新。

Android 分别选择 Standalone 与 AVF Bridge **APK**；不选 Debian 包。只打开相应 Release 页面，不自动下载、不请求安装未知应用权限、不安装 APK；同包名但不同签名仍无法覆盖，界面明确告知不能为绕过错误先卸载。

iOS 从 IPA 文件名读取版本和 build，只链接发布说明，不尝试安装 unsigned IPA。TestFlight／sandbox receipt 且没有开发描述文件时显示 TestFlight 提示，其余显示自签／侧载或其他渠道提示；这是提示用途的来源识别，不是收据验签或 App Store 分发证明。TestFlight 用户需在 TestFlight 查看可用构建，GitHub 发布不证明 Apple 已处理、审核或开放测试。自签用户仍需侧载工具重新签名。没有配置可验证的项目 TestFlight 邀请链接时，不编造 App 专属更新 URL。

最近 100 项中未发现更新只表示此扫描范围内没有可识别的新应用版本，不保证第三方分发渠道或 App Store 状态。检查结果及待提醒结果保存在进程内；如果进程在请求中被系统结束，仍保留当日尝试时间，手动检查可重试，下一日再自动核对。

iOS 热修复保留仓库既有命名：例如 Release `v0.9.7.2` 可以包含 `AirSIM-iOS-0.9.7-build91-unsigned.ipa`。四段发布 tag 可对应前三段相同的 iOS 版本，按 IPA 自己的 build 判断升级；不能把发布 tag 的第四段当作 iOS 的版本，也不能接受主／次版本不一致的旧资产。

## 发布维护约定

当前兼容资产名：

```text
AirSIM-Android-Standalone-0.9.8-Android10-13.apk
AirSIM-Android-AVF-0.9.8-Android10-13.apk
AirSIM-iOS-0.9.8-build92-unsigned.ipa
AirSIM-iOS-0.9.8-build92-sideload-unsigned.ipa
```

后续推荐 Android 文件名增加显式 build，以支持同版本重打包比较：

```text
AirSIM-Android-Standalone-0.9.8.1-build95-Android10-13.apk
AirSIM-Android-AVF-0.9.8.1-build95-Android10-13.apk
```

不含 Android build 的旧文件仅能比较版本名：同版本不能证明 versionCode 更高，不提示升级；不同版本只能提示发现新版发布，是否允许覆盖仍由系统安装器校验。不得从 iOS build 猜测 Android versionCode。

发布新版本时同时维护 `iOS/AirSIM/AppUpdateView.swift` 的 `NewFeatureCatalog`（实际轮播）、对应插图与 `AppReleaseNotes`（文字摘要），以及 Android `AppUpdatePresenter.showNotes` 的本机摘要，核对包版本与验证边界，并移除已发布项的候选措辞。正式发布仍需用户另行授权，不新增 workflow。

## 验证

```sh
sh iOS/scripts/test-app-updates.sh
sh android-standalone/test.sh
xcodebuild -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'platform=iOS Simulator,name=iPhone Air' CODE_SIGNING_ALLOWED=NO test
```

覆盖数字版本排序、平台筛选、拒绝错误平台／URL／未完成上传、首次／升级已读持久化、每日冷却含失败、手动检查、并发检查与 Android Activity 消费者交接。iOS 延后结果邮箱测试覆盖请求挂起时并发检查、迟到结果遇到通话／后台／已有更新弹窗的保留与一次性取出。自动化不代表真机权限弹窗、旋转屏幕、来电抢占或 TestFlight 可更新状态已验收；这些需另外实测。
