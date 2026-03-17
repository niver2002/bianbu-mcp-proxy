#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_NAME="$(basename "$0")"
APP_NAME="bianbu-mcp-server"
INSTALL_ROOT="/opt/${APP_NAME}"
APP_FILE="${INSTALL_ROOT}/server.mjs"
PACKAGE_FILE="${INSTALL_ROOT}/package.json"
SERVICE_NAME="${APP_NAME}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_FILE="/etc/default/${SERVICE_NAME}"
BACKUP_ROOT="/opt/${APP_NAME}-backups"

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-11434}"
MCP_PATH="${MCP_PATH:-/mcp}"
RUN_USER="${RUN_USER:-bianbu}"
RUN_GROUP="${RUN_GROUP:-${RUN_USER}}"
FILE_ROOT="${FILE_ROOT:-/home/${RUN_USER}}"
ENABLE_PASSWORDLESS_SUDO="${ENABLE_PASSWORDLESS_SUDO:-true}"
MAX_FILE_MB="${MAX_FILE_MB:-64}"
MAX_COMMAND_OUTPUT_KB="${MAX_COMMAND_OUTPUT_KB:-256}"
TLS_CERT_FILE="${TLS_CERT_FILE:-}"
TLS_KEY_FILE="${TLS_KEY_FILE:-}"
MCP_TRANSPORT_MODE="${MCP_TRANSPORT_MODE:-stateless}"

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
用法:
  $SCRIPT_NAME install
  $SCRIPT_NAME up
  $SCRIPT_NAME bootstrap
  $SCRIPT_NAME start
  $SCRIPT_NAME stop
  $SCRIPT_NAME restart
  $SCRIPT_NAME status
  $SCRIPT_NAME recover
  $SCRIPT_NAME repair
  $SCRIPT_NAME logs [journalctl参数...]
  $SCRIPT_NAME show-config
  $SCRIPT_NAME help

默认行为:
  - 在当前 Bianbu OS 主机上启动一个 MCP server
  - MCP endpoint: http://<你的主机>:${PORT}${MCP_PATH}
  - 健康检查:   http://<你的主机>:${PORT}/health
  - 默认使用 stateless Streamable HTTP，适合经由 Bianbu 平台 HTTPS 网关暴露

MCP transport mode:
  - stateless  推荐。每个请求独立处理，不依赖 MCP-Session-Id，兼容平台网关
  - stateful   传统会话模式，支持 MCP-Session-Id / GET / DELETE

MCP tools:
  - health
  - run_command
  - list_directory
  - read_text_file
  - write_text_file
  - upload_binary_file
  - download_binary_file
  - make_directory
  - delete_path

常用环境变量:
  HOST                   服务监听地址，默认: ${HOST}
  PORT                   服务端口，默认: ${PORT}
  MCP_PATH               MCP 挂载路径，默认: ${MCP_PATH}
  MCP_TRANSPORT_MODE     stateless 或 stateful，默认: ${MCP_TRANSPORT_MODE}
  RUN_USER               systemd 运行用户，默认: ${RUN_USER}
  RUN_GROUP              systemd 运行组，默认: ${RUN_GROUP}
  FILE_ROOT              文件操作根目录，默认: ${FILE_ROOT}
  ENABLE_PASSWORDLESS_SUDO  bootstrap 时为 RUN_USER 自动配置 sudo 免密码，默认: ${ENABLE_PASSWORDLESS_SUDO}
  MAX_FILE_MB            上传/下载单文件大小限制，默认: ${MAX_FILE_MB} MB
  MAX_COMMAND_OUTPUT_KB  命令输出截断上限，默认: ${MAX_COMMAND_OUTPUT_KB} KB
  TLS_CERT_FILE          可选，HTTPS 证书路径
  TLS_KEY_FILE           可选，HTTPS 私钥路径

示例:
  chmod +x ./$SCRIPT_NAME
  MCP_TRANSPORT_MODE=stateless ./$SCRIPT_NAME bootstrap
  curl http://127.0.0.1:${PORT}/health

权限说明:
  - 非 root 执行 bootstrap 时，脚本会自动调用 sudo，并在需要时提示输入当前用户密码
  - 若 ENABLE_PASSWORDLESS_SUDO=true，bootstrap 会为 RUN_USER 写入 sudoers，便于后续 MCP 工具以 as_root=true 免密码提权

公网暴露建议:
  - Bianbu 虚拟平台建议优先使用 MCP_TRANSPORT_MODE=stateless
  - 认证默认依赖外层平台/网关已有的 X-API-KEY；脚本本身不再额外生成第二层 token
  - 强烈建议设置 TLS_CERT_FILE / TLS_KEY_FILE，或放在 HTTPS 反向代理/网关后面
  - 默认以非 root 用户运行；如需更高权限，请显式设置 RUN_USER / FILE_ROOT 并知晓风险
  - bootstrap 会自动检测并清理旧版残留安装
EOF
}

need_root_prefix() {
  if [ "$(id -u)" -eq 0 ]; then
    printf ''
  elif command -v sudo >/dev/null 2>&1; then
    printf 'sudo'
  else
    die "需要 root 权限，请使用 root 运行或先安装 sudo"
  fi
}

run_as_root() {
  local prefix
  prefix="$(need_root_prefix)"
  if [ -n "$prefix" ]; then
    "$prefix" "$@"
  else
    "$@"
  fi
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl，当前环境不支持 systemd"
}

