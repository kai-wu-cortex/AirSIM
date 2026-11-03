# 反馈仅允许手动上传

2026-10-29，未发布/未部署候选。

- iOS 和 Android 仅保留设置/调试页的“立即上传反馈”按钮。没有定时、启动、异常、通话结束、短信发送/接收后的自动反馈上传入口。
- 两端上传器在读取日志、请求 Android 快照或进入上传队列之前，只接受精确的 `trigger=manual`；其他值直接拒绝，不能通过旧调用重新启用自动上传。
- Relay `/v1/feedback` 对非 `manual`（含缺失 trigger）的请求返回 `403 manual_feedback_required`，且不上传附件、不创建 Notion 页面。部署此 Worker 后才对线上请求生效。
- `trigger` 是产品策略字段，不是鉴权机制，也不能证明用户真实点击。客户端仍必须只从手动按钮调用上传器。
- 本地日志、手动导出/分享、通话信令、APNs 与短信业务同步不属于反馈自动上传，不受此变更影响。
- 没有清除现有 Notion 反馈，没有自动补传历史反馈或新建后台重试任务。

升级边界：源码修改不等于手机上的旧版本已更新；客户端需构建安装，服务端需独立部署。此任务未执行发布、安装、生产部署或推送。

回归：iOS `ManualFeedbackPolicyTests`；Android `FeedbackUploadPolicyTests`；Relay `feedback-policy.test.mjs`（模拟 Notion，验证自动触发零外部请求、手动触发正常）。
