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

合并到 `dev` 分支后会自动运行测试并构建 macOS 安装包。到 GitHub Actions 对应运行记录的 Artifacts 下载 `.dmg`，打开后将 `CodexUsage.app` 拖到「Applications」即可。

这是开发构建，未配置 Developer ID 签名和公证；首次打开时 macOS 可能需要在「系统设置 → 隐私与安全性」中手动允许。

正式版本通过 Tag 构建：

```sh
git tag v0.1.0-rc.1   # 候选版本
git push origin v0.1.0-rc.1

git tag v0.1.0         # 正式版本
git push origin v0.1.0
```

`rc` Tag 会创建 GitHub Pre-release，正式 Tag 会创建普通 GitHub Release，并附带 DMG 与 SHA256 校验文件。当前发布包仍是开发签名，暂未配置 Developer ID 签名和 Apple 公证。