write_root_file() {
  local dest="$1"
  local mode="$2"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  run_as_root install -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
}

service_file_exists() {
  run_as_root test -f "$SERVICE_FILE"
}

stop_existing_service_if_needed() {
  require_systemd
  if service_file_exists && run_as_root systemctl is-active --quiet "$SERVICE_NAME"; then
    log "检测到已运行服务，先停止: $SERVICE_NAME"
    run_as_root systemctl stop "$SERVICE_NAME"
  fi
}

cleanup_legacy_install() {
  local legacy_paths
  local stale_paths
  local item
  local found_any=0

  legacy_paths=(
    "$INSTALL_ROOT/.venv"
    "$INSTALL_ROOT/app.py"
    "$INSTALL_ROOT/requirements.txt"
    "$INSTALL_ROOT/server.py"
  )

  stale_paths=(
    "$INSTALL_ROOT/node_modules"
    "$INSTALL_ROOT/package-lock.json"
    "$INSTALL_ROOT/server.mjs"
    "$INSTALL_ROOT/package.json"
  )

  stop_existing_service_if_needed

  for item in "${legacy_paths[@]}"; do
    if run_as_root test -e "$item"; then
      if [ "$found_any" -eq 0 ]; then
        log "检测到旧版/异构安装残留，开始自动清理"
        found_any=1
      fi
      log "清理旧遗留: $item"
      run_as_root rm -rf "$item"
    fi
  done

  for item in "${stale_paths[@]}"; do
    if run_as_root test -e "$item"; then
      if [ "$found_any" -eq 0 ]; then
        log "检测到上次安装残留，开始自动清理"
        found_any=1
      fi
      log "清理安装缓存: $item"
      run_as_root rm -rf "$item"
    fi
  done

  if [ "$found_any" -eq 0 ]; then
    log "未发现需要清理的旧安装残留"
  fi
}

ensure_runtime_user() {
  if ! run_as_root id -u "$RUN_USER" >/dev/null 2>&1; then
    die "运行用户不存在: $RUN_USER"
  fi

  if ! run_as_root getent group "$RUN_GROUP" >/dev/null 2>&1; then
    die "运行组不存在: $RUN_GROUP"
  fi

  case "$MCP_TRANSPORT_MODE" in
    stateless|stateful) ;;
    *) die "MCP_TRANSPORT_MODE 仅支持 stateless 或 stateful，当前: $MCP_TRANSPORT_MODE" ;;
  esac

  case "$ENABLE_PASSWORDLESS_SUDO" in
    true|false) ;;
    *) die "ENABLE_PASSWORDLESS_SUDO 仅支持 true 或 false，当前: $ENABLE_PASSWORDLESS_SUDO" ;;
  esac

  if { [ -n "$TLS_CERT_FILE" ] && [ -z "$TLS_KEY_FILE" ]; } || { [ -z "$TLS_CERT_FILE" ] && [ -n "$TLS_KEY_FILE" ]; }; then
    die "TLS_CERT_FILE 与 TLS_KEY_FILE 必须同时设置"
  fi

  if [ -n "$TLS_CERT_FILE" ]; then
    run_as_root test -r "$TLS_CERT_FILE" || die "TLS 证书不可读: $TLS_CERT_FILE"
    run_as_root test -r "$TLS_KEY_FILE" || die "TLS 私钥不可读: $TLS_KEY_FILE"
  fi

  run_as_root install -d -m 755 "$INSTALL_ROOT"
  if [ "$FILE_ROOT" != "/" ]; then
    run_as_root install -d -m 755 -o "$RUN_USER" -g "$RUN_GROUP" "$FILE_ROOT"
  fi
}

configure_passwordless_sudo() {
  if [ "$ENABLE_PASSWORDLESS_SUDO" != "true" ]; then
    log "跳过 sudo 免密码配置"
    return 0
  fi

  if [ "$RUN_USER" = "root" ]; then
    log "RUN_USER=root，无需配置 sudo 免密码"
    return 0
  fi

  command -v visudo >/dev/null 2>&1 || die "未找到 visudo，请先安装 sudo"

  local sudoers_file="/etc/sudoers.d/${SERVICE_NAME}"
  write_root_file "$sudoers_file" 440 <<EOF
Defaults:${RUN_USER} !requiretty
${RUN_USER} ALL=(root) NOPASSWD:ALL
EOF
  run_as_root visudo -cf "$sudoers_file" >/dev/null
  log "已为 ${RUN_USER} 配置 sudo 免密码: $sudoers_file"
}

