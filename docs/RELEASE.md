# 发布说明

源码保存在 [lhzzzzzzz/ScreenGPT](https://github.com/lhzzzzzzz/ScreenGPT)，安装包通过 [GitHub Releases](https://github.com/lhzzzzzzz/ScreenGPT/releases) 提供。`dist/` 不进入 Git 历史；每个 Release 附带 DMG、ZIP 和 SHA-256 校验文件，GitHub 同时提供对应标签的源码归档。

## 当前测试版

`v0.2.1` 为当前公开测试版（Pre-release），使用 ad hoc 临时签名，尚未 Apple 公证。macOS 可能拦截首次启动；Release 和 README 均说明该限制。本机已验证真实截图、翻译和多轮提问；Intel 实机、多显示器、macOS 14 干净安装及公证安装仍待验收，检查结果见 [VERIFICATION.md](VERIFICATION.md)。

## 构建与校验

需要 macOS 与 Swift 6。版本号定义在 `scripts/build.sh` 的 `VERSION`，更改后同步更新版本记录、下载链接和 Release 标签。

```sh
swift test
./scripts/package.sh
codesign --verify --deep --strict dist/ScreenGPT.app
hdiutil verify dist/ScreenGPT-macOS.dmg
lipo dist/ScreenGPT.app/Contents/MacOS/ScreenGPT -verify_arch arm64 x86_64
cd dist
shasum -a 256 ScreenGPT-macOS.dmg ScreenGPT-macOS.zip > SHA256SUMS.txt
```

CI 在 GitHub Actions 的 macOS 15 环境运行测试、构建通用应用、校验并上传构建附件。它不会自动发布新版本；用于下载的长期附件放在 GitHub Releases。

## 正式签名与公证

正式发行版应使用 Apple Developer ID 身份签名并完成 Apple 公证；当前仓库不包含证书或公证凭据。

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notarytool-keychain-profile" \
./scripts/package.sh
```

公证配置预先通过 `xcrun notarytool store-credentials` 存入本机钥匙串。Apple ID 密码、App 专用密码、API 私钥、证书和钥匙串导出内容都不应提交到仓库。正式包还需要在另一台 Mac 检查 Gatekeeper 和安装流程。

## 发布一个版本

1. 完成相应测试，在验证记录中明确哪些已通过、哪些尚未验证。
2. 将源码提交到 `main`，确认版本号一致，为该提交建立版本标签。
3. 创建 GitHub Release 并上传 DMG、ZIP、SHA256SUMS.txt。尚未完成签名或验收的版本标记为 Pre-release。
4. 检查三个附件能下载、校验和一致，README 的下载链接指向该版本。

构建成功不能代替真实 UI、OAuth、套餐资格、联网响应和安装体验的验收。
