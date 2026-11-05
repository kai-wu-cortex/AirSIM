# Android 10：SIM 订阅监听导致启动崩溃

## 原因与支持范围

用户报告 Redmi Note 8 Pro / Android 10 在 Standalone Service 的 `onCreate` 中崩溃。
代码确认 `SIMSlotObserver.start` 无条件调用
`SubscriptionManager.addOnSubscriptionsChangedListener(Executor, listener)`，
但该重载从 API 30 才提供。API 29 执行此路径会发生 `NoSuchMethodError`。

Standalone 与 AVF Bridge 的 Manifest 均声明 `minSdkVersion=29`。
这是应用遗漏低版本兼容分支，不应据此要求用户升级至 Android 11、卸载应用或清除数据。
这也不代表 AVF 虚拟机及全部 OEM 音频能力在 Android 10 上可用。

## 修复

- API 29 使用单参数 `addOnSubscriptionsChangedListener(listener)`。
- API 30 及以上保留 Executor 重载，回调使用主线程。
- 保留在 `Service.onCreate` 主线程创建 listener，满足旧接口的 Looper 要求。
- 保留重启前注销旧 listener、停止时注销当前 listener 的生命周期。
- 不提高最低系统版本，不改变配对、推送、音频及 SIM 选择协议。

共享测试脚本新增生产 `SIMSlotObserver` 的 API 29 / 30 / 35 分支测试，
并覆盖订阅回调、重复启动、重复停止、无订阅服务。
API 29 测试替身会在误调用 Executor 重载时抛出 `NoSuchMethodError`。
JVM 测试不能替代 Android 10 真机启动验收。

2026-10-31 本地验证：`android-standalone/test.sh` 完整通过（包含上述兼容测试、
核心／短信／音频桥／云端通话／纯本地模式测试和 Standalone Debug APK 构建），
`git diff --check` 通过。ADB 未发现设备，尚未覆盖安装或验证红米冷启动。
本次仅修改本地 VoBLE 工作树；已发布的 v0.9.8.20 资产未替换，修复尚未发布。

## 真机验收

1. 用与旧包相同包名和签名的修复 APK 覆盖安装，保留数据；不要用 Debug 包覆盖正式签名包。
2. 连续冷启动并启动内置 Agent，确认不再出现该 `NoSuchMethodError`。
3. 在支持双卡的设备上切换默认 SIM 或启停 SIM，确认 iPhone 的 SIM 信息刷新。
4. 停止并重新启动 Agent，确认没有重复订阅回调，配对与通话状态仍可读取。
5. 在 Android 11 及以上重复上述流程，验证 Executor 分支未回归。

参考：[Android 官方 SubscriptionManager API](https://developer.android.com/reference/android/telephony/SubscriptionManager)。