wait_for_local_health() {
  local attempts="${1:-20}"
  local delay="${2:-2}"
  local i
  for i in $(seq 1 "$attempts"); do
    if curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      log "本地健康检查通过"
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

finalize_service_start() {
  require_systemd
  run_as_root systemctl daemon-reload
  run_as_root systemctl reset-failed "$SERVICE_NAME" || true
  run_as_root systemctl enable --now "$SERVICE_NAME"
  run_as_root systemctl restart "$SERVICE_NAME"
  if ! wait_for_local_health 25 2; then
    run_as_root systemctl --no-pager --full status "$SERVICE_NAME" || true
    run_as_root journalctl -u "$SERVICE_NAME" -n 120 --no-pager || true
    die "服务启动后健康检查失败"
  fi
  run_as_root systemctl --no-pager --full status "$SERVICE_NAME" || true
}

ensure_node_version() {
  command -v node >/dev/null 2>&1 || die "未找到 node，请先执行: $SCRIPT_NAME install"
  if ! node -e "const major=Number(process.versions.node.split('.')[0]); process.exit(major >= 18 ? 0 : 1)"; then
    die "Node.js 版本过低，要求 >= 18"
  fi
}

write_package() {
  write_root_file "$PACKAGE_FILE" 644 <<'EOF'
{
  "name": "bianbu-mcp-server",
  "version": "1.1.0",
  "private": true,
  "type": "module",
  "dependencies": {
    "@modelcontextprotocol/sdk": "1.27.1",
    "zod": "^4.0.0"
  }
}
EOF
}

write_app() {
  write_root_file "$APP_FILE" 755 <<'EOF'
import { randomBytes, randomUUID } from 'node:crypto';
import { exec as execCb } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import https from 'node:https';

import { createMcpExpressApp } from '@modelcontextprotocol/sdk/server/express.js';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { isInitializeRequest } from '@modelcontextprotocol/sdk/types.js';
import { z } from 'zod/v4';

const exec = promisify(execCb);

const HOST = process.env.HOST || '0.0.0.0';
const PORT = Number(process.env.PORT || '11434');
const MCP_PATH = process.env.MCP_PATH || '/mcp';
const FILE_ROOT = path.resolve(process.env.FILE_ROOT || '/');
const ENABLE_PASSWORDLESS_SUDO = (process.env.ENABLE_PASSWORDLESS_SUDO || 'true').toLowerCase() === 'true';
const MAX_FILE_BYTES = Number(process.env.MAX_FILE_MB || '64') * 1024 * 1024;
const MAX_COMMAND_OUTPUT_BYTES = Number(process.env.MAX_COMMAND_OUTPUT_KB || '256') * 1024;
const TLS_CERT_FILE = process.env.TLS_CERT_FILE || '';
const TLS_KEY_FILE = process.env.TLS_KEY_FILE || '';
const MCP_TRANSPORT_MODE = (process.env.MCP_TRANSPORT_MODE || 'stateless').toLowerCase();
const CANONICAL_FILE_ROOT = FILE_ROOT === '/' ? '/' : fs.realpathSync(FILE_ROOT);
const HAS_SUDO = fs.existsSync('/usr/bin/sudo') || fs.existsSync('/bin/sudo');

if (!['stateless', 'stateful'].includes(MCP_TRANSPORT_MODE)) {
  throw new Error(`Unsupported MCP_TRANSPORT_MODE: ${MCP_TRANSPORT_MODE}`);
}

function textResult(text, structuredContent = undefined) {
  const result = { content: [{ type: 'text', text }] };
  if (structuredContent !== undefined) {
    result.structuredContent = structuredContent;
  }
  return result;
}

function truncateText(value, limit) {
  const text = value || '';
  const buffer = Buffer.from(text, 'utf8');
  if (buffer.length <= limit) {
    return text;
  }
  return buffer.subarray(0, limit).toString('utf8') + '\n...[truncated]';
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'"'"'`)}'`;
}

function rootHelperScript() {
  return String.raw`import base64, json, os, shutil, stat, sys, tempfile
payload = json.loads(base64.b64decode(sys.argv[1]).decode('utf-8'))
op = payload['op']
target = payload.get('path', '')

def stat_dict(p):
    st = os.stat(p)
    return {
        'path': p,
        'size': st.st_size,
        'modified': int(st.st_mtime),
        'is_dir': stat.S_ISDIR(st.st_mode),
        'is_file': stat.S_ISREG(st.st_mode),
    }

if op == 'list_directory':
    if not os.path.isdir(target):
        raise RuntimeError(f'not a directory: {target}')
    items = [stat_dict(os.path.join(target, name)) for name in sorted(os.listdir(target))]
    print(json.dumps({'items': items}, ensure_ascii=False))
elif op == 'read_text_file':
    if not os.path.isfile(target):
        raise RuntimeError(f'file not found: {target}')
    max_bytes = int(payload['max_bytes'])
    if os.path.getsize(target) > max_bytes:
        raise RuntimeError(f'file exceeds max_bytes={max_bytes}: {target}')
    with open(target, 'r', encoding=payload.get('encoding', 'utf-8')) as fh:
        print(json.dumps({'path': target, 'content': fh.read()}, ensure_ascii=False))
elif op == 'write_text_file':
    os.makedirs(os.path.dirname(target), exist_ok=True)
    if (not payload.get('overwrite', True)) and os.path.exists(target):
        raise RuntimeError(f'target exists and overwrite=false: {target}')
    fd, tmp_path = tempfile.mkstemp(prefix='.mcp-write-', dir=os.path.dirname(target) or '.')
    os.close(fd)
    try:
        with open(tmp_path, 'w', encoding=payload.get('encoding', 'utf-8')) as fh:
            fh.write(payload['content'])
        os.replace(tmp_path, target)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
    print(json.dumps(stat_dict(target), ensure_ascii=False))
elif op == 'upload_binary_file':
    data = base64.b64decode(payload['content_base64'])
    if len(data) > int(payload['max_file_bytes']):
        raise RuntimeError(f"payload exceeds max size {payload['max_file_bytes']} bytes")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    if (not payload.get('overwrite', True)) and os.path.exists(target):
        raise RuntimeError(f'target exists and overwrite=false: {target}')
    fd, tmp_path = tempfile.mkstemp(prefix='.mcp-bin-', dir=os.path.dirname(target) or '.')
    os.close(fd)
    try:
        with open(tmp_path, 'wb') as fh:
            fh.write(data)
        os.replace(tmp_path, target)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
    print(json.dumps(stat_dict(target), ensure_ascii=False))
elif op == 'download_binary_file':
    if not os.path.isfile(target):
        raise RuntimeError(f'file not found: {target}')
    max_bytes = int(payload['max_bytes'])
    if os.path.getsize(target) > max_bytes:
        raise RuntimeError(f'file exceeds max_bytes={max_bytes}: {target}')
    with open(target, 'rb') as fh:
        content = fh.read()
    out = stat_dict(target)
    out['content_base64'] = base64.b64encode(content).decode('ascii')
    print(json.dumps(out, ensure_ascii=False))
elif op == 'make_directory':
    parents = bool(payload.get('parents', True))
    if parents:
        os.makedirs(target, exist_ok=True)
    else:
        os.mkdir(target)
    print(json.dumps(stat_dict(target), ensure_ascii=False))
elif op == 'delete_path':
    if not os.path.exists(target):
        raise RuntimeError(f'path not found: {target}')
    info = stat_dict(target)
    recursive = bool(payload.get('recursive', False))
    if info['is_dir']:
        if not recursive:
            raise RuntimeError(f'path is directory, set recursive=true: {target}')
        shutil.rmtree(target)
    else:
        os.remove(target)
    info['ok'] = True
    print(json.dumps(info, ensure_ascii=False))
else:
    raise RuntimeError(f'unsupported op: {op}')`;
}

async function execShell(command, { cwd='/', timeoutSeconds=120, asRoot=false } = {}) {
  const wrapped = `cd ${shellQuote(cwd)} && ${command}`;
  const finalCommand = asRoot
    ? `sudo -n -- /bin/bash -lc ${shellQuote(wrapped)}`
    : wrapped;

  if (asRoot && process.getuid() !== 0 && !HAS_SUDO) {
    throw new Error('as_root requested but sudo is unavailable');
  }

  return exec(finalCommand, {
    cwd: '/',
    shell: '/bin/bash',
    timeout: timeoutSeconds * 1000,
    maxBuffer: Math.max(MAX_COMMAND_OUTPUT_BYTES * 4, 1024 * 1024),
  });
}

async function runRootFileOp(payload, timeoutSeconds = 120) {
  const encoded = Buffer.from(JSON.stringify(payload), 'utf8').toString('base64');
  const command = `python3 -c ${shellQuote(rootHelperScript())} ${shellQuote(encoded)}`;
  const completed = await execShell(command, { cwd: '/', timeoutSeconds, asRoot: true });
  return JSON.parse(completed.stdout || '{}');
}

async function resolvePath(rawPath) {
  const candidate = path.isAbsolute(rawPath) ? path.resolve(rawPath) : path.resolve(FILE_ROOT, rawPath);

  if (CANONICAL_FILE_ROOT === '/') {
    return candidate;
  }

  let probe = candidate;
  while (true) {
    try {
      await fs.promises.lstat(probe);
      break;
    } catch {
      const parent = path.dirname(probe);
      if (parent === probe) {
        throw new Error(`path not resolvable: ${rawPath}`);
      }
      probe = parent;
    }
  }

  const canonicalProbe = await fs.promises.realpath(probe);
  const suffix = path.relative(probe, candidate);
  const canonicalCandidate = path.resolve(canonicalProbe, suffix);

  if (canonicalCandidate !== CANONICAL_FILE_ROOT && !canonicalCandidate.startsWith(CANONICAL_FILE_ROOT + path.sep)) {
    throw new Error(`path escapes FILE_ROOT: ${rawPath}`);
  }

  return canonicalCandidate;
}

async function resolveRequestedPath(rawPath, asRoot = false) {
  if (asRoot && path.isAbsolute(rawPath)) {
    return path.resolve(rawPath);
  }
  return resolvePath(rawPath);
}

async function fileStat(target) {
  const stat = await fs.promises.stat(target);
  return {
    path: target,
    size: stat.size,
    modified: Math.floor(stat.mtimeMs / 1000),
    is_dir: stat.isDirectory(),
    is_file: stat.isFile(),
  };
}

function makeServer() {
  const server = new McpServer(
    {
      name: 'bianbu-remote-control',
      version: '1.1.0',
    },
    { capabilities: { logging: {} } },
  );

  server.registerTool(
    'health',
    { description: 'Return basic MCP server health information.' },
    async () => {
      const payload = {
        ok: true,
        listen: `${HOST}:${PORT}${MCP_PATH}`,
        file_root: FILE_ROOT,
        max_file_bytes: MAX_FILE_BYTES,
        max_command_output_bytes: MAX_COMMAND_OUTPUT_BYTES,
        transport_mode: MCP_TRANSPORT_MODE,
        running_uid: process.getuid(),
        has_sudo: HAS_SUDO,
        passwordless_sudo_expected: ENABLE_PASSWORDLESS_SUDO,
      };
      return textResult(JSON.stringify(payload, null, 2), payload);
    },
  );

  server.registerTool(
    'list_directory',
    {
      description: 'List one directory level and return metadata for each entry.',
      inputSchema: {
        path: z.string().default('.').describe('Absolute path or path relative to FILE_ROOT.'),
        as_root: z.boolean().default(false).describe('Use sudo/root privileges when true.'),
      },
    },
    async ({ path: inputPath, as_root }) => {
      const target = await resolveRequestedPath(inputPath, as_root);
      if (as_root) {
        const payload = await runRootFileOp({ op: 'list_directory', path: target });
        return textResult(JSON.stringify(payload.items, null, 2), payload);
      }

      const stat = await fs.promises.stat(target).catch(() => null);
      if (!stat) {
        throw new Error(`path not found: ${target}`);
      }
      if (!stat.isDirectory()) {
        throw new Error(`not a directory: ${target}`);
      }

      const names = await fs.promises.readdir(target);
      const items = [];
      for (const name of names.sort((a, b) => a.localeCompare(b))) {
        items.push(await fileStat(path.join(target, name)));
      }
      return textResult(JSON.stringify(items, null, 2), { items });
    },
  );

  server.registerTool(
    'read_text_file',
    {
      description: 'Read a UTF-8 text file from the remote host.',
      inputSchema: {
        path: z.string().describe('Absolute path or path relative to FILE_ROOT.'),
        max_bytes: z.number().int().positive().default(262144),
        encoding: z.string().default('utf-8'),
        as_root: z.boolean().default(false).describe('Use sudo/root privileges when true.'),
      },
    },
    async ({ path: inputPath, max_bytes, encoding, as_root }) => {
      const target = await resolveRequestedPath(inputPath, as_root);
      if (as_root) {
        const payload = await runRootFileOp({ op: 'read_text_file', path: target, max_bytes, encoding });
        return textResult(payload.content, payload);
      }
      const stat = await fs.promises.stat(target).catch(() => null);
      if (!stat || !stat.isFile()) {
        throw new Error(`file not found: ${target}`);
      }
      if (stat.size > max_bytes) {
        throw new Error(`file exceeds max_bytes=${max_bytes}: ${target}`);
      }
      const content = await fs.promises.readFile(target, { encoding });
      return textResult(content, { path: target, content });
    },
  );

  server.registerTool(
    'write_text_file',
    {
      description: 'Write a UTF-8 text file to the remote host.',
      inputSchema: {
        path: z.string().describe('Absolute path or path relative to FILE_ROOT.'),
        content: z.string(),
        overwrite: z.boolean().default(true),
        encoding: z.string().default('utf-8'),
        as_root: z.boolean().default(false).describe('Use sudo/root privileges when true.'),
      },
    },
    async ({ path: inputPath, content, overwrite, encoding, as_root }) => {
      const target = await resolveRequestedPath(inputPath, as_root);
      if (as_root) {
        const payload = await runRootFileOp({ op: 'write_text_file', path: target, content, overwrite, encoding });
        return textResult(JSON.stringify(payload, null, 2), payload);
      }
      await fs.promises.mkdir(path.dirname(target), { recursive: true });
      if (!overwrite) {
        const exists = await fs.promises.stat(target).then(() => true).catch(() => false);
        if (exists) {
          throw new Error(`target exists and overwrite=false: ${target}`);
        }
      }
      const tempPath = `${target}.tmp-${randomBytes(6).toString('hex')}`;
      await fs.promises.writeFile(tempPath, content, { encoding });
      await fs.promises.rename(tempPath, target);
      const info = await fileStat(target);
      return textResult(JSON.stringify(info, null, 2), info);
    },
  );

  server.registerTool(
    'upload_binary_file',
    {
      description: 'Upload a binary file to the remote host using base64 content.',
      inputSchema: {
        path: z.string().describe('Absolute path or path relative to FILE_ROOT.'),
        content_base64: z.string().describe('Base64-encoded file content.'),
        overwrite: z.boolean().default(true),
        as_root: z.boolean().default(false).describe('Use sudo/root privileges when true.'),
      },
    },
    async ({ path: inputPath, content_base64, overwrite, as_root }) => {
      const data = Buffer.from(content_base64, 'base64');
      if (data.length > MAX_FILE_BYTES) {
        throw new Error(`payload exceeds max size ${MAX_FILE_BYTES} bytes`);
      }
      const target = await resolveRequestedPath(inputPath, as_root);
      if (as_root) {
        const payload = await runRootFileOp({ op: 'upload_binary_file', path: target, content_base64, overwrite, max_file_bytes: MAX_FILE_BYTES });
        return textResult(JSON.stringify(payload, null, 2), payload);
      }
      await fs.promises.mkdir(path.dirname(target), { recursive: true });
      if (!overwrite) {
        const exists = await fs.promises.stat(target).then(() => true).catch(() => false);
        if (exists) {
          throw new Error(`target exists and overwrite=false: ${target}`);
        }
      }
      const tempPath = `${target}.tmp-${randomBytes(6).toString('hex')}`;
      await fs.promises.writeFile(tempPath, data);
      await fs.promises.rename(tempPath, target);
      const info = await fileStat(target);
      return textResult(JSON.stringify(info, null, 2), info);
    },
  );

  server.registerTool(
    'download_binary_file',
    {
      description: 'Download a binary file from the remote host as base64.',
      inputSchema: {
        path: z.string().describe('Absolute path or path relative to FILE_ROOT.'),
        max_bytes: z.number().int().positive().default(MAX_FILE_BYTES),
        as_root: z.boolean().default(false).describe('Use sudo/root privileges when true.'),
      },
    },
    async ({ path: inputPath, max_bytes, as_root }) => {
      const target = await resolveRequestedPath(inputPath, as_root);
      if (as_root) {
        const payload = await runRootFileOp({ op: 'download_binary_file', path: target, max_bytes });
        const size = Buffer.from(payload.content_base64 || '', 'base64').length;
        return textResult(JSON.stringify({ ...payload, content_base64: `[base64:${size} bytes]` }, null, 2), payload);
      }
      const stat = await fs.promises.stat(target).catch(() => null);
      if (!stat || !stat.isFile()) {
        throw new Error(`file not found: ${target}`);
      }
      if (stat.size > max_bytes) {
        throw new Error(`file exceeds max_bytes=${max_bytes}: ${target}`);
      }
      const content = await fs.promises.readFile(target);
      const payload = {
        ...(await fileStat(target)),
        content_base64: content.toString('base64'),
      };
      return textResult(JSON.stringify({ ...payload, content_base64: `[base64:${content.length} bytes]` }, null, 2), payload);
    },
  );

  server.registerTool(
    'make_directory',
    {
      description: 'Create a directory on the remote host.',
      inputSchema: {
        path: z.string().describe('Absolute path or path relative to FILE_ROOT.'),
        parents: z.boolean().default(true),
        as_root: z.boolean().default(false).describe('Use sudo/root privileges when true.'),
      },
    },
    async ({ path: inputPath, parents, as_root }) => {
      const target = await resolveRequestedPath(inputPath, as_root);
      if (as_root) {
        const payload = await runRootFileOp({ op: 'make_directory', path: target, parents });
        return textResult(JSON.stringify(payload, null, 2), payload);
      }
      await fs.promises.mkdir(target, { recursive: parents });
      const info = await fileStat(target);
      return textResult(JSON.stringify(info, null, 2), info);
    },
  );

  server.registerTool(
    'delete_path',
    {
      description: 'Delete a file or directory on the remote host.',
      inputSchema: {
        path: z.string().describe('Absolute path or path relative to FILE_ROOT.'),
        recursive: z.boolean().default(false),
        as_root: z.boolean().default(false).describe('Use sudo/root privileges when true.'),
      },
    },
    async ({ path: inputPath, recursive, as_root }) => {
      const target = await resolveRequestedPath(inputPath, as_root);
      if (as_root) {
        const payload = await runRootFileOp({ op: 'delete_path', path: target, recursive });
        return textResult(JSON.stringify(payload, null, 2), payload);
      }
      const info = await fileStat(target).catch(() => null);
      if (!info) {
        throw new Error(`path not found: ${target}`);
      }
      if (info.is_dir && !recursive) {
        throw new Error(`path is directory, set recursive=true: ${target}`);
      }
      await fs.promises.rm(target, { recursive, force: false });
      return textResult(JSON.stringify({ ok: true, ...info }, null, 2), { ok: true, ...info });
    },
  );

  server.registerTool(
    'run_command',
    {
      description: 'Run a shell command on the remote host and return stdout/stderr/exit_code.',
      inputSchema: {
        command: z.string().describe('Command executed by /bin/bash -lc'),
        cwd: z.string().default('.').describe('Absolute path or path relative to FILE_ROOT.'),
        timeout_seconds: z.number().int().positive().max(1800).default(120),
        as_root: z.boolean().default(false).describe('Use sudo/root privileges when true.'),
      },
    },
    async ({ command, cwd, timeout_seconds, as_root }) => {
      const workingDirectory = await resolveRequestedPath(cwd, as_root);
      const stat = await fs.promises.stat(workingDirectory).catch(() => null);
      if (!stat || !stat.isDirectory()) {
        throw new Error(`cwd not found or not a directory: ${workingDirectory}`);
      }

      try {
        const completed = await execShell(command, {
          cwd: workingDirectory,
          timeoutSeconds: timeout_seconds,
          asRoot: as_root,
        });

        const payload = {
          ok: true,
          timed_out: false,
          exit_code: 0,
          stdout: truncateText(completed.stdout ?? '', MAX_COMMAND_OUTPUT_BYTES),
          stderr: truncateText(completed.stderr ?? '', MAX_COMMAND_OUTPUT_BYTES),
          as_root: as_root,
        };
        return textResult(JSON.stringify(payload, null, 2), payload);
      } catch (error) {
        const payload = {
          ok: false,
          timed_out: error?.killed === true,
          exit_code: typeof error?.code === 'number' ? error.code : null,
          stdout: truncateText(error?.stdout ?? '', MAX_COMMAND_OUTPUT_BYTES),
          stderr: truncateText(error?.stderr ?? error?.message ?? '', MAX_COMMAND_OUTPUT_BYTES),
          as_root: as_root,
        };
        return textResult(JSON.stringify(payload, null, 2), payload);
      }
    },
  );

  return server;
}

const app = createMcpExpressApp({ host: HOST });
const transports = new Map();
const servers = new Map();

app.get('/health', (_req, res) => {
  res.json({
    ok: true,
    listen: `${HOST}:${PORT}${MCP_PATH}`,
    file_root: FILE_ROOT,
    transport_mode: MCP_TRANSPORT_MODE,
  });
});

function registerStatefulSession(transport, server) {
  transport.onclose = () => {
    const sid = transport.sessionId;
    if (sid) {
      transports.delete(sid);
      servers.delete(sid);
    }
  };

  return new StreamableHTTPServerTransport({
    sessionIdGenerator: () => randomUUID(),
    enableJsonResponse: true,
    onsessioninitialized: (sessionId) => {
      transports.set(sessionId, transport);
      servers.set(sessionId, server);
    },
    onsessionclosed: (sessionId) => {
      if (sessionId) {
        transports.delete(sessionId);
        servers.delete(sessionId);
      }
    },
  });
}

app.post(MCP_PATH, async (req, res) => {
  try {
    if (MCP_TRANSPORT_MODE === 'stateless') {
      const server = makeServer();
      const transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: undefined,
        enableJsonResponse: true,
      });
      try {
        await server.connect(transport);
        await transport.handleRequest(req, res, req.body);
      } finally {
        await transport.close().catch(() => {});
        await server.close().catch(() => {});
      }
      return;
    }

    const sessionIdHeader = req.headers['mcp-session-id'];
    const sessionId = Array.isArray(sessionIdHeader) ? sessionIdHeader[0] : sessionIdHeader;
    let transport = sessionId ? transports.get(sessionId) : undefined;

    if (!transport && !sessionId && isInitializeRequest(req.body)) {
      const server = makeServer();
      transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: () => randomUUID(),
        enableJsonResponse: true,
        onsessioninitialized: (newSessionId) => {
          transports.set(newSessionId, transport);
          servers.set(newSessionId, server);
        },
        onsessionclosed: (closedSessionId) => {
          if (closedSessionId) {
            transports.delete(closedSessionId);
            servers.delete(closedSessionId);
          }
        },
      });
      transport.onclose = () => {
        const sid = transport.sessionId;
        if (sid) {
          transports.delete(sid);
          servers.delete(sid);
        }
      };
      await server.connect(transport);
      await transport.handleRequest(req, res, req.body);
      return;
    }

    if (!transport) {
      res.status(400).json({
        jsonrpc: '2.0',
        error: { code: -32000, message: 'Bad Request: No valid session ID provided' },
        id: null,
      });
      return;
    }

    await transport.handleRequest(req, res, req.body);
  } catch (error) {
    console.error('Error handling MCP POST request:', error);
    if (!res.headersSent) {
      res.status(500).json({
        jsonrpc: '2.0',
        error: { code: -32603, message: 'Internal server error' },
        id: null,
      });
    }
  }
});

