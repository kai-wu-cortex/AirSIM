# F50 Pro Wi-Fi 配置

## Platform
web

## Users and purpose
设备所有者用 iPhone Safari 在本地配置 F50 Pro 的上游 Wi-Fi。先连接设备原热点，填写并保存目标网络，点击“保存并重启”后切换指定网络；连接失败恢复并保持热点。可保存多个网络但仅自动连接指定目标，USB ADB 在重启后仍可用。

## Scope
本页只管理 Wi-Fi，不改变 SIM、AirSIM 配对、USB 组合或固件版本。当前 MU3356 B28 已有客户端补丁和 wlan0 地址保护。无可用网络时返回原热点，让 iPhone 仍能进入设置。页面需登录，不显示已保存网络的密码。

## Implementation choices
使用设备本地 Java 服务和自包含 HTML/CSS/JavaScript；不依赖 CDN、云端或前端框架。采用手机设置页的列表与内联表单，简体中文，操作目标至少 44px。这些是本任务的实现选择，不代表 AirSIM 全项目设计规范。
