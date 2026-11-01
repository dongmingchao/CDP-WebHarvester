# CDP 抓取器

> Attention：Vibe Coded！

这是一个运行在 Windows PowerShell 上的轻量网页抓取工具。它通过 Chrome DevTools Protocol（CDP）控制 Lightpanda，在指定网页加载后按 CSS 选择器提取结果，并输出每项的名称、相对路径和完整 URL。

## 工作流程

1. 连接本机 CDP WebSocket：`ws://127.0.0.1:9222`。
2. 关闭已有页面，创建并附加一个新页面。
3. 导航到目标 URL，读取 `Page.*` 事件并等待页面内容稳定。
4. 使用 `Runtime.evaluate` 执行 DOM 查询，分批提取匹配元素。
5. 输出可读列表和 JSON，最后关闭页面。

CDP 通信辅助函数位于 [`scripts/cdp_core.ps1`](scripts/cdp_core.ps1)，主抓取脚本位于 [`scripts/cdp_fetch.ps1`](scripts/cdp_fetch.ps1)。

## 前置条件

- Windows PowerShell 5.1 或兼容的 PowerShell。
- Lightpanda 已启动，并提供可访问的 CDP WebSocket：`ws://127.0.0.1:9222`。
- 目标网页可公开访问；本工具不会处理登录或绕过访问控制。

> **注意：** 主脚本启动时会关闭该 CDP 端点上的所有现有 `page` 类型标签页。不要连接到包含重要浏览会话的共享实例。

如果无法连接 CDP，请先启动或重连 Lightpanda，再运行脚本。

## 快速开始

先用探索模式查看页面结构：

```powershell
powershell -ExecutionPolicy Bypass -File ".\scripts\cdp_fetch.ps1" `
  -Url "https://github.com/trending" `
  -Explore
```

探索结果会列出页面 URL、链接、标签分布、候选选择器及表单控件。根据结果选择**每个条目对应的元素**，再执行抓取：

```powershell
powershell -ExecutionPolicy Bypass -File ".\scripts\cdp_fetch.ps1" `
  -Url "https://github.com/trending" `
  -CardSelector "article h2 a" `
  -Max 5
```

也可以省略 URL 的协议，脚本会自动补上 `https://`：

```powershell
powershell -ExecutionPolicy Bypass -File ".\scripts\cdp_fetch.ps1" `
  -Url "www.fab.com/search?ui_filter_price=1&is_free=1&sort_by=-firstPublishedAt" `
  -CardSelector 'a[href^="/listings/"]' `
  -Max 10 `
  -Title "Fab 免费新品"
```

## 参数

| 参数 | 必填 | 默认值 | 说明 |
|---|---:|---|---|
| `-Url` | 是 | — | 目标页面 URL。可带 `http://` 或 `https://`，也可使用不带协议的主机名。 |
| `-CardSelector` | 普通抓取必填 | — | CSS 选择器。应匹配每个条目；当前实现仅在匹配元素本身为相对链接 `<a href="/...">` 时提取路径。 |
| `-Max` | 否 | `5` | 最多输出的条目数。 |
| `-Explore` | 否 | 关闭 | 探索页面结构；此模式不需要 `-CardSelector`，输出结构信息后退出。 |
| `-Title` | 否 | `Top results` | 可读结果列表的标题。 |
| `-WaitSeconds` | 否 | `120` | 等待导航事件及通过挑战页的最长秒数。 |
| `-ShowAll` | 否 | 关闭 | 当前脚本保留此参数，但暂未实现额外行为；请使用 `-Explore` 检查页面。 |
| `-Verbose` | 否 | 关闭 | 显示 PowerShell 详细诊断信息。 |

### 选择器注意事项

当前版本对每个匹配元素读取 `textContent`，并仅在该元素本身是 `<a>` 且 `href` 为站内相对路径时填充 `path`。因此，推荐选择直接匹配条目链接的选择器，例如：

- GitHub Trending：`article h2 a`
- Fab 列表：`a[href^="/listings/"]`

如果选择器匹配的是包住链接的 `article`、`div` 等容器，`name` 可能有内容，但 `path` 会为空，生成的 `fullUrl` 也就不是条目地址。先运行 `-Explore` 检查页面和链接，再确定选择器。不同网站的 DOM 会变化，选择器需要按页面实际结构调整。

## 输出

普通模式会先打印条目列表，再打印 JSON，例如：

```json
[
  {
    "name": "owner/repository",
    "path": "/owner/repository",
    "fullUrl": "https://github.com/owner/repository"
  }
]
```

- `name`：匹配元素的文本内容，空白字符会被整理。
- `path`：匹配元素自身的站内相对 `href`；非链接或不符合条件时为空字符串。
- `fullUrl`：将目标 URL 的 scheme 和 host 与 `path` 拼接得到。

成功时会显示 `OK` 并以退出码 `0` 结束。连接失败、页面未加载、选择器没有匹配项或提取失败时会报告错误并以非零退出码结束。

## 常见问题

### 无法连接到 CDP

确认 Lightpanda 正在运行，并监听 `127.0.0.1:9222`。脚本连接的是本机端点，不会自动启动 Lightpanda。

### 等不到页面加载或结果为空

- 确认 URL 可从 Lightpanda 所在的网络环境访问。
- 检查是否遇到 Cloudflare 或其他挑战页面；可增加 `-WaitSeconds`。
- 使用 `-Explore` 检查实际 URL、链接和候选选择器。
- 确认 `-CardSelector` 匹配到元素，且元素本身是带相对 `href` 的 `<a>`。
- 加 `-Verbose` 查看 CDP 命令和诊断输出。

### 某些页面没有可用条目链接

如果页面使用跟踪链接、JavaScript 点击处理，或根本没有 `<a href>`，当前抓取方式可能无法得到条目路径。不要只靠调整选择器猜测；先检查页面结构，再考虑站点提供的 RSS、JSON API 或嵌入式数据。更多判断方法见 [`references/site-patterns.md`](references/site-patterns.md)。

### CDP 导航事件

本工具使用 `Page.enable` 和 CDP 事件流判断导航进度。关于 Lightpanda 的事件行为和限制，参见 [`references/cdp-events.md`](references/cdp-events.md)。
