---
name: f50skill
description: 部署、升级或排障中兴 F50 Pro 的 USB ADB、双卡保持、AirSIM 云端、独立供电自启动和 iPhone 酒店 Wi-Fi 认证；先按机型、固件与本机备份核验兼容性。适用于全新机和保留配对升级，不能把 MU3356 B28 镜像通刷到其他固件。
---

# F50Skill

把一台属于用户的 F50 Pro 做成可独立供电、自动连接指定 Wi-Fi、从 iPhone 使用 AirSIM 云端的设备。中文沟通，实际结果逐台记录。当前实机基线为 **MU3356 / F50ProV1.0.0B28 / Android 15**，不是所有叫 F50 Pro 的硬件都已适配。

## 先定位，再选择路径

1. 识别当前 Mac、ADB 工具、目标 USB 序列号、机型/固件、活动槽、安装包与已有授权。每条 ADB 命令明确 `-s SERIAL`，不猜上一台序列号。
2. 定位 `kai-wu-cortex/AirSIM` 的 `F50Pro-AirSIM` 分支及所需提交，**不是 AirSIM-mu300**。读仓库规则、组件 README 和实际源码。相同版本号仍比较摘要与签名。可先查看 `~/.config/f50skill/local.json` 的路径提示，再验证文件和摘要；该文件不是部署授权。
3. ADB 可用：运行 `scripts/preflight.py device --adb /path/to/adb --serial SERIAL --out /private/path/report.json`。只读核对，不开调试、不刷机、不改配对，不采集号码/IMSI/ICCID/密码/令牌。
4. ADB 不可用或全新原厂机：读 [bootstrap.md](references/bootstrap.md)，先检查 USB 和原厂开关，再决定是否需要下载模式或启动修改。历史刷写授权不沿用到另一台设备。
5. 已有 ADB/配网/配对：读 [deployment.md](references/deployment.md)，备份后增量更新，不重复刷正常启动链。只要求回归时直接读 [acceptance.md](references/acceptance.md)，不顺便升级。

## 成品范围

- USB ADB 保持密钥认证及用户 Mac 公钥，原 USB 网卡与管理页保留；不默认开放 TCP 5555。
- 双卡保持、默认电话、VoLTE/PCM 桥及自启动。**卡槽保持启用不等于注册成功**，双待不等于两路并发通话；每卡通话/短信和双向音频分别实测。
- 保存多个 Wi-Fi，开机只连指定目标；系统就绪且运行满 60 秒后切换，连接失败最多再等 90 秒恢复原热点。不是断电后恰好 60 秒联网。
- 指定酒店网络未通过 HTTPS 时开启临时 P2P 热点供 iPhone 认证，见 [酒店操作及排障](references/hotel-and-troubleshooting.md)。原热点、认证热点、管理页是不同入口。
- 使用用户当前 Relay 和匹配签名的 iOS App；新机独立生成身份、配对及桥接令牌，不复制成品机 userdata。
- 密码按本次用户明确选择设置，否则分别生成；不把某台的简单密码当成所有新机默认值，不把凭据写入 Skill、Git 或普通总结。

## 执行与恢复

持续完成已有授权范围内的备份、设置和部署，不反复询问。同一台尚未授权分区写入时，先准备完整备份、候选摘要、目标分区与恢复步骤供审阅，再请求该具体步骤授权。固件未知、摘要不符、完整备份不足或活动槽未确定时，只停止依赖这些条件的写入，继续诊断；不删校验断言，不试刷别机镜像。

原厂拒绝、下载窗口错过和 USB 会话中断不构成重复刷写理由。先启动恢复监听再请用户拔插。候选启动失败先恢复本次写入前可启动副本，按新证据修订。临时重建分区表仅限已核验的对应 B28 工具路线，不是所有新机的必经步骤。

## 交付

按 [验收矩阵](references/acceptance.md) 分别记录通过/失败/待实测/不适用，区分接 Mac 重启、独立电源冷启动、工具观测、iPhone 反馈、真实通话与 CI。[基线](references/baseline.md) 是带日期的证据，不是永久最新版声明。遵守用户总结目录和 Git/PR 工作流，固件与凭据留在受限目录；不把另一台成功、构建成功或云端自检拼成本机全功能通过。
