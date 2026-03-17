import { config, baseToolCases, postJsonRpc } from './shared.mjs';

const results = [];

const init = await postJsonRpc({
  jsonrpc: '2.0',
  id: 'init-1',
  method: 'initialize',
  params: {
    protocolVersion: config.protocolVersion,
    capabilities: {},
    clientInfo: { name: 'session-raw-test', version: '1.1.0' },
  },
});

results.push({ step: 'initialize', ...init });

const sessionId = init.headers['mcp-session-id'] ?? null;
results.push({ step: 'session', sessionId });

if (sessionId) {
  results.push({
    step: 'initialized',
    ...(await postJsonRpc(
      { jsonrpc: '2.0', method: 'notifications/initialized', params: {} },
      { sessionId },
    )),
  });

  results.push({
    step: 'tools/list',
    ...(await postJsonRpc(
      { jsonrpc: '2.0', id: 'tools-1', method: 'tools/list', params: {} },
      { sessionId },
    )),
  });

  for (const entry of baseToolCases('hello from session raw test')) {
    if (typeof entry[1] === 'object' && entry[1] !== null && 'tool' in entry[1]) {
      results.push({
        step: entry[0],
        ...(await postJsonRpc(
          { jsonrpc: '2.0', id: `id-${entry[0]}`, method: 'tools/call', params: { name: entry[1].tool, arguments: entry[1].args } },
          { sessionId },
        )),
      });
    } else {
      results.push({
        step: entry[0],
        ...(await postJsonRpc(
          { jsonrpc: '2.0', id: `id-${entry[0]}`, method: 'tools/call', params: { name: entry[0], arguments: entry[1] } },
          { sessionId },
        )),
      });
    }
  }
}

console.log(JSON.stringify(results, null, 2));