app.get(MCP_PATH, async (req, res) => {
  if (MCP_TRANSPORT_MODE !== 'stateful') {
    res.status(405).json({ jsonrpc: '2.0', error: { code: -32000, message: 'GET is disabled in stateless mode.' }, id: null });
    return;
  }

  try {
    const sessionIdHeader = req.headers['mcp-session-id'];
    const sessionId = Array.isArray(sessionIdHeader) ? sessionIdHeader[0] : sessionIdHeader;
    const transport = sessionId ? transports.get(sessionId) : undefined;
    if (!transport) {
      res.status(400).json({ jsonrpc: '2.0', error: { code: -32000, message: 'Invalid or missing session ID' }, id: null });
      return;
    }
    await transport.handleRequest(req, res);
  } catch (error) {
    console.error('Error handling MCP GET request:', error);
    if (!res.headersSent) {
      res.status(500).json({ jsonrpc: '2.0', error: { code: -32603, message: 'Internal server error' }, id: null });
    }
  }
});

app.delete(MCP_PATH, async (req, res) => {
  if (MCP_TRANSPORT_MODE !== 'stateful') {
    res.status(405).json({ jsonrpc: '2.0', error: { code: -32000, message: 'DELETE is disabled in stateless mode.' }, id: null });
    return;
  }

  try {
    const sessionIdHeader = req.headers['mcp-session-id'];
    const sessionId = Array.isArray(sessionIdHeader) ? sessionIdHeader[0] : sessionIdHeader;
    const transport = sessionId ? transports.get(sessionId) : undefined;
    if (!transport) {
      res.status(400).json({ jsonrpc: '2.0', error: { code: -32000, message: 'Invalid or missing session ID' }, id: null });
      return;
    }
    await transport.handleRequest(req, res);
  } catch (error) {
    console.error('Error handling MCP DELETE request:', error);
    if (!res.headersSent) {
      res.status(500).json({ jsonrpc: '2.0', error: { code: -32603, message: 'Internal server error' }, id: null });
    }
  }
});

