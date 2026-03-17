import { config, postJsonRpc } from './shared.mjs';

const steps = [];
const initialize = await postJsonRpc({
  jsonrpc: '2.0',
  id: 'init-1',
  method: 'initialize',
  params: {
    protocolVersion: config.protocolVersion,
    capabilities: {},
    clientInfo: { name: 'debug-client', version: '1.1.0' },
  },
});

steps.push({ step: 'initialize', ...initialize });

const sessionId = initialize.headers['mcp-session-id'] ?? null;
steps.push({ step: 'session', sessionId });

if (sessionId) {
  steps.push({
    step: 'initialized',
    ...(await postJsonRpc(
      { jsonrpc: '2.0', method: 'notifications/initialized', params: {} },
      { sessionId },
    )),
  });

  steps.push({
    step: 'tools/list',
    ...(await postJsonRpc(
      { jsonrpc: '2.0', id: 'tools-1', method: 'tools/list', params: {} },
      { sessionId },
    )),
  });
}

console.log(JSON.stringify(steps, null, 2));
