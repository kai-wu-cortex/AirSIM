# HONOR Android 16 通话采集启动兼容性（PR #35）

## 故障与贡献者提供的证据

PR #35 的贡献者在 HONOR AMG-AN00 / Android 16（SDK 36）上报告：
信令可用，但特权 `app_process` PCM 桥在 `AudioRecord.startRecording()` 内抛出 NPE，
上下行没有音频。贡献者反汇编的 ROM 在该方法入口调用
`Objects.requireNonNull(ActivityThread.currentApplication())`，并对 CAMCORDER(5) 跳过这段审计。
这属于该 ROM 的实现细节，不能从所有 NPE 推断同一根因。

贡献者报告原补丁在 v0.9.8.23 和 v0.9.8.24 基线上恢复双向音频，约 39 万字节、
上下行峰值非零。其历史实验使用单独测试包名；本项目没有增加荣耀专版或修改通用包名。
这些是真机报告，不代表维护者已在荣耀上验收下面收窄后的补丁。

## 合入策略

原补丁无条件反射并修改 `mRecordSource`，普通 Android 也可能具有该字段，
因此“字段不存在时回退”不足以保证其他品牌不受影响。合入版本改为：

1. 所有设备先正常调用一次 `startRecording()`；正常成功完全不触碰字段。
2. 仅 HONOR / SDK 36，且 NPE 栈前两帧精确为 `Objects.requireNonNull` →
   `android.media.AudioRecord.startRecording`，且尚未处于 recording 状态时允许一次兼容重试。
3. 构造仍使用真实通话采集源；只在重试期间将 Java 字段临时置为 5，`finally` 恢复。
4. 字段不可访问时保留首次异常，不继续启动；SecurityException、其他 NPE、其他品牌/SDK 不重试。
5. 恢复失败不能报告 READY，交给现有 endpoint lease 终止并释放采集；重试异常保留为主异常。
6. 真正进入 recording 后原子地记录每进程一次 `capture_audit_bypass`。

只在两处调用：早期媒体下行采集和完整通话采集。不改变 native 构造参数、上行、鉴权、
通话状态与计时，也不新增权限。反射私有字段存在 ROM 差异风险，未验证系统保持原失败行为。
日志 `error_stack` 最多 8 帧，仅类、方法与行号，不包含异常正文或源码文件路径。

## 自动验证

```sh
sh android/phone-audio-bridge/build.sh
sh android/phone-control-app/test.sh
```

新增宿主 JVM Android 边界桩测试覆盖正常路径、匹配异常的一次重试、恢复真实源、
其他厂商/SDK不命中、非审计 NPE、不绕过权限失败、重试失败恢复、反射不可用、
诊断栈截断与隐私。原有 early/full session 启动清理测试继续执行。
2026-11-10 验证：音频桥测试和 DEX 构建通过，新增 16 项检查通过，Android App 全套回归通过，`git diff --check` 通过。
这些测试不模拟 HAL，也不能证明实际通话音质。

## 待真机验收

- HONOR AMG-AN00 / SDK 36：普通启动失败后是否命中收窄条件，是否仅记录一次兼容成功。
- 通话双向声音、远端挂断、重拨、早期媒体只收下行且不提前计时。
- 三星/Redmi：正常路径不产生兼容事件，音频和采集音量不回归。
- 新版 ROM 若栈形态不同，需要先采集不含私密正文的异常栈再扩大适用范围。

本次只改通用 Android PCM 桥与诊断，不涉及 Worker、iOS、Go Agent API、U30Air 固件。
无需为此同步修改 U30Air 协议。未自动安装、拨打电话、部署或发布新版本。
