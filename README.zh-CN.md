# DisplayHarbor

[English](README.md) · [官网](https://mitaraifail.github.io/displayharbor/)

DisplayHarbor 是一个原生 macOS 菜单栏工具，用来记住每个 App 窗口应该出现的位置。它会识别当前显示器环境，为 App 保存窗口规则，并在 App 启动或显示器发生变化时恢复这些规则。

## 功能

- 从菜单栏识别当前 App 和标准窗口。
- 保存窗口所在显示器、位置、大小和全屏状态。
- 一次恢复同一个 App 的多个窗口。
- 为不同的物理显示器环境分别保存规则。
- 在每个显示器环境下创建命名情景。
- 支持复制、新建、重命名、切换和删除情景。
- 显示器连接、断开或重新排列后自动重新应用规则。
- 一键打开当前情景中尚未运行的 App，并恢复窗口。
- 为每个情景配置进入时需要正常退出的 App。
- 在管理窗口中查看和维护显示器环境及 App 规则。
- 跟随 macOS 首选语言（内置 English 和简体中文）。

## 系统要求

- macOS 14 或更高版本。
- Apple Silicon（当前 Release 流程生成 arm64 版本）。
- DisplayHarbor 的辅助功能权限。

首次运行时，请在以下位置允许 DisplayHarbor 控制窗口：

`系统设置 → 隐私与安全性 → 辅助功能`

如果打开菜单栏面板时仍未授权，DisplayHarbor 会自动打开一次这个设置页面进行引导，同时保留“打开辅助功能设置”按钮作为兜底。

## 从 GitHub Release 安装（推荐）

普通用户应从 [GitHub Releases 页面](https://github.com/mitaraifail/displayharbor/releases/latest) 下载最新的 arm64 **DMG**。ZIP 会保留作为脚本化或手动安装的备用方式。除非你是在开发 DisplayHarbor，否则不需要运行 `swift run` 或 `build-app.sh`。

1. 下载 `.dmg` 文件及其对应的 `.sha256` 校验文件。校验文件不是安装程序。
2. 在终端中校验 DMG（可选）：

   ```bash
   archive="DisplayHarbor-v0.1.4-macos-arm64.dmg"
   shasum -a 256 -c "$archive.sha256"
   ```

3. 打开 DMG，将 `DisplayHarbor.app` 拖到“应用程序”快捷方式。
4. GitHub Release 会由 Actions 使用 Developer ID 签名并提交 Apple 公证。首次启动后，请在“系统设置 → 隐私与安全性 → 辅助功能”中授权 DisplayHarbor。

ZIP 备用方式：

   ```bash
   archive="DisplayHarbor-v0.1.4-macos-arm64.zip"
   shasum -a 256 -c "$archive.sha256"
   ditto -x -k "$archive" .
   mv DisplayHarbor.app /Applications/
   ```

如果 Finder 显示通用占位图标，安装后重新启动 Finder。如果 macOS 提示 App 已损坏，请先重新下载 Release 并校验 checksum，再进行其他处理。

## 更新软件

DisplayHarbor 会通过 Sparkle 定期检查经过签名的 appcast。当发现新版本时，Sparkle 会验证更新包并在 App 内显示更新流程，可以自动下载、安装并重新启动 DisplayHarbor。

如果 Sparkle 不可用，或者你希望手动安装更新，仍然可以从 [GitHub Releases 页面](https://github.com/mitaraifail/displayharbor/releases/latest) 下载新的 DMG 并校验 checksum，退出 DisplayHarbor，然后将新的 App 拖到 `/Applications`。规则保存在 `~/Library/Application Support/DisplayHarbor/environments.json`，替换 App 不会删除这些数据。

## 从源码运行

```bash
swift run
```

生成可双击运行的 App：

```bash
zsh build-app.sh
open dist/DisplayHarbor.app
```

`build-app.sh` 要求本机已安装 Developer ID Application 证书，并会生成启用 Hardened Runtime 的签名 App。GitHub Release 工作流还会继续提交 Apple 公证；如果签名或公证 Secrets 未配置，工作流会失败，不会发布未签名或未公证的 Release。

## 使用方式

1. 启动 DisplayHarbor 并授予辅助功能权限。
2. 将 App 窗口摆放到目标显示器。
3. 从菜单栏打开 DisplayHarbor。
4. 为当前 App 保存布局。
5. 打开“管理环境与 App 规则”查看规则和情景。
6. 使用“应用当前情景”打开尚未运行的 App，并恢复已保存窗口。
7. 在情景下方的“进入情景时退出的 App”区域添加需要在切换时退出的工作 App。

## 数字授权

DisplayHarbor 支持砖块儿 `mbd-license-v1` 软件授权协议。未激活时可以使用默认工作区；新增、重命名和删除命名工作区需要有效授权。

首次激活后，客户端会把安装私钥保存在 macOS 钥匙串中，只向砖块儿提交安装公钥。激活成功后，设备证书在本地验签，软件可以离线运行；激活码和证书不会写入布局规则文件。

正式发布前，在 `Resources/Info.plist` 中填入授权商品生成的公开配置：

- `MBDLicenseAppID`：授权商品的 `app_id`。
- `MBDLicensePublicKey`：授权商品的 Ed25519 公钥。
- `MBDLicensePurchaseURL`：砖块儿授权商品购买页地址。

也可以在执行 `build-app.sh` 时通过 `DISPLAYHARBOR_LICENSE_APP_ID`、`DISPLAYHARBOR_LICENSE_PUBLIC_KEY` 和 `DISPLAYHARBOR_LICENSE_PURCHASE_URL` 注入这些值，适合 CI 构建。

GitHub Release 工作流从仓库 Variables 读取同名配置；在授权商品创建完成后，应配置这些 Variables 再推送正式 tag。软件运行时不要求砖块儿在线。

公钥可以随 App 分发；不要把平台签名私钥、买家激活码或设备私钥写入仓库。

退出规则会在切换到对应情景时向已运行的 App 请求正常退出，不会强制终止进程。如果 App 有未保存内容，macOS 仍会按照 App 自身的保存流程处理。一个 App 不能同时拥有当前情景的窗口布局规则和退出规则。

规则保存在：

`~/Library/Application Support/DisplayHarbor/environments.json`

用户自定义的环境名、情景名和 App 规则会按输入原样保留。内置文案会在运行时本地化，因此切换 macOS 首选语言后，重启 App 即可生效。

## GitHub Release

推送 `v*` tag 后，[`.github/workflows/release.yml`](.github/workflows/release.yml) 会自动构建并发布：

```bash
git tag v0.1.4
git push origin v0.1.4
```

工作流会构建、验证并上传：

- `DisplayHarbor-<version>-macos-arm64.zip`
- `DisplayHarbor-<version>-macos-arm64.zip.sha256`
- `appcast.xml`（Sparkle 自动更新 feed）
- `DisplayHarbor-<version>-macos-arm64.dmg`（推荐安装包）
- `DisplayHarbor-<version>-macos-arm64.dmg.sha256`

### GitHub Actions 签名与公证配置

Release 工作流需要在仓库的 **Settings → Secrets and variables → Actions** 中配置以下 Secrets：

- `DISPLAYHARBOR_SIGNING_P12_BASE64`：从钥匙串导出的 Developer ID Application `.p12` 文件的 base64 内容。
- `DISPLAYHARBOR_SIGNING_P12_PASSWORD`：导出 `.p12` 时设置的密码。
- `DISPLAYHARBOR_NOTARY_APPLE_ID`：加入 Apple Developer Program 的 Apple ID 邮箱。
- `DISPLAYHARBOR_NOTARY_APP_SPECIFIC_PASSWORD`：为这个 Apple ID 生成的 App 专用密码，不是 Apple ID 普通密码。
- `DISPLAYHARBOR_NOTARY_TEAM_ID`：Apple Developer Team ID，例如 `6ABLTPWC78`。
- `DISPLAYHARBOR_SPARKLE_EDDSA_PRIVATE_KEY`：从 Sparkle 的 `generate_keys` 工具导出的 EdDSA 私钥，只保存到 GitHub Secrets。

私钥、`.p12` 密码、API Key 和 EdDSA 私钥不要提交到 Git。工作流会在 GitHub runner 的临时钥匙串中导入证书，完成签名、公证、票据装订、checksum 和 Sparkle appcast 生成。

## 显示器环境与情景

DisplayHarbor 根据已连接的物理显示器、排列位置、分辨率和主屏关系识别显示器环境。不同环境的规则互不覆盖。

每个环境默认包含一个内置“默认”情景。你可以复制当前情景创建新情景，然后进行重命名、切换或删除。内置默认情景会始终按当前界面语言显示。

## 当前限制

- 多窗口匹配使用窗口标题、保存时尺寸和窗口顺序；窗口 ID 改变本身不会阻止恢复。
- 自动恢复只会移动已经存在的窗口，不会创建缺少的窗口。
- DisplayHarbor 不会主动切换 macOS Space，也不会创建原生全屏 Space。
- 当前 Release 仅支持 arm64。

## License

暂未选择许可证。
