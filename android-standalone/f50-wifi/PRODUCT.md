# F50 Pro Wi-Fi 配置

## Platform
web

## Users and purpose
设备所有者用 iPhone Safari 在本地配置 F50 Pro 的上游 Wi-Fi。需要保存多个网络，重启自动连接可用的已保存网络，同时保持 USB ADB 可用。

## Scope
本页只管理 Wi-Fi，不改变 SIM、AirSIM 配对、USB 组合或固件版本。当前 MU3356 B28 已有客户端补丁和 wlan0 地址保护。无可用网络时返回原热点，让 iPhone 仍能进入设置。页面需登录，不显示已保存网络的密码。

## Implementation choices
使用设备本地 Java 服务和自包含 HTML/CSS/JavaScript；不依赖 CDN、云端或前端框架。采用手机设置页的列表与内联表单，简体中文，操作目标至少 44px。这些是本任务的实现选择，不代表 AirSIM 全项目设计规范。
