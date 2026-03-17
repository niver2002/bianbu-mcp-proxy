import { runOfficialClientFlow } from './shared.mjs';

const summary = await runOfficialClientFlow({
  name: 'bianbu-mcp-platform-test',
  label: 'hello from official stateless client',
});

process.stdout.write(JSON.stringify(summary, null, 2));