const listener = app;
const httpServer = TLS_CERT_FILE && TLS_KEY_FILE
  ? https.createServer({ cert: fs.readFileSync(TLS_CERT_FILE), key: fs.readFileSync(TLS_KEY_FILE) }, listener)
  : http.createServer(listener);

httpServer.listen(PORT, HOST, () => {
  const scheme = TLS_CERT_FILE && TLS_KEY_FILE ? 'https' : 'http';
  console.log(`Bianbu MCP server listening at ${scheme}://${HOST}:${PORT}${MCP_PATH} (${MCP_TRANSPORT_MODE})`);
});

process.on('unhandledRejection', (error) => {
  console.error('Unhandled rejection:', error);
});

process.on('uncaughtException', (error) => {
  console.error('Uncaught exception:', error);
  process.exit(1);
});

process.on('SIGINT', () => process.exit(0));
process.on('SIGTERM', () => process.exit(0));
EOF
}

install_node_modules() {
  ensure_node_version
  log "安装 Node 依赖到: $INSTALL_ROOT"
  run_as_root rm -rf "$INSTALL_ROOT/node_modules" "$INSTALL_ROOT/package-lock.json"
  run_as_root sh -c "cd '$INSTALL_ROOT' && npm install --omit=dev --no-fund --no-audit"
  run_as_root test -f "$INSTALL_ROOT/node_modules/@modelcontextprotocol/sdk/package.json" || die "npm 安装后缺少 @modelcontextprotocol/sdk"
  run_as_root test -f "$INSTALL_ROOT/node_modules/zod/package.json" || die "npm 安装后缺少 zod"
  run_as_root chmod -R a+rX "$INSTALL_ROOT/node_modules"
  run_as_root sh -c "cd '$INSTALL_ROOT' && node -e \"import('./server.mjs').then(() => process.exit(0)).catch((err) => { console.error(err); process.exit(1); })\"" || die "Node 运行时无法解析 MCP server"
}

