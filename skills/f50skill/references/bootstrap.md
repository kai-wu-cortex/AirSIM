# 全新原厂机：USB ADB 与恢复

## 先检查可逆入口

只读 USB 枚举、线缆供电、Mac 配件许可、原厂后台型号/硬件/固件。无电池设备换电源即冷启动。使用该设备已登录会话，不混用另一台。原厂开关可能被拒绝；以 USB devpath、shell 和实际文件写读判断，不只看网页响应。

保持 `ro.adb.secure=1`。正常 ADB 两分钟后掉线时先看 `settings get global adb_enabled`：现场曾因值 0 导致接口关闭，改 1 后两次重启各约七分钟连续读写通过，无需常亮或关闭认证。USB 完全不见先查硬件层；若三秒反复枚举，依据日志检查 AOA/占用软件，不能把工具 README 的 WeChat 案例套用到每次掉线。

## 写入前所需材料

- 目标自己的原始分区表及导出表、`misc` 启动控制区、活动槽与 CRC，真实机型/固件。
- 完整 A/B `init_boot`、`trustos`、`sml` 及所有将修改分区的备份，尽可能做整机只读备份；逐文件记录实际长度、SHA-256、设备和工具版本。不复制他机 NV、persist、prodnv、userdata。
- spd_dump 可能裁掉 TrustOS 尾部填充。按分区表长度补读/禁用裁剪，不用补零冒充原副本。现场 init_boot 8 MiB、trustos 6 MiB 只是已见值，新机仍实读。
- 对应固件的 FDL1/FDL2、核验来源的工具、连接参数和已用读取验证的恢复路径；不猜加载地址、偏移或调用未知一键 root。
- 当前 Mac ADB 公钥、候选及离线验证 manifest；含公钥的镜像也按私有设备产物保存。

`scripts/preflight.py verify-artifacts MANIFEST` 仅核验清单列出的文件长度/摘要，**不证明 A/B 恢复材料齐全、固件/槽位/分区兼容，也不刷写**。仍需人工核对上方全部备份要求。manifest 含 device_serial、firmware、files 数组；每项需 role、path、bytes、sha256。path 相对 manifest 目录或绝对路径；填写来自实读的值，不能拿示例代替。

## B28 已验证路线及恢复

历史原厂 B28 使用启动组件及 TrustOS 修改提供 USB ADB。第一版镜像能启动、网页正常，却没有 ADB；v2 等 USB 网卡、系统启动和密钥目录就绪，再在 Magisk 服务上下文设置 USB 组合。没有单独归因时序与上下文各自作用，不删等待步骤。

复用候选前，新机完整原始文件、布局、活动槽、固件与公钥必须符合该候选的适用条件。新的 Wi-Fi 启动镜像以本机已验证的可启动镜像为基础，保留原条目，仅改明确列出的项目；比较 ramdisk 每项、长度、AVB blob、USB 初始化与变更清单。

`android-standalone/f50-wifi/prepare-b28.py` 只支持其写明的一个基底 SHA，并依赖已有修复条目；不是原厂通用构建器。它还会拒绝已有内嵌 DEX。不能删除 BASE_SHA256/条目断言来适配新基底；不同基底重新做条目保留与固件分析。

历史 B28 force 路径会临时使用 `w_force` 分区别名。先核对锁定工具源码、实际会话协议与原始布局，逐目标写入，随后**按原分区名完整回读**。短 TrustOS 候选还要确认未覆盖尾部等于本机原副本。再次导出分区表，和原始响应比较，确认原分区名及数量恢复、无 w_force 遗留，才重启。不可推广为未知设备的通用 GPT 重建。

会话断开后旧连接可能无法接管：结束旧会话，监听就绪再要求完整断电/插线。候选不启动时恢复本次写入前副本并回读，再研究新候选；不擦 userdata/NV，不反复刷同样内容碰运气。

## 工具与证据入口

- [joker-skills/f50pro-MacOS-tools](https://github.com/joker-skills/f50pro-MacOS-tools)：本次另行核验的 checkout 为 `5cf272702e97196525de2a05d8f3bc9855d14ce1`。其快速开始及包配置以 **B25** 为例，不是本成品 B28 的配方；不要直接运行 flash-root/restore 默认参数，也不要按其示例改成网络5555或安装其他软路由/Tailscale组件。先读 bin/backup.sh、read-part.sh、flash-init-boot.sh、restore.sh 及所引用配置，取得目标匹配的FDL/包/编译工具。Skill准备时仅下载源码，没有运行这些刷写脚本。
- [spreadtrum_flash common.c 历史固定提交](https://github.com/TomKing062/spreadtrum_flash/blob/607f70147763c878e46d7b6eeccc2a6cd34b8f61/common.c)：核对 force 协议，不能直接当新机命令。
- 私有原副本、v2 候选、读回与第二台对照日志通常在 `F50 Pro/Firmware Backups`，由 local.json 定位；文件或工具缺失先查备份/取得匹配来源，路径提示不代表文件存在。

启动第一道验收：USB shell、正确槽、系统启动完成、ncm/mtp/adb、adb_enabled=1、认证公钥、原管理页与网卡、真实文件读写、原分区表。持续跨过之前两分钟掉线窗口，再进行上层部署。
