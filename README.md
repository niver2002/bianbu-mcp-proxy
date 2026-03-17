# Bianbu MCP Proxy

<p align="center">
  <b>Turn a Bianbu Cloud 云主机 into a remote MCP server for AI IDEs.</b>
</p>

<p align="center">
  One-file deploy • HTTP MCP • Root-capable tools • Systemd auto-start
</p>

<p align="center">
  <a href="./README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/platform-Bianbu%20Cloud-2b6cb0">
  <img alt="transport" src="https://img.shields.io/badge/MCP-Streamable%20HTTP-0f766e">
  <img alt="service" src="https://img.shields.io/badge/service-systemd-444">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-black">
</p>

---

## At a glance

This repository gives you a practical remote MCP endpoint backed by a Bianbu Cloud host:

- one-file deployment on a Bianbu Cloud 云主机
- stateless Streamable HTTP MCP server for gateway exposure
- file tools, binary upload/download, and shell command execution
- optional root-capable operations with `as_root: true`
- automatic sudo setup for the runtime user during bootstrap
- systemd startup, health checks, repair, and recovery commands
- client examples tuned for gateway rate limits

## 3-step quick start

| Step | What to do | Result |
|---|---|---|
| ① Deploy remote service | `bash bianbu_agent_proxy.sh` | MCP service is installed and started |
| ② Get connection info | copy `API Key` + derive `https://<domain>/mcp` | URL and `X-API-KEY` are ready |
| ③ Configure your AI IDE | add remote HTTP MCP server | tools become available in the IDE |

If the script was uploaded from Windows and line endings are broken:

```bash
tr -d '\r' < bianbu_agent_proxy.sh | bash
```

---

## Repository layout

```text
bianbu_agent_proxy.sh        # deployment / recovery script
examples/client/            # minimal Node client examples
pic/                        # screenshots for URL + key acquisition
README.md                   # English guide
README.zh-CN.md             # 中文说明
```

## Remote deployment

Run on the remote Bianbu Cloud 云主机:

```bash
bash bianbu_agent_proxy.sh
```

The script defaults to `up`, which runs the full recovery/bootstrap path.

### Main commands

| Command | Meaning |
|---|---|
| `bash bianbu_agent_proxy.sh up` | full startup / recovery path |
| `bash bianbu_agent_proxy.sh bootstrap` | install and deploy from scratch |
| `bash bianbu_agent_proxy.sh repair` | restart and repair the service |
| `bash bianbu_agent_proxy.sh recover` | full rebuild / recovery |
| `bash bianbu_agent_proxy.sh status` | show systemd status |
| `bash bianbu_agent_proxy.sh logs` | show service logs |
| `bash bianbu_agent_proxy.sh show-config` | print effective config |

### What bootstrap does

During bootstrap the script will:

- install `nodejs`, `npm`, `curl`, `ca-certificates`, `python3`, `sudo`
- generate the server under `/opt/bianbu-mcp-server`
- install Node dependencies
- configure a systemd service
- enable startup on boot
- configure passwordless sudo for the runtime user when enabled
- wait for `http://127.0.0.1:$PORT/health` before reporting success

### Required privilege model

The script supports two normal cases:

- you are already `root`
- you are a normal user with working `sudo`

It cannot bootstrap a machine where the current user has no sudo rights at all.

---

## Connection info users need

For normal client usage you only need two things:

```text
MCP_SERVER_URL
MCP_GATEWAY_KEY
```

That means:

- MCP URL, for example: `https://your-domain.example.com/mcp`
- gateway key, sent as `X-API-KEY`

You do not normally need the remote root password in the AI IDE.

---

## How to obtain the MCP URL and key

Use the platform UI shown in `pic/`.

### ① Open your instance page

![Step 1: open your instance page](./pic/1.png)

From the Bianbu Cloud console, click your instance card and enter the instance detail page.

### ② Open API Key and copy the key value

![Step 2: open API Key and copy it](./pic/2.png)

Open `API Key` and copy the full value shown there. This becomes the `X-API-KEY` used by MCP clients.

### ③ Open Local Connection and derive the MCP URL

![Step 3: derive the MCP URL from the domain](./pic/3.png)

Open `Local Connection`, find the full domain, and form the MCP endpoint as:

```text
https://<that-domain>/mcp
```

In short:

- MCP URL = `https://<domain>/mcp`
- MCP key = the value from `API Key`

