# Bianbu MCP Proxy

<p align="center">
  <b>把一台 Bianbu OS 主机暴露成可供 AI IDE 使用的远程 MCP 服务。</b>
</p>

<p align="center">
  <a href="./README.md">English</a> | 简体中文
</p>

## 概览

这个项目解决的是：

- 一台远端 Bianbu OS 主机，如何一键部署成 MCP 服务
- 如何通过 HTTP/HTTPS 暴露给 Cursor、Windsurf、Claude Desktop 等 AI IDE
- 如何让 MCP 具备文件操作、命令执行，甚至 `as_root: true` 的远程提权能力

你最终会得到：

- 单文件部署脚本
- stateless Streamable HTTP MCP server
- systemd 开机自启
- 自动健康检查与修复命令
- 网关限流下更稳定的客户端访问策略

## 仓库内容

- `bianbu_agent_proxy.sh` —— 核心部署 / 修复 / 恢复脚本
- `examples/client/` —— 最小 Node 示例，分别用于普通功能与 root 功能验证
- `pic/` —— 图示说明，告诉用户如何从平台界面获取 MCP URL 和 API Key

## 一键部署

在远端 Bianbu OS 主机上，最短启动命令就是：

```bash
bash bianbu_agent_proxy.sh
```

脚本默认执行 `up`，也就是完整恢复 / 启动流程。

如果文件是从 Windows 上传，可能带有 CRLF 换行，此时建议这样跑：

```bash
tr -d '\r' < bianbu_agent_proxy.sh | bash
```

## 常用命令

```bash
bash bianbu_agent_proxy.sh up
bash bianbu_agent_proxy.sh bootstrap
bash bianbu_agent_proxy.sh repair
bash bianbu_agent_proxy.sh recover
bash bianbu_agent_proxy.sh status
bash bianbu_agent_proxy.sh logs
bash bianbu_agent_proxy.sh show-config
```

| 命令 | 作用 |
|---|---|
| `up` | 默认完整恢复流程 |
| `bootstrap` | 从零安装并部署 |
| `repair` | 修复并重启服务，然后做健康检查 |
| `recover` | 走更完整的重建恢复流程 |
| `status` | 查看 systemd 服务状态 |
| `logs` | 查看服务日志 |
| `show-config` | 查看当前脚本配置 |

## 部署时脚本会自动做什么

执行后会自动：

- 安装 `nodejs`、`npm`、`curl`、`ca-certificates`、`python3`、`sudo`
- 生成 MCP server 到 `/opt/bianbu-mcp-server`
- 安装 Node 依赖
- 写 systemd 服务文件
- 配置开机自启
- 给运行用户配置免密码 sudo（默认开启）
- 自动检查 `http://127.0.0.1:11434/health`

### 前提条件

脚本支持两种远端环境：

① 当前就是 root

② 当前不是 root，但当前用户本来就有 sudo 权限

注意：
- 脚本可以自动调 sudo
- 但它不能凭空绕过系统权限模型
- 如果当前用户完全没有 sudo 权限，那还是需要人工先处理权限

## 本地客户端真正需要的参数

对本地 AI IDE / MCP 客户端来说，真正必须提供的只有：

```text
MCP_SERVER_URL
MCP_GATEWAY_KEY
```

也就是：

- MCP URL，例如：`https://your-domain.example.com/mcp`
- 网关 API Key，也就是 MCP 客户端请求头里的 `X-API-KEY`

一般不需要远端 root 密码。

root 密码只和远端人工维护、首次部署权限有关，不是客户端连接配置的一部分。

## 在 AI IDE 里怎么用

对大多数支持远程 HTTP MCP 的 AI IDE，填写规则都是一样的：

- transport：`http` 或 `streamable http`
- URL：`https://your-domain.example.com/mcp`
- header 名称：`X-API-KEY`
- header 值：你的网关 key

如果某个 IDE 强制你填写本地 `command`，那说明它只支持本地 stdio MCP，不能直接连接这个远程 HTTP MCP。

### Cursor

常见配置路径：
- macOS: `~/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor/mcp.json`
- Windows: `%APPDATA%/Cursor/User/globalStorage/anysphere.cursor/mcp.json`
- Linux: `~/.config/Cursor/User/globalStorage/anysphere.cursor/mcp.json`

示例：

```json
{
  "mcpServers": {
    "bianbu": {
      "type": "http",
      "url": "https://your-domain.example.com/mcp",
      "headers": {
        "X-API-KEY": "your-x-api-key"
      }
    }
  }
}
```

### Windsurf

