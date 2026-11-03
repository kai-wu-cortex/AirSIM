# iPhone Duo 与可变尺寸窗口适配

本次依据 Appllama App Design Skill 的原生控件、窗口安全区域、状态连续性和模拟器验证原则，调整已有 SwiftUI 界面。保留原生 TabView、导航栏、表单及系统配色，不按机型名称或固定屏幕分辨率选择布局。

参考：
- [Appllama App Design Skill](https://github.com/Appllama/appllama-skills/blob/main/skills/appllama-app-design-skill/SKILL.md)
- [Apple：Prepare your app for iPhone Duo](https://developer.apple.com/iphone-duo/prepare/)
- [Apple：Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)

## 界面行为

- iPhone 允许竖屏与左右横屏；依赖当前窗口的安全区域，不读取整块屏幕尺寸。
- 拨号页：窄窗口保持纵向排列；宽窗口分为号码／设备区与按键区。改变尺寸不重建号码状态。短窗口可滚动，按键不小于 44 pt。
- 通话页：宽窗口并排展示联系人与通话操作；窄窗口纵向展示。布局变化不改变通话 ID、音频连接或挂断／接听动作。大字体与短窗口可滚动。
- 短信：iOS 17 及以上采用原生 NavigationSplitView，在宽窗口显示列表与对话，窄窗口使用系统返回导航。对话详情保持同一视图身份，使窗口变化时草稿不被重置。iOS 16 保留原有导航栈。
- 通话键盘使用可滚动内容与中／大两种系统高度，避免横屏时最后一排按键被裁切。
- 辅助功能字号使用单栏；设置、联系人和最近通话继续使用已有原生可滚动界面。
- 顶部其他设备来电提示通过安全区插入，为正文预留空间；短信列表按自身安全区布局，并在集合实际宽度变化时重算高度、恢复原消息位置。

## 最新验收结果（2026-11-02）

Duo 模拟器应用启动和测试执行已恢复，当前实现通过 **10 项定向测试**（分三轮：4 项布局／短信交互、5 项核心 UI 回归、1 项展开屏大字号操作）。构建与 `git diff --check` 通过。不是全项目测试通过，也不代表真实通话验收。

| 检查 | 结果 |
| --- | --- |
| 拨号号码旋转保留、追加数字、清空 | UI 回归通过 |
| 短信带键盘旋转、草稿保留 | UI 回归通过 |
| 短信反复进入／返回与切换标签 | UI 回归通过 |
| 联系人搜索、最近通话标题 | UI 回归通过 |
| 来电／通话操作可点击、DTMF 末排可达 | 合成通话 UI 回归通过 |
| 展开屏最大辅助功能字号下滚动、末排按键、清空 | 新增 UI 回归通过 |
| 窗口布局规则、短信选择和阅读锚点 | 4 项测试通过 |
| 折叠／半展开／展开后的短信草稿、拨号号码 | Device Hub 手工验证通过 |
| 深色、XL 设置页、展开屏短信分栏 | 截图核对通过 |
| 真机通话、音频不中断、硬件折叠与帧率 | 尚未验证；需要 Duo 真机 |

本轮实际修复：通话显示时，Duo 原生导航容器仍参与点击判定，导致接听按钮可见但不可点击。现在隐藏底层 TabView 的显示、点击和辅助功能访问，并将通话层置顶；保留导航状态，不更改媒体或通话状态机。修复前该断言失败，修复后接听／挂断和通话键盘检查通过。

测试证据存于本机 `~/Library/Caches/AirSIM/DuoValidation/`：

- `duo-targeted.xcresult`：首轮结果，包含 4 项通过的布局／短信交互测试及后续已修复的 UI 失败。
- `duo-ui-final.xcresult`：5 项核心 UI 测试，0 失败。
- `duo-large-text.xcresult`：展开屏大字号测试，0 失败。该轮 XCTest 自动截图为黑图，不能作为视觉证据；断言和执行记录有效，视觉检查另用 Device Hub。
- `duo-open-incoming.png`、`duo-open-settings-dark-xl.png`：展开屏截图。
- `duo-flow-primary-1.mov`：折叠过程的内屏录像；切换到外屏时内屏黑屏，不作为帧率测量。

未提交、推送、发布，也未覆盖安装真实设备。

## 验证边界

工具链为 Xcode 27.2（27B52）及 Duo 专用 iOS 27.2 运行时（24B91016s）。2026-11-02 上午已恢复应用安装、启动与 XCTest 执行，实际完成短信草稿和拨号内容的折叠／展开检查。系统初始化仍留下 `Data Migration Failed` 诊断，不能称为运行时根因已经修复；最新验收结果见本文末尾。

模拟器验证不代替真实通话链路、铰链硬件输入、音频连续性与真机帧率测量。测试数据为隔离的合成短信／通话，不连接真实网关、不拨打真实电话。

自动化回归入口：`PhoneWindowLayoutTests`、`SMSNavigationUITests`。测试使用模拟器隔离数据，不连接真实网关、不拨打真实电话。

### 历史验证记录（2026-11-01，已由上方结果更新）

- Xcode 27.0 模拟器编译通过；窗口布局规则 2 项测试通过。
- iOS 26.5 上通话按钮／通话键盘、联系人与最近通话工具栏、短信反复进入返回、带键盘的短信草稿旋转测试分别通过。
- 拨号号码在旋转中保留；横屏“清空”后的即时断言失败，已补充等待 UI 更新的断言与横屏数字输入检查，尚待完成复测，不能视作已通过。
- 测试运行结束后的结果包收集及后续模拟器启动遇到长时间停滞，已保留控制台日志与录屏，停止挂起进程。不能以该轮不完整结果包宣称整套测试通过。
- 该轮之后已更新至 Xcode 27.2，见下方工具链记录；宽屏、深色／XL 字号、Duo 折叠和真机帧率仍需完成验证。

### 工具链更新进度

2026-11-02，已从 Mac App Store 安装 Xcode 27.2，命令行确认版本为 27B52，包含 iOS 27.2 SDK。更新曾因空闲磁盘不足 1 GB 暂停；经用户确认，已卸载 iOS 26.5 与 watchOS 26.5 的旧模拟器运行时，保留模拟器设备数据、项目、签名和发布包，随后完成主程序更新。

用户已完成本机管理员授权，共享组件安装完成。Duo 专用运行时已就绪：`com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4`，构建 24B91016s，支持设备列表明确包含 iPhone Duo。

Xcode 自动选择了两个 iOS 27.2 构建：24B8117 的支持设备列表不包含 Duo；24B91016s 支持 Duo。已尝试通过 `simctl runtime delete` 清理本次新增的 24B8117，首次提示 MobileAsset 未回收，按工具建议重新扫描并删除记录后，磁盘空间仍未恢复。

用户另行授权移除旧 iOS 27.0，保留设备数据及 watchOS 27.0。删除同样出现 `SimDiskImageError code=30`，运行时注册记录移除但 MobileAsset 未回收，不能宣称已释放约 8 GB。另清理了此前 AirSIM 构建的可再生中间缓存，保留安装包、归档及当前测试产物。

已完成 Xcode 27.2 的 `build-for-testing`（`TEST BUILD SUCCEEDED`）；尝试在原 iOS 27.0 模拟器运行定向回归时，测试启动阶段停滞，尚未进入测试用例，已停止该轮并重启模拟器服务。不能把构建通过或该轮启动等待记为测试通过。后续优先在新运行时继续。

### Duo 运行验证记录（2026-11-02）

- 新建 `AirSIM-Duo-UI`，设备 ID `73968C4F-F842-42EA-B025-FE93DC266FCF`。
- 设备 MobileInstallation 日志确认 `com.example.airsim`（build 152）安装成功；工具的长时间等待不能据此认定安装失败。
- 首次初始化和一次干净重启均报告 `Data Migration Failed`；未取得可交互的 AirSIM 截图，折叠／展开、拨号清空、短信草稿的 Duo 回归仍未通过验收。
- 未找到明确的 ENOSPC 或应用崩溃证据，不能断言磁盘不足就是初始化失败的原因。
- 最后磁盘余量约 2 GB；已关闭该测试模拟器并停止挂起请求。下一步先保存其他工作、重启 Mac 并恢复足够运行空间，再对同一测试设备继续验证；无需重新配对真实设备。

### Mac 重启后复查（2026-11-02）

- 用户完成重启后，磁盘可用空间恢复至约 37 GiB；Xcode 27.2 与 Duo 专用运行时仍为 Ready。旧 iOS 27.0 注册记录重新出现，未继续删除运行时或设备数据。
- 原 `AirSIM-Duo-UI` 再次报告 `Data Migration Failed`。另建空白测试设备 `AirSIM-Duo-Clean-Verify`（`C8A196D1-3DE2-4D56-960F-E244DCC39B53`），保留原测试设备。
- 空白设备在安装 AirSIM 之前也出现迁移失败。系统日志包含 `Reporting migration failure due to migration progress window incident`，以及 WebBookmarks 迁移监视器异常；不能据此判定 AirSIM 启动失败。
- 等待系统后续启动后，Device Hub 能显示主屏幕及折叠／展开控制，AirSIM build 152 安装日志确认成功。仍需验证应用能正常启动及实际交互，主屏幕可见不等于完成适配验收。
- 重启清理了此前 `/tmp` 中的构建和诊断文件。本轮产物改存本机 `~/Library/Caches/AirSIM/DuoValidation/`，包含系统迁移日志、进程采样、截图与重新构建日志；旧轮结果仅保留本文的已记录结论。

- 空白 Duo 的 AirSIM 启动请求最终返回 `NSPOSIXErrorDomain Code=3`：`Application launch ... did not return a process handle nor launch error`。未进入应用交互验收。
- 已关闭该 Duo 并进行运行时对照：已有 iPhone 18 Pro Max（iOS 27.0）约 20 秒完成启动，`bootstatus` 明确返回 `Finished`。此结果仅说明普通设备的系统启动成功，不能替代 Duo 折叠或 AirSIM 应用测试。

- 重启后的全新 arm64 `build-for-testing` 再次通过（`TEST BUILD SUCCEEDED`），产物位于上述持久缓存的 `DerivedData/Build/Products/`。构建通过不代表交互回归通过。

- 普通 iPhone 上的定向回归已启动测试运行器，并进入 `testCallControlsAndKeypadRemainReachableInLandscape`；随后停在 `Launch com.example.airsim`，未到达首个界面断言。等待约 4 分钟后主动中断本轮，结果不计为测试通过，也不据此判定布局断言失败。
- 本轮仅更新诊断记录，未新增产品代码改动，未提交、推送、发布或覆盖安装真实设备。后续需要先恢复稳定的模拟器应用启动／测试链路，再完成拨号清空、草稿保留、折叠、深浅色和字号验证。无需再次无条件重启 Mac。

### 启动恢复与 Duo 交互复测（2026-11-02 上午）

- 在 `AirSIM-Duo-Clean-Verify` 上重新安装构建并启动，系统“设置”和 AirSIM 均返回有效进程，实际页面可操作；再次停止／启动 AirSIM 也成功。没有删除原设备或用户数据。
- `bootstatus` 仍报告迁移失败，但没有阻止本次应用交互与 XCTest。此前启动故障与这条诊断的因果关系未证实，不用修改 App 业务逻辑来隐藏系统诊断。
- 用户停止其他模拟器操作后，使用真实屏幕键盘输入 `123`，验证展开 → 折叠 → 展开、旋转及半展开，短信草稿保持；折叠会收起键盘，重新点击输入框可继续输入。
- 拨号输入 `123` 后折叠仍保留，继续点击数字可追加；展开来电页展示联系人与接听／拒接双栏，折叠恢复纵向布局。
- 首轮定向 XCTest 完整结束：9 项中 5 项通过、4 项失败。通过项为 2 项窗口布局规则、2 项短信选择／阅读锚点和 1 项带键盘草稿旋转。失败项包括旧 `tabBars` 查询不兼容 Duo 系统导航，以及横屏通话按钮可点击性，后续修正／复测记录如下。
- 已将 UI 测试改为查询原生标签按钮，兼容底部与侧边系统导航；首次麦克风提示明确选择“不允许”，布局测试不采集音频。

- 后续诊断确认麦克风弹窗并非通话按钮失败的唯一原因：Duo 原生导航容器在通话覆盖层下仍参与命中测试。`RootView` 现在在通话期间保持 TabView 的状态，但隐藏其显示、点击和辅助功能访问，通话层明确置顶；不改变接听／挂断或媒体业务逻辑。
- Duo 的返回按钮位于系统侧边工具栏，测试改为优先定位系统 `BackButton`，旧系统仍使用导航栏返回按钮。没有为通过测试而移除返回或可点击性断言。

- 最终再次关闭并启动同一 Duo：`bootstatus` 仍在约 7 秒返回 `Data Migration Failed`，随后 AirSIM 启动返回有效 PID 77026，Device Hub 显示应用页面。恢复的是可用的安装／启动／测试路径，并未消除 Apple 运行时迁移告警。默认外观已恢复浅色、字号恢复 Large。
