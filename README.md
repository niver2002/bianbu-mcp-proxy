# Bianbu MCP Proxy

Public deployment script and client examples for exposing a Bianbu OS host as a remote MCP server over HTTP/HTTPS.

What this gives you:
- one-file deployment on a Bianbu OS / Debian-like host
- stateless Streamable HTTP MCP server, suitable for platform gateways
- file operations, binary upload/download, and command execution
- optional root-capable MCP calls through `as_root: true`
- auto `sudo` setup for the runtime user during bootstrap
- systemd service with health checks and recovery commands
- client-side pacing and retry examples for rate-limited gateways

## Repository contents

- `bianbu_agent_proxy.sh` — deploy, repair, recover, and manage the remote MCP service
- `examples/client/` — minimal Node client examples and test scripts

## Quick start

On the remote Bianbu OS host:

```bash
bash bianbu_agent_proxy.sh
```

The script now defaults to `up`, which runs the full recovery/bootstrap flow.

If the file may have CRLF line endings, this also works:

```bash
tr -d '\r' < bianbu_agent_proxy.sh | bash
```

## Commands

```bash
bash bianbu_agent_proxy.sh up
bash bianbu_agent_proxy.sh bootstrap
bash bianbu_agent_proxy.sh repair
bash bianbu_agent_proxy.sh recover
bash bianbu_agent_proxy.sh status
bash bianbu_agent_proxy.sh logs
bash bianbu_agent_proxy.sh show-config
```

Practical meaning:
- `up` → default full recovery path
- `bootstrap` → install and deploy from scratch
- `repair` → re-enable and restart the service, then wait for health
- `recover` → full rebuild/recovery

## Remote deployment behavior

The script is designed for a mostly clean Bianbu OS / Debian-like machine.

During bootstrap it will:
- install `nodejs`, `npm`, `curl`, `ca-certificates`, `python3`, `sudo`
- generate the MCP server app under `/opt/bianbu-mcp-server`
- install dependencies
- configure a systemd service
- enable startup on boot
- configure passwordless sudo for the runtime user when `ENABLE_PASSWORDLESS_SUDO=true`
- wait for `http://127.0.0.1:$PORT/health` before declaring success

Important:
- if you are not root, the script uses `sudo`
- the user must already have sudo rights on the remote machine
- the script cannot magically bootstrap a machine where the current user has no sudo access at all

## Environment variables

Common deployment variables:

```bash
HOST=0.0.0.0
PORT=11434
MCP_PATH=/mcp
MCP_TRANSPORT_MODE=stateless
RUN_USER=bianbu
RUN_GROUP=bianbu
FILE_ROOT=/home/bianbu
ENABLE_PASSWORDLESS_SUDO=true
TLS_CERT_FILE=
TLS_KEY_FILE=
```

## Exposed MCP tools

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

Examples:

Read a root-owned file:

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

Run a root shell command:

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

## Client configuration

For normal client usage you only need:
- remote MCP URL
- gateway `X-API-KEY`

Example env:

```bash
export MCP_SERVER_URL='https://your-domain.example.com/mcp'
export MCP_GATEWAY_KEY='your-x-api-key'
```

## Recommended gateway pacing

Some gateways reject bursty traffic. The included client examples therefore use pacing and retries.

Recommended stable defaults:

```bash
export MCP_MIN_INTERVAL_MS=1000
export MCP_MAX_RETRIES=2
export MCP_RETRY_BASE_MS=1000
```

This corresponds to about 1 request per second, prioritized for stability.

## Local client examples

In `examples/client/`:

```bash
npm install
npm run test:stateless
npm run test:stateful
node test-root-tools.mjs
```

The example scripts expect:
- `MCP_SERVER_URL`
- `MCP_GATEWAY_KEY`

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

If the script file was uploaded from Windows and line endings are broken, run:

```bash
tr -d '\r' < bianbu_agent_proxy.sh | bash
```

## Security notes

- gateway authentication is expected to be enforced outside the script via `X-API-KEY`
- the proxy itself does not add a second auth token layer by default
- `as_root: true` is powerful and should only be exposed behind a trusted gateway
- enabling passwordless sudo for the runtime user is a deliberate tradeoff to support remote root-capable MCP operations

## License

MIT
