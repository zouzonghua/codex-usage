# CodexUsage

一个极简的 macOS 菜单栏应用，只做三件事：

- 查看 Codex 5 小时 / 周额度与重置时间
- 查看可用的 Codex 重置额度及最近到期时间
- 切换已保存的 Codex 账号

## 设计取舍

- SwiftPM 原生实现，零第三方依赖，macOS 14+。
- 只读取 `~/.codex/auth.json`（或 `CODEX_HOME/auth.json`）和应用自己保存的账号目录。
- 通过 Codex OAuth 使用接口读取额度；不主动刷新 token，不读取浏览器 Cookie，也不会上传或打印 token。
- “切换账号”会先备份当前账号，再原子替换当前的 `~/.codex/auth.json`，因此 Codex CLI 会同步切换；应用不会刷新 token。
- 添加账号时会在独立的 `~/Library/Application Support/CodexUsage/accounts/<id>` 中执行 `codex login`。

## 运行

```sh
swift run CodexUsage
```

## 验证

```sh
swift test
swift build
```

重置额度仅展示服务端返回的可用数量和到期时间；应用不会自动兑换或修改额度。

## GitHub Actions

向 `dev` 或 `main` 提交 PR 时会自动运行测试与构建。

合并到 `dev` 后，会根据 Conventional Commits 自动计算下一个版本，使用 GitHub Actions 运行编号生成递增的 Beta Tag（例如 `v0.2.0-beta.12`），并创建包含 DMG 与 SHA256 校验文件的 GitHub Pre-release。

使用 merge commit 将 `dev` 合并到 `main` 后，会把最新 Beta 提升为同版本号的正式 Tag（例如 `v0.2.0`），并创建 GitHub Release。不要使用 squash 或 rebase 合并。

发布任务会串行执行。等待当前 `Auto Release` 完成后，再合并下一次发布变更，避免 GitHub 取消排队中的旧任务。

Beta 版本递增规则：

- `fix:` / `perf:`：递增补丁版本
- `feat:`：递增次版本
- `BREAKING CHANGE:` 或带 `!` 的提交：递增主版本
- 其他提交：不生成新版本

首次发布使用 `Resources/Info.plist` 中的版本作为起始版本。

当前发布包仍使用 ad-hoc 签名，暂未配置 Developer ID 签名和 Apple 公证；首次打开时 macOS 可能需要在「系统设置 → 隐私与安全性」中手动允许。
