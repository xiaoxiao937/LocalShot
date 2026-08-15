# LocalShot 0.1.10 隐私与安全审计

审计日期：2026-08-15

## 已通过项目

- Release 构建成功。
- 应用包签名结构完整。
- Hardened Runtime 已开启。
- App Sandbox 已开启。
- 仅包含“用户选择文件读写”沙箱权限。
- 不包含网络客户端或网络服务器权限。
- 不包含 `get-task-allow` 调试权限。
- 不链接 CFNetwork、Network、WebKit 或私有框架。
- 未发现 URLSession、socket、connect、getaddrinfo 等网络 API。
- 未发现 HTTP、HTTPS、WebSocket 地址。
- 隐私清单声明不跟踪、不收集数据。
- 已在 Xcode 27.0 beta 3（27A5218g）中以标准 macOS App 工程成功编译并运行。
- 首次启动欢迎页验证通过，进入菜单栏前未触发录屏或其他敏感权限请求。
- 运行期间未发现 LocalShot 的 TCP 或 UDP 网络连接。
- 对勾完成路径只写入系统剪贴板，不向应用容器写入截图缓存、历史记录或缩略图。

## 当前构建校验值

- 可执行文件 SHA-256：`7590ef1879bcef5b403008d07658c3bf2f92e85c1c4c5dd43ddb5794fd1b0a4b`
- 分发压缩包 `LocalShot-0.1.10-macOS.zip` SHA-256：`3efb2e8fe35381833d82199c440fd243749f631c4525f575b67a51a8c96cccb2`

## 发布前仍需完成

- 使用开发者自己的 Developer ID Application 证书重新签名。
- 提交 Apple 公证并装订公证票据。
- 在用户明确授予录屏权限后，完成 `TESTING.md` 中截图与编辑部分的手工验收。
- 每次重新构建后更新 SHA-256。

当前压缩包是本机测试包，使用临时签名，不应直接作为公开发行版本。
