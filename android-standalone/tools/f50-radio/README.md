# F50 Pro 临时注册诊断

供已授权的 MU3356 USB ADB 排障使用；不是自动修复、安装包或开机服务。不会拨号、发短信、改网络制式掩码、写基带、刷分区或输出号码、IMSI、ICCID。只在 shell UID 2000 和 MU3356 上运行；写操作还要求所有活动卡均无通话，并按当前订阅的国家与公开运营商代码校验目标。订阅 ID 必须从本次 `status` 读取，不能复用旧记录。

## 构建与使用

需要 JDK 17 或更新版本、Android SDK Platform 35 和 Build Tools 35.0.0。`ANDROID_HOME` 默认指向 macOS 用户目录的 `Library/Android/sdk`。现场验证的系统为 Android 14。

```sh
JAVA_HOME=/path/to/jdk sh android-standalone/tools/f50-radio/build.sh
adb -s SERIAL push android-standalone/tools/f50-radio/build/f50-radio-check.dex /data/local/tmp/f50-radio-check.dex
adb -s SERIAL shell chmod 600 /data/local/tmp/f50-radio-check.dex
adb -s SERIAL shell 'CLASSPATH=/data/local/tmp/f50-radio-check.dex app_process -Xmx64m /system/bin --nice-name=f50-radio-check com.airsim.tools.F50RadioCheck status'
```

`status` 返回运营商代码、选网模式、漫游/数据开关、允许的制式、无线电电源、IMS 与默认语音/数据订阅。它不等同于完整的网络注册诊断；应结合经过脱敏的 ServiceState。`network_operator` 有值、`radio_power=1` 或 SIM 已加载都不能证明已注册成功。

将最后的 `status` 换成以下命令可做有限的对照测试：

| 命令 | 范围与效果 |
| --- | --- |
| `roaming SUB true` / `false` | 仅英国、SIM 运营商 `23433`；更改数据漫游 |
| `data-enabled SUB true` / `false` | 同上；更改用户移动数据开关 |
| `select-cmhk SUB` | 同上；临时指定 `45412`，不要求跨重启保存 |
| `automatic SUB` | 同上；恢复自动选网 |
| `default-data SUB` | 同上；临时改为主数据卡，不更改默认语音/SMS |
| `restore-hk-data SUB` | 仅香港、SIM 运营商 `45400`；恢复该卡为主数据卡 |

写操作仅表示请求已提交，须稍后重新读取状态。尤其手动选网返回 `false` 时仍可能已经进入手动模式，失败后也要明确恢复自动选网。切换主数据卡可能连带改变其他卡的数据开关；必须先保存两卡基线，结束后逐项复核。工具有意不提供任意 AT 命令或关闭卡槽的接口。

现场发现 vendor AT 查询接口出现 `bad array lengths`，无法可靠读取扩展拒绝原因，因此该实验接口未保留。不能把没有拒绝码解释为网络未拒绝。

排查结束后删除临时 DEX：

```sh
adb -s SERIAL shell rm -f /data/local/tmp/f50-radio-check.dex
```

现场验证与未解决问题见 [CMHK 对照记录](../../../docs/f50pro-cmhk-diagnostic.md)。
