import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

export const config = {
  serverUrl: process.env.MCP_SERVER_URL || 'http://127.0.0.1:11434/mcp',
  gatewayKey: process.env.MCP_GATEWAY_KEY || '',
  protocolVersion: process.env.MCP_PROTOCOL_VERSION || '2025-11-25',
  minIntervalMs: Number(process.env.MCP_MIN_INTERVAL_MS || '1000'),
  maxRetries: Number(process.env.MCP_MAX_RETRIES || '2'),
  retryBaseMs: Number(process.env.MCP_RETRY_BASE_MS || '1000'),
};

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function shouldRetryStatus(status) {
  return status === 429 || status === 502 || status === 503 || status === 504;
}

function jitter(ms) {
  return ms + Math.floor(Math.random() * 250);
}

const originalFetch = globalThis.fetch.bind(globalThis);
let nextAllowedAt = 0;

async function pacedFetch(input, init) {
  const now = Date.now();
  const waitMs = Math.max(0, nextAllowedAt - now);
  if (waitMs > 0) {
    await sleep(waitMs);
  }
  nextAllowedAt = Date.now() + config.minIntervalMs;
  return originalFetch(input, init);
}

async function resilientFetch(input, init) {
  let lastResponse = null;
  let lastBody = '';
  let lastError = null;

  for (let attempt = 0; attempt <= config.maxRetries; attempt += 1) {
    try {
      const response = await pacedFetch(input, init);
      if (!shouldRetryStatus(response.status)) {
        return response;
      }

      lastResponse = response;
      lastBody = await response.text().catch(() => '');
    } catch (error) {
      lastError = error;
    }

    if (attempt < config.maxRetries) {
      await sleep(jitter(config.retryBaseMs * (attempt + 1)));
      continue;
    }
  }

  if (lastResponse) {
    return new Response(lastBody, {
      status: lastResponse.status,
      statusText: lastResponse.statusText,
      headers: lastResponse.headers,
    });
  }

  throw lastError ?? new Error('fetch failed without response');
}

globalThis.fetch = resilientFetch;

export function buildHeaders() {
  const headers = {};
  if (config.gatewayKey) {
    headers['X-API-KEY'] = config.gatewayKey;
  }
  return headers;
}

export function createTransport() {
  return new StreamableHTTPClientTransport(new URL(config.serverUrl), {
    requestInit: {
      headers: buildHeaders(),
    },
  });
}

export function createClient(name) {
  return new Client(
    {
      name,
      version: '1.1.0',
    },
    {
      capabilities: {},
    },
  );
}

export function baseToolCases(label = 'hello from mcp client') {
  return [
    ['health', {}],
    ['list_directory', { path: '.' }],
    ['make_directory', { path: 'mcp_test/subdir', parents: true }],
    ['write_text_file', { path: 'mcp_test/hello.txt', content: label, overwrite: true, encoding: 'utf-8' }],
    ['read_text_file', { path: 'mcp_test/hello.txt', max_bytes: 8192, encoding: 'utf-8' }],
    ['upload_binary_file', { path: 'mcp_test/blob.bin', content_base64: 'aGVsbG8=', overwrite: true }],
    ['download_binary_file', { path: 'mcp_test/blob.bin', max_bytes: 8192 }],
    ['run_command', { command: 'pwd && whoami && ls -1 mcp_test', cwd: '.', timeout_seconds: 30 }],
    ['delete_path_blob', { tool: 'delete_path', args: { path: 'mcp_test/blob.bin', recursive: false } }],
    ['delete_path_text', { tool: 'delete_path', args: { path: 'mcp_test/hello.txt', recursive: false } }],
    ['delete_path_subdir_recursive', { tool: 'delete_path', args: { path: 'mcp_test/subdir', recursive: true } }],
    ['delete_path_root_recursive', { tool: 'delete_path', args: { path: 'mcp_test', recursive: true } }],
  ];
}

export async function runOfficialClientFlow({ name, label }) {
  const transport = createTransport();
  const client = createClient(name);
  const summary = [];

  try {
    await client.connect(transport);
    summary.push({
      step: 'connect',
      ok: true,
      sessionId: transport.sessionId ?? null,
      protocolVersion: transport.protocolVersion ?? null,
      url: config.serverUrl,
    });

    const tools = await client.listTools();
    summary.push({ step: 'listTools', ok: true, count: tools.tools.length, names: tools.tools.map((tool) => tool.name) });

    for (const entry of baseToolCases(label)) {
      if (typeof entry[1] === 'object' && entry[1] !== null && 'tool' in entry[1]) {
        const result = await client.callTool({ name: entry[1].tool, arguments: entry[1].args });
        summary.push({ step: entry[0], ok: true, result });
      } else {
        const result = await client.callTool({ name: entry[0], arguments: entry[1] });
        summary.push({ step: entry[0], ok: true, result });
      }
    }
  } catch (error) {
    summary.push({ step: 'fatal', ok: false, error: String(error), stack: error?.stack ?? null });
  } finally {
    try {
      await transport.close();
    } catch {
      // ignore
    }
  }

  return summary;
}

export async function postJsonRpc(payload, { sessionId } = {}) {
  const headers = {
    ...buildHeaders(),
    'Content-Type': 'application/json',
    Accept: 'application/json, text/event-stream',
    'MCP-Protocol-Version': config.protocolVersion,
  };

  if (sessionId) {
    headers['MCP-Session-Id'] = sessionId;
  }

  const response = await fetch(config.serverUrl, {
    method: 'POST',
    headers,
    body: JSON.stringify(payload),
  });

  const text = await response.text().catch(() => '');
  return {
    status: response.status,
    headers: Object.fromEntries(response.headers.entries()),
    body: text,
    parsed: parseMaybeJson(text),
  };
}

export function parseMaybeJson(text) {
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {}

  const sseMatch = text.match(/data:\s*(\{[\s\S]*\})/);
  if (sseMatch) {
    try {
      return JSON.parse(sseMatch[1]);
    } catch {}
  }

  return { raw: text };
}
