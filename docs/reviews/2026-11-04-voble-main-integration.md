# VoBLE 与 main 集成记录（2026-11-04）

用户明确要求把 VoBLE 尚未提交的改动检查、整理后一起合入 main。未修改 `/Users/kyle/codex project/AirSIM` 中另一个分支的未提交工作。

## 来源与保留范围

- VoBLE 已提交基线：`1f353767faaf26d764f2e359b962e5104d8b693c`。
- main 集成基线：`5e32b602aad3e7440549b0d1968b30ab8a7711ef`，包含已评审合并的 PR #29。
- `c5d4db8`：通用 Android 应用内的能力探测、Root/Shizuku 生命周期、设备音频适配、接通前只接收音频及 SIM 号码兼容处理。
- `f7a3fa4`：iOS 设置分层与导航精简、固定 Tab、短信搜索、小组件每设备最近五条通话／短信、Duo 布局及 Date 运行时兼容处理。
- `7db0cb5`：复用 Worker 源码的自托管 Relay、HTTP/2 APNs 桥、部署配置模板和说明。

用户已安装的 166 界面改动包含在本次源码整理中。构建版本没有因为合并而自动递增；本次源码比此前安装包多出 PR #29，不能说现有设备已经获得此次集成内容。

## 集成处理

- 唯一文本冲突位于 `AirSIMTests.swift` 末尾；保留设置／通知转发测试及 PR #29 的短信、挂断测试。
- 保留 Android 接通前音频 GET 路由，以及 PR #29 的 POST resolve、history/ack 路由，不互相覆盖。
- PR #29 新增的端点冷却检查五处、推送注册退避检查一处使用了 Date `<=` / `>=`。改为等价的数值时间戳比较，保留相等边界和原有退避时间，避免再次导入 162 崩溃所涉及的运行时符号。
- 配置模板只有占位值；扫描变更文件未发现实际 PEM 私钥或常见 GitHub/AWS token。自托管私有配置、生成配置、数据目录与依赖目录不纳入提交。

## 验证

- iOS 模拟器构建和全部 483 项单元／集成测试通过：`/tmp/airsim-voble-main-tests.xcresult`。
- 合并构建的 App 内 10 个 Mach-O 通过 `check-date-runtime-imports.py`，没有 Date `>=` / `<=` 导入。
- Android 主测试通过，覆盖权限通道、PCM 生命周期、早期媒体授权与撤销、API 29/30/35 SIM 监听、短信、网络恢复等。
- Android Standalone Debug 构建及签名校验通过；实际 Gateway/CloudCallManager、OutgoingObservation 定向测试通过。
- 独立音频桥构建与单元／启动测试通过，包括接通前只接收、拒绝麦克风上行、资源清理及设备路由 fixture。
- Worker 78/78 通过；自托管 Relay 5/5 通过，包括真实本地 workerd 的鉴权、心跳、命令去重、双向模拟 PCM、持久化重启和维护入口隔离。
- UI 导航回归最终四条通过：设置分类／手动配对、反馈草稿返回、联系人与最近标签切换、短信会话反复进入。前三项见 `/tmp/airsim-voble-main-ui-tests.xcresult`，短信会话复测见 `/tmp/airsim-voble-main-split-ui-final.xcresult`。
- 首次短信会话测试失败源于旧断言要求所有设备隐藏 Tab；Duo 展开时本就保留双栏与 Tab。测试改为验证列表行与回复输入框处于不同列，并保留单栏隐藏 Tab 的断言；未为通过测试更改生产导航。中间一次使用导航栏边界的断言也失败，因为系统导航栏覆盖整窗，最终改用实际回复控件边界。
- Duo 复测最终通过，但模拟器运行严重变慢，本次没有继续重跑普通 iPhone 单栏 UI 测试。不能把保留单栏断言描述为本轮已经执行验证。
- `git diff --check` 通过。

本地日志前缀：`/tmp/airsim-voble-main-`；临时日志不是仓库可长期保留的构建产物。

## 发布顺序与验收边界

PR #29 的跨端协议和部署顺序见 [API 兼容记录](pr29-api-compatibility.md)：兼容设备 Agent → Worker → iOS。Worker 的短信卡槽与发件线路透传同样需要部署更新，不能只更新客户端。

U30Air 协作线程已回复：最终协议已核对，源码测试及 ARM64 编译通过；设备端实机通话、短信与联合验收仍待完成，未安装或发布。此结论来自该线程的报告，本次没有操作其源码或 USB 设备。

本次只提交、合并并推送代码。未安装到手机、部署服务器、发布 Release 或上传 TestFlight。模拟测试不替代真实双向通话、锁屏来电、VPN/Wi-Fi 切换、短信选卡和早期运营商音频验收。
