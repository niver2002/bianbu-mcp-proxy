import { runOfficialClientFlow } from './shared.mjs';

const summary = await runOfficialClientFlow({
  name: 'bianbu-mcp-stateful-test',
  label: 'hello from official stateful client',
});

process.stdout.write(JSON.stringify(summary, null, 2));
