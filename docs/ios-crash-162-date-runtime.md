# TestFlight 162 启动崩溃：Date 比较的运行时兼容处理

调查日期：2026-11-04。来源：用户提供的 `TestFlight – AirSIM 0.9.8 (162).crash`。

## 已确认的证据

- AirSIM 0.9.8（162），TestFlight，iPhone18,4，iOS 27.2 Beta `24B5089g`。
- 启动 08:41:54.3049，终止 08:41:54.5876，约 0.283 秒。
- 报告包含 `EXC_BAD_ACCESS (SIGKILL)`、`CODESIGNING 2 Invalid Page`、`pc=0`、`x16=0` 和执行权限缺页信息。
- 栈为 `Date.>=` → `VoWLANRecoveryGate.shouldAttempt` → `recoverIfNeeded` → Agent 轮询。重连检查在主线程控制器内调用。
- 找到原始 Release 归档和 App Store 导出包；两者主程序 UUID 均为 `67289F94-8240-3D34-9014-221939926055`，与崩溃日志一致。归档、App Store 导出包深度签名验证均通过。
- 将崩溃 LR `0x100394908` 减去加载偏移 `0x44000`，得到 `0x100350908`。其前一条指令 `0x100350904` 调用 stub `0x1003f3c80`。
- 该 stub 对应弱链接符号 `_$s10Foundation4DateV2geoiySbAC_ACtFZ`（`Date.>=`）；stub 从 GOT 取值到 x16，然后 `br x16`。日志 x16 和 pc 都为零，吻合空函数地址跳转。
- 调用前存在 iOS 27.2 版本判断。当前 SDK 的 Foundation Swift 接口对 `Date.>=` 和 `Date.<=` 标注 `@backDeployed(before: ... iOS 27.2 ...)`；其兼容实现正是比较两侧 `timeIntervalSinceReferenceDate`。

## 判断及边界

直接故障点是对 `Date.>=` 的空地址调用。最有力的解释是新 SDK 与故障设备的早期 27.2 Beta 运行时不一致：版本判断选择系统实现，但该弱链接入口未能解析。

最初只看 `CODESIGNING` 会指向代码页校验；结合匹配 UUID 的反汇编和寄存器，不能再把它简单归因于开发者证书或打包签名损坏。`CODESIGNING` 是此次终止记录，不足以单独说明根因。没有取得故障设备的系统库或现场 `dlsym` 结果，因此“该 Beta 缺少导出符号”仍是高置信度推断，不能视作 Apple 已确认的问题。

163 的 Debug 程序也引用这两个弱符号，仍有兼容风险；此前安装和成功启动不代表能排除故障设备上的该问题。短信搜索、Tab 和小组件列表的新增改动不在这份 162 崩溃堆栈中。

## 修复

将生产代码中具体 `Date` 类型的 `>=`／`<=` 改为两侧 `timeIntervalSinceReferenceDate` 的数值比较，等同于 SDK 的兼容实现，保留相等边界以及原有过期和重试规则。范围包括 VoWLAN 恢复、离线确认、元数据刷新、通话记录去重、Push 注册／过期校验、蓝牙防重放与分片回收、Watch 同步。

不修改计数器、DispatchTime 或 Unix 秒整数比较；不放宽鉴权窗口、不绕过签名、不增加自动拨号。

新增 `iOS/scripts/check-date-runtime-imports.py <app-or-Mach-O>`：扫描 App、扩展、Watch 和内嵌动态库，拒绝以上两个未解析导入；后续安装／发布包签名完成后执行。它补充签名校验，不能替代真实运行。

## 验证结果

- 检查器正确拒绝原 App Store 162：主 App 和 Watch 含上述导入。
- 恢复门限的生产源码在原生断言运行器通过首次恢复、10 秒边界、提前重试拒绝、未配对排除、在线排除、reset 检查；相应 XCTest 增补边界断言。未运行完整 iOS XCTest 宿主。
- 修复后本地签名 Debug 0.9.8（164）构建通过，主 App 深度签名校验通过；9 个 Mach-O 均不再导入这两个 Date 函数。
- 构建 164 使用本机安装配置覆盖版本号，仓库默认仍为 162。未安装 164、未提交推送、未上传 TestFlight。
- 故障设备目前不可用，尚未在 `24B5089g` 上验证冷启动、重新进入 App、VoWLAN 恢复及推送路径。不能宣称真机故障已经消失。

## 验收

在原故障设备保留数据覆盖安装修复包，检查冷启动、退出重开、VoWLAN 离线恢复及后台回前台；另行验证来电／推送和 Watch。TestFlight 分发仍需新的 Release 归档、二进制导入与签名校验、上传处理和故障系统上的实际启动验证。