write_env() {
  write_root_file "$ENV_FILE" 600 <<EOF
HOST=${HOST}
PORT=${PORT}
MCP_PATH=${MCP_PATH}
MCP_TRANSPORT_MODE=${MCP_TRANSPORT_MODE}
RUN_USER=${RUN_USER}
RUN_GROUP=${RUN_GROUP}
FILE_ROOT=${FILE_ROOT}
ENABLE_PASSWORDLESS_SUDO=${ENABLE_PASSWORDLESS_SUDO}
MAX_FILE_MB=${MAX_FILE_MB}
MAX_COMMAND_OUTPUT_KB=${MAX_COMMAND_OUTPUT_KB}
TLS_CERT_FILE=${TLS_CERT_FILE}
TLS_KEY_FILE=${TLS_KEY_FILE}
EOF
}

write_service() {
  write_root_file "$SERVICE_FILE" 644 <<EOF
[Unit]
Description=Bianbu MCP Server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
EnvironmentFile=-${ENV_FILE}
WorkingDirectory=${INSTALL_ROOT}
User=${RUN_USER}
Group=${RUN_GROUP}
ExecStart=/usr/bin/env node ${APP_FILE}
Restart=always
RestartSec=5
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
}

cmd_install() {
  if ! command -v apt-get >/dev/null 2>&1; then
    die "当前系统没有 apt-get，脚本按 Debian/Ubuntu/Bianbu OS 体系编写"
  fi

  log "安装依赖: nodejs npm curl ca-certificates python3 sudo"
  run_as_root apt-get update
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    nodejs npm curl ca-certificates python3 sudo
  ensure_node_version
  log "依赖安装完成"
}

