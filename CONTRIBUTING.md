# 贡献指南

欢迎提交问题报告和改进。请先阅读项目根目录的 `README.md`，以及 `docs/DEVELOPMENT.md`、`docs/PRIVACY.md` 和 `docs/RELEASE.md` 中与改动相关的说明。

## 环境与验证

- 需要 macOS 14 或更新版本，以及 Swift 6（Xcode 16 或对应的 Command Line Tools）。
- 运行自动测试：`swift test`
- 构建应用及安装包：`./scripts/package.sh`。产物位于 `dist/`。
- 人工验收记录见 `docs/VERIFICATION.md`；开发验收步骤见 `docs/DEVELOPMENT.md`。

## 文档与截图

请在行为或使用方式变化时更新 `README.md` 或相应的 `docs/` 文档。README 中的预览图位于 `docs/images/`，来源为应用内置预览及合成示例内容；更新截图时请使用合成内容，避免包含个人或账号信息。