常见配置路径：
- macOS: `~/Library/Application Support/Windsurf/User/globalStorage/codeium.windsurf/mcp.json`
- Windows: `%APPDATA%/Windsurf/User/globalStorage/codeium.windsurf/mcp.json`
- Linux: `~/.config/Windsurf/User/globalStorage/codeium.windsurf/mcp.json`

同样可以使用上面的 JSON 结构。

### Claude Desktop

常见配置路径：
- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%/Claude/claude_desktop_config.json`

如果当前版本支持远程 MCP，就同样配置 URL + `X-API-KEY`。

### Cline / Roo Code / VS Code MCP 插件

常见位置：
- `.vscode/settings.json`
- 插件自己的 MCP 配置面板
- VS Code 用户数据目录下的插件配置文件

如果插件支持远程 HTTP MCP，就使用同样的字段；如果它只支持本地 stdio MCP，就不能直接连这个远端地址。

### Continue / Claude Code / Codex / 其他 Agent Runner

只要它支持远程 MCP 注册，规则就一样：
- URL
- `X-API-KEY`

如果只支持本地命令型 MCP，则需要额外桥接。

## 用户如何获取 MCP URL 和 Key

仓库里 `pic/` 目录已经放了 3 张图，正好可以串成完整指引。

### ① 先进入实例页面

![图 1：进入实例页](./pic/1.png)

这一页对应的是 BianbuCloud 控制台主页。用户应先点击自己的实例卡片，进入实例详情页。

### ② 再去 API Key 页面复制 Key

![图 2：进入 API Key 页面并复制 Key](./pic/2.png)

用户需要：
- 点击左侧 `API Key`
- 复制页面里显示的完整 key 值
- 这个值就是 AI IDE / MCP 客户端里要填的 `X-API-KEY`

### ③ 在“本地连接”里找到域名，拼成 MCP URL

![图 3：从本地连接页面提取域名并拼接 MCP URL](./pic/3.png)

用户需要：
- 点击“本地连接”
- 在连接信息里找到完整域名
- 用下面这个格式拼出 MCP URL：

```text
https://<该域名>/mcp
```

所以最终：

- MCP URL = `https://<domain>/mcp`
- MCP Key = `API Key` 页面复制出来的值

## 当前暴露的 MCP Tools

- `health`
- `list_directory`
- `read_text_file`
- `write_text_file`
- `upload_binary_file`
- `download_binary_file`
- `make_directory`
- `delete_path`
- `run_command`

## root 提权能力

多数工具都支持：

```json
{
  "as_root": true
}
```

支持 `as_root` 的工具：

- `list_directory`
- `read_text_file`
- `write_text_file`
- `upload_binary_file`
- `download_binary_file`
- `make_directory`
- `delete_path`
- `run_command`

### root 文件读取示例

```json
{
  "name": "read_text_file",
  "arguments": {
    "path": "/root/secret.txt",
    "max_bytes": 8192,
    "encoding": "utf-8",
    "as_root": true
  }
}
```

### root 命令执行示例

```json
{
  "name": "run_command",
  "arguments": {
    "command": "id && whoami",
    "cwd": "/",
    "timeout_seconds": 30,
    "as_root": true
  }
}
```

## 推荐访问频率

考虑到某些网关对突发请求敏感，推荐默认参数：

```bash
export MCP_MIN_INTERVAL_MS=1000
export MCP_MAX_RETRIES=2
export MCP_RETRY_BASE_MS=1000
```

这大约是 1 PPS，优先稳定。

## 本地示例怎么跑

最小示例在：

`examples/client/`

使用方式：

```bash
cd examples/client
npm install
export MCP_SERVER_URL='https://your-domain.example.com/mcp'
export MCP_GATEWAY_KEY='your-x-api-key'
npm run test:stateless
npm run test:root
```

## 健康检查与排障

远端本机健康检查：

```bash
curl http://127.0.0.1:11434/health
```

常用命令：

```bash
bash bianbu_agent_proxy.sh status
bash bianbu_agent_proxy.sh logs
bash bianbu_agent_proxy.sh repair
bash bianbu_agent_proxy.sh recover
```

如果是 Windows 上传导致换行符异常：

```bash
tr -d '\r' < bianbu_agent_proxy.sh | bash
```

## 安全说明

- 认证默认依赖外层网关的 `X-API-KEY`
- 脚本默认不再额外叠加第二层 token
- `as_root: true` 权限非常高，只应暴露在可信网关之后
- 给运行用户配置 passwordless sudo 是为了支持远程 root MCP 操作，这是一个明确的安全权衡

## License

MIT