cmd_bootstrap() {
  require_systemd
  cmd_install
  ensure_runtime_user
  configure_passwordless_sudo
  cleanup_legacy_install
  write_package
  write_app
  install_node_modules
  write_env
  write_service
  finalize_service_start

  log "bootstrap 完成"
  log "健康检查: curl http://127.0.0.1:${PORT}/health"
  if [ -n "$TLS_CERT_FILE" ] && [ -n "$TLS_KEY_FILE" ]; then
    log "MCP 地址: https://<你的主机>:${PORT}${MCP_PATH}"
  else
    log "MCP 地址: http://<你的主机>:${PORT}${MCP_PATH}"
    log "警告: 当前未配置 TLS。公网使用时请设置 TLS_CERT_FILE/TLS_KEY_FILE 或放在 HTTPS 反向代理后。"
  fi
  log "MCP 传输模式: ${MCP_TRANSPORT_MODE}"
}

cmd_start() {
  require_systemd
  run_as_root systemctl start "$SERVICE_NAME"
}

cmd_stop() {
  require_systemd
  run_as_root systemctl stop "$SERVICE_NAME"
}

cmd_restart() {
  require_systemd
  finalize_service_start
}

cmd_repair() {
  require_systemd
  finalize_service_start
}

cmd_recover() {
  cmd_bootstrap
}

