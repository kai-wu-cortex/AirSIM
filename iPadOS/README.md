# AirSIM iPhone / Apple Watch

此目录仅用于三星 Android 电话端的 VoWLAN 与独立云端 Relay。打开 `AirSIM.xcodeproj`，使用 `AirSIM` scheme 构建。新的 Bundle ID 为 `com.eric3u.airsim*`，可与原 DJOneHub 并存。

首次启动引导两台设备进入同一局域网、在三星端启动 AirSIM 音频桥，并通过六位配对码建立私网控制通道。设置页仅提供三星配对、VoWLAN 状态和独立 Relay 地址；云端模式可单独开关。iPhone 和 Watch 的拨号、接听、短信及媒体链路应只使用已验证的三星配对路线或独立 Relay。

大疆 4G 模块的 USB ECM 首次连接向导、固件更新 UI、Agent 维修页面和 `.djupdate` 资源未进入 AirSIM App。旧 `.moduleLocal` 协议枚举暂供兼容共用模型，但请求层会在联网前拒绝它，不会访问 `192.168.225.1`。部分旧类型名、协议字段及非入口代码仍在共用源文件中；这些不代表三星功能，后续应在专门重构中继续删减。

本项目未迁移原 App 的配对凭据、APNs 密钥或生产 Relay 配置，也未完成三星实机双向通话验证。新包名需要重新签名、配对与授权。
