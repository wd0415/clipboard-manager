# Clipboard Manager MVP

当前版本是离线 macOS MVP：不登录、不联网，后台记录文本和图片剪贴板历史，并保存在本机 SQLite。

## 运行

```bash
cd /Users/wangdong/Documents/work_space/clipboard-manager
swift run --disable-sandbox ClipboardManagerApp
```

也可以生成可双击运行的菜单栏应用：

```bash
./scripts/build-app.sh
open "dist/Clipboard Manager.app"
```

启动后：

- 菜单栏出现 `📋` 图标。
- 复制文本或图片后，内容自动写入本地历史。
- 使用 `⌘⇧V`，或点击菜单栏图标中的“显示历史”，打开历史面板。
- 点击历史条目即可将文本或图片写回系统剪贴板。
- 数据保存在 `~/Library/Application Support/ClipboardManager/history.sqlite3`。

当前 MVP 不包含登录、云同步、运营后台和 Windows 客户端；这些会在离线体验稳定后接入。

## 验证

```bash
swift build --disable-sandbox
swift test --disable-sandbox
```