---

## AI IDE setup

### Quick copy-paste connection block

Use these values wherever an IDE asks for remote MCP connection details:

```text
Name: bianbu
Transport: HTTP / Streamable HTTP
URL: https://your-domain.example.com/mcp
Header: X-API-KEY
Value: your-x-api-key
```

Minimal JSON form:

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

If an IDE insists on a local executable `command`, it expects a local stdio MCP server and cannot use this remote HTTP endpoint directly.

### Compatibility matrix

| Tool | Direct remote HTTP MCP | Typical status |
|---|---|---|
| Cursor | Yes, if build supports remote MCP | usually direct |
| Windsurf | Yes, if build supports remote MCP | usually direct |
| Claude Desktop | Version-dependent | direct if remote MCP is supported |
| Cline / Roo / VS Code MCP clients | Version-dependent | sometimes direct, sometimes stdio-only |
| Continue | Version-dependent | sometimes direct, sometimes config-dependent |
| Claude Code / Codex / agent runners | Version-dependent | direct only if remote MCP registration exists |

Rule of thumb:
- if the product asks for URL + headers, you can usually connect directly
- if the product asks for a local `command`, it is stdio-only and needs a bridge

### Cursor

Typical config location:
- macOS: `~/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor/mcp.json`
- Windows: `%APPDATA%/Cursor/User/globalStorage/anysphere.cursor/mcp.json`
- Linux: `~/.config/Cursor/User/globalStorage/anysphere.cursor/mcp.json`

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

Typical config location:
- macOS: `~/Library/Application Support/Windsurf/User/globalStorage/codeium.windsurf/mcp.json`
- Windows: `%APPDATA%/Windsurf/User/globalStorage/codeium.windsurf/mcp.json`
- Linux: `~/.config/Windsurf/User/globalStorage/codeium.windsurf/mcp.json`

Use the same JSON structure as Cursor.

### Claude Desktop

Typical config location:
- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%/Claude/claude_desktop_config.json`

If your build supports remote MCP, use the same URL + header format.

### Cline / Roo Code / VS Code MCP clients

Common config locations:
- `.vscode/settings.json`
- extension MCP settings UI
- extension-specific config files in VS Code user data

If the extension supports remote HTTP MCP, use the same server definition. If it only supports stdio MCP, it cannot connect directly to this endpoint.

### Continue / Claude Code / Codex-style runners

If the tool supports remote MCP registration, use the same URL + header pattern. If it only supports local command-based MCP, it needs a local bridge.

---

## Available MCP tools

- `health`
- `list_directory`
- `read_text_file`
- `write_text_file`
- `upload_binary_file`
- `download_binary_file`
- `make_directory`
- `delete_path`
- `run_command`

## Root-capable operations

Most tools accept:

```json
{
  "as_root": true
}
```

Supported for:
- `list_directory`
- `read_text_file`
- `write_text_file`
- `upload_binary_file`
- `download_binary_file`
- `make_directory`
- `delete_path`
- `run_command`

### Example: read a root-owned file

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

### Example: run a root shell command

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

---

## Recommended gateway pacing

Some gateways reject bursty traffic. Recommended stable defaults:

```bash
export MCP_MIN_INTERVAL_MS=1000
export MCP_MAX_RETRIES=2
export MCP_RETRY_BASE_MS=1000
```

That is about 1 request per second, optimized for stability.

## Minimal local test examples

In `examples/client/`:

```bash
npm install
npm run test:stateless
npm run test:root
```

Expected env vars:
- `MCP_SERVER_URL`
- `MCP_GATEWAY_KEY`

---

## Health and troubleshooting

Remote health check:

```bash
curl http://127.0.0.1:11434/health
```

Useful commands:

```bash
bash bianbu_agent_proxy.sh status
bash bianbu_agent_proxy.sh logs
bash bianbu_agent_proxy.sh repair
bash bianbu_agent_proxy.sh recover
```

If the script file was uploaded from Windows and line endings are broken:

```bash
tr -d '\r' < bianbu_agent_proxy.sh | bash
```

## Security notes

- gateway authentication is expected to be enforced outside the script via `X-API-KEY`
- the proxy itself does not add a second auth token layer by default
- `as_root: true` is powerful and should only be exposed behind a trusted gateway
- passwordless sudo for the runtime user is a deliberate tradeoff to support remote root-capable MCP operations

## License

MIT
