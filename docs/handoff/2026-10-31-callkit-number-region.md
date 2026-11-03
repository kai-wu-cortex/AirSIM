# CallKit 来电号码与设备地区隔离

## 用户反馈与证据边界

用户转述：使用美区 Apple ID 的 iPhone 接收中国 SIM 来电时，系统显示了 `+1` 和错误的号码格式。暂时没有故障截图或对应原始 payload，不能断言 Apple ID 是直接原因，也不能确认错误发生在系统来电界面还是历史记录。

静态排查发现：

- Android Telecom 读取 `Call.Details.handle.schemeSpecificPart`，来电路径没有按 iPhone 地区补区号。
- Agent 的 CLIP / CLCC / DSCI 路径读取上报号码；目前未将号码类型字段转换成统一 E.164 号码。本次不猜测或重写这些号码。
- Worker 与 iOS PushKit 解析没有按 Apple ID 或 Locale 添加 `+1` 的逻辑。
- iPhone 和 Watch 原先把无国家区号的号码也作为 CallKit `.phoneNumber`，交给系统解释。设备地区和远程 SIM 地区可能不同，因此存在展示歧义。
- 通讯录 `ContactStore.normalized` 会去掉 `+86` 用于匹配与联系人缓存，但没有添加 `+1`；本次不改变联系人数据格式。

## 修改

共享 `iOS/Shared/CallKitNumberPresentation.swift`，供 iPhone 与 Watch 的来电、呼出 CallKit 入口使用：

1. 明确的国际号码（`+` 开头、合理长度、数字及常见分隔符）保留 `.phoneNumber` 和原始值，既不替换真实 `+1`，也不强制添加 `+86`。
2. 无区号号码、短号、服务码、未知号码采用 `.generic`；没有联系人姓名时显式使用原始值作为显示名称，避免按接收设备地区解释。
3. 保留实际拨号字符串、PushKit payload、通话身份和路由逻辑；不转换 `00` / `011`，不迁移历史记录。
4. 保留虚拟通知的标题和 AirSIM 自身联系人姓名匹配。

代价：无区号号码不再交给 CallKit 的电话号码型匹配；系统通讯录关联及系统最近通话回拨行为需要真机验收。显式国际区号仍使用电话号码型句柄。本次只是消除客户端地区猜测入口，不能修复上游已经错误写入的 `+1`。

## 验证

新增 `CallKitNumberPresentationTests`，覆盖中国/其他地区的本地号码、显式 `+86`/`+1`/其他区号、联系人名、未知号码、无效格式、拨号目标不变、真实 PushKit 与呼出事务入口、虚拟通知标题。

验证状态：iPhone / Watch 模拟器目标和包含 9 个号码专项测试的测试目标完成编译、链接，无编译错误；`git diff --check` 通过。

最初自动测试停在启动阶段：iOS 27 重启后以 `-testLanguage en -testRegion US` 重试仍未开始执行，独立新建 iOS 26.5 模拟器也未能开始执行。期间 Mac 的 load averages 达到 `363.04 / 230.47 / 124.61`。当时已中断本次启动的测试命令，不将编译结果算作测试通过，也未关闭其他项目进程。

发布阶段补测：英文／美国地区下，新增 9 项号码展示及 CallKit 入口测试全部通过。最终源码完整回归 387 项中 385 通过、2 项失败（多设备链路超时、Watch 占用释放后的接听返回 `stale`），不宣称全量通过。最终复跑及 TestFlight 152 上传回执见发布说明。

日志：`/tmp/airsim-number-presentation-tests.log`、`/tmp/airsim-number-us-tests.log`、`/tmp/airsim-number-us-clean-tests.log`。独立测试模拟器：`DB712BA4-C0B9-4DB1-A3C0-0E7FAC5F9497`（AirSIM-Number-Region，iOS 26.5）。环境恢复后重跑 `CallKitNumberPresentationTests`、`DeviceCallActionRouterTests`、`OtherDeviceCallReminderTests`，再做真机验收。

用户随后授权安装，已在 iPhone Air 覆盖安装并启动 **0.9.8 (151)**，设备查询确认 bundle `com.eric3u.airsim` / build `151`。此次真机构建 `BUILD SUCCEEDED`，`codesign --verify --deep --strict` 通过。沿用本地 Apple Development 签名与 APNs sandbox 配置，未卸载旧应用。

安装前后联系人、短信和通话记录逐项 JSON 内容比较均相同。备份及构建日志保存在受限本机目录，不要提交或公开其中的偏好、日志和用户数据。真机来电展示尚待用户复测。后续发布状态见 `../releases/0.9.8.20.md`。

## 真机验收

1. 故障 iPhone 保持原账号与地区，用同一中国 SIM 复测无区号来电：系统来电界面和 AirSIM 记录都应保留完整号码，不多出 `+1`。
2. 分别测试明确 `+86`、真实 `+1` 来电，确认区号不被强制改写。
3. 测试已存联系人、未知号码，以及 AirSIM 和系统最近通话中的回拨。
4. 若依旧收到 `+1`，比对安卓/模块原始号码、推送 payload 与 CallKit 句柄；只在本机查看，分享时遮住中间数字，不上传完整私人号码或 token。
