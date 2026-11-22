# 2026-11-22 实机基线，后续须重新核验

AirSIM的F50Pro-AirSIM路线，历史PR43/44集成后，酒店候选c0d63d2由[PR49](https://github.com/kai-wu-cortex/AirSIM/pull/49)提交，记录时未合并，不是作者最新正式版声明。

| 组件 | 摘要与边界 |
| --- | --- |
| Standalone APK | 0.9.8.25/140，ccbc903c6c08d372d19b3848c9646fc198371de0447bc4943595e7357693d75a，含挂断修复；仍核对安装证书。 |
| DSDS helper APK | 0656e974a6d7e1010f8ae7022263b005eaec70d04c45c476a1e5d9808606f7e4；取自当前设备并独立验签，证书 pin 仍按实际安装核对。 |
| 酒店runtime | 07cdf7f5b8c585f37dee262e556f80e1fc15b8b1741645727ab9fe0300bf065f，含目标网络、call-safe、DSDS监督与P2P认证。 |
| DSDS框架guard | vendor-telephony-common.jar 600edb6d53fefa464503a3d8958ccd15befce847648528a4b0439df8c738a2a0。 |
| Wi-Fi原厂JAR guard | ac1698cbfe73ae03e6497df42127943a4cb06f73f34f35955e72a96c506dd95e，按实际boot脚本检查路径。 |
| netd guard | edfea436579c95f39dd43ec5f3dc458ebc091ad60fed57c5174ead3d771448f3，不整体替换。 |
| USB ADB v2私有候选 | init_boot 8MiB，ec3c4130ef93eb9ecc0ace2173bc652702d5f11c35421a7bfa5073a8f3605e86，包含当时Mac公钥，非通刷包。 |
| TrustOS短候选 | f82f788023e950e083760df1712718f454b59ed394bccca613d72dce5a939ab2，5195528字节，不等于完整6MiB恢复副本。 |
| 后装配网boot候选之一 | 9cd83338944f2c1f84722a655a54498a1c89670a7d688d99cdebf4ab7443592b，当时基底ec3c4130…，保留32条新增10条，仍逐机核对。 |

摘要帮助识别，不证明兼容。Skill不分发镜像/密钥/凭据，历史目录名不直接映射新机。可复用证据包括两台B28的USB/配网与独立供电、原机香港卡声音与远端挂断、追加设备两实体卡注册、ZTE CN当前酒店iPhone认证与独立供电云端自检。这些属于不同日期/设备，不能拼成新机全功能通过。

家庭现有服务为GCloud、自有企业签名TestFlight，确切URL/Team/Bundle ID从受限配置核验。无凭据可以准备客户端，不能借作者APNs密钥或承诺后台推送。当前设备的简单管理/热点密码是用户对该台的选择，不作为Skill全局默认。