cmd_status() {
  require_systemd
  run_as_root systemctl --no-pager --full status "$SERVICE_NAME"
}

cmd_logs() {
  require_systemd
  run_as_root journalctl -u "$SERVICE_NAME" --no-pager "$@"
}

cmd_show_config() {
  cat <<EOF
SERVICE_NAME=${SERVICE_NAME}
HOST=${HOST}
PORT=${PORT}
MCP_PATH=${MCP_PATH}
MCP_TRANSPORT_MODE=${MCP_TRANSPORT_MODE}
RUN_USER=${RUN_USER}
RUN_GROUP=${RUN_GROUP}
FILE_ROOT=${FILE_ROOT}
ENABLE_PASSWORDLESS_SUDO=${ENABLE_PASSWORDLESS_SUDO}
MAX_FILE_MB=${MAX_FILE_MB}
MAX_COMMAND_OUTPUT_KB=${MAX_COMMAND_OUTPUT_KB}
TLS_CERT_FILE=${TLS_CERT_FILE}
TLS_KEY_FILE=${TLS_KEY_FILE}
EOF
}

main() {
  local cmd="${1:-up}"
  shift || true

  case "$cmd" in
    install) cmd_install "$@" ;;
    up) cmd_recover "$@" ;;
    bootstrap) cmd_bootstrap "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    restart) cmd_restart "$@" ;;
    status) cmd_status "$@" ;;
    recover) cmd_recover "$@" ;;
    repair) cmd_repair "$@" ;;
    logs) cmd_logs "$@" ;;
    show-config) cmd_show_config "$@" ;;
    help|-h|--help) usage ;;
    *) die "未知命令: $cmd，执行 '$SCRIPT_NAME help' 查看帮助" ;;
  esac
}

main "$@"
