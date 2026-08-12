# FantaLogcat

FantaLogcat 是一款原生 macOS Android Logcat 查看器。连接 Android 设备、选择应用进程后，即可在 Mac 上实时查看、筛选、搜索并导出该进程的日志。

[应用主页](https://lijing233.github.io/FantaLogcat/) · [下载最新版](https://github.com/lijing233/FantaLogcat/releases/latest) · [问题反馈](https://github.com/lijing233/FantaLogcat/issues)

## 界面预览

### 应用选择

从最近使用、收藏或设备上的全部已安装应用中快速定位目标，也可以按应用名和应用 ID 搜索。

![FantaLogcat 应用选择界面](docs/images/app-picker.jpg)

### 实时日志与组合搜索

在同一个窗口中查看目标进程的实时日志、切换优先级、暂停或清屏，并通过关键词卡片和 `OR` / `AND` 关系构建组合查询。

![FantaLogcat 实时日志与组合搜索界面](docs/images/log-view.jpg)

## 主要功能

- 选择已连接的 Android 设备、应用与进程，专注查看单个进程的 Logcat。
- 按日志优先级筛选，并使用 `OR` / `AND` 组合多个搜索关键词。
- 收藏常用关键词，快速复用搜索条件。
- 限制历史日志条数和文本缓存大小，避免长时间会话无限占用内存。
- 导出前可对常见 token、密码和密钥模式进行脱敏，默认启用脱敏。
- 设置采用“关闭放弃、保存生效”的原子交互，保存失败时不会覆盖当前配置。
- 按需下载 Google 官方 Android Platform-Tools，并在安装前校验 SHA-256。

## 下载与安装

推荐从 GitHub Releases 下载 `FantaLogcat-macos-arm64.dmg`：

1. 双击打开 DMG。
2. 将 `FantaLogcat.app` 拖到窗口中的 `Applications` 快捷方式。
3. 安装完成后，可在“应用程序”、Launchpad 或 Spotlight 中搜索 **FantaLogcat** 并启动。
4. 确认应用正常打开后，可以推出并删除下载的 DMG。

也可以下载 ZIP，解压后手动将 `FantaLogcat.app` 移入“应用程序”目录。DMG 和 ZIP 均提供同名 `.sha256` 文件，可在下载目录中校验：

```sh
shasum -a 256 -c FantaLogcat-macos-arm64.dmg.sha256
```

公开发布版本仍需由维护者使用 Apple Developer ID 签名并完成公证。未公证的本地构建可能被 Gatekeeper 拦截；请右键应用选择“打开”，或在“系统设置 → 隐私与安全性”中仅为该应用选择“仍要打开”，不要全局关闭 Gatekeeper。

## 系统要求

- Apple 芯片 Mac（`arm64`），macOS 13 或更高版本。
- 已启用“开发者选项”和“USB 调试”或“无线调试”的 Android 设备。
- 使用 USB 调试时，需要可传输数据的 USB 线，并在设备上确认调试授权。

FantaLogcat 不要求用户预先安装 `adb`。首次需要 Android 工具时，阅读 Google 许可条款并选择“接受并安装”；应用会下载官方 Platform-Tools、校验 SHA-256，并将其保存在本机应用支持目录中。

## 使用方法

1. 通过 USB 连接设备，或完成无线调试配对。
2. 如设备弹出授权提示，请允许这台 Mac 进行调试。
3. 在 FantaLogcat 中选择设备以及需要查看的应用或进程。
4. 开始采集日志，根据需要设置优先级和组合搜索条件。
5. 需要分享日志时打开导出面板，检查脱敏结果后再保存文件。

## 隐私与日志导出

采集到的日志仅保存在内存中，不会自动写入持久化日志档案；收藏内容和设置保存在本机。导出必须由用户主动执行。

导出脱敏能够识别常见 token、密码和密钥模式，但无法保证覆盖所有秘密信息、个人数据或专有内容。分享前请务必人工检查导出文件。

## 本地开发

项目使用 Xcode 26.6、Swift 6.3.3、Mint 0.18.0 和 XcodeGen 2.46.0。常用命令：

```sh
make generate   # 生成 Xcode 工程
make test       # 运行单元测试和 UI 测试
make build      # 构建 Release 应用
make release    # 生成 DMG、ZIP 及 SHA-256 校验文件
```

`make release` 会在 `build/releases` 生成：

- `FantaLogcat-macos-arm64.dmg` 与 `FantaLogcat-macos-arm64.dmg.sha256`
- `FantaLogcat-macos-arm64.zip` 与 `FantaLogcat-macos-arm64.zip.sha256`

## 当前限制

- 当前版本一次专注查看一个选定进程，不用于完全替代所有 Android 调试工具。
- 设备是否可用取决于 ADB 连接状态和设备调试授权。
- 无线调试必须在设备上保持开启，并与 Mac 网络互通。
- 自动脱敏只识别常见模式，导出内容仍需人工复核。

## 参与项目

- [贡献指南](CONTRIBUTING.md)
- [安全策略](SECURITY.md)
- [行为准则](CODE_OF_CONDUCT.md)
- [Apache License 2.0](LICENSE)
- [第三方声明](NOTICE)
- [发布检查清单](docs/RELEASE_CHECKLIST.md)
