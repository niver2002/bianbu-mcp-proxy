import { config, postJsonRpc } from './shared.mjs';

const steps = [];

async function call(name, args) {
  const res = await postJsonRpc({
    jsonrpc: '2.0',
    id: `id-${name}`,
    method: 'tools/call',
    params: { name, arguments: args },
  });
  steps.push({ step: name, ...res });
}

await call('health', {});
await call('run_command', { command: 'id && whoami', cwd: '/', timeout_seconds: 30, as_root: true });
await call('make_directory', { path: '/root/mcp_root_test/subdir', parents: true, as_root: true });
await call('write_text_file', { path: '/root/mcp_root_test/hello.txt', content: 'hello from root tool test', overwrite: true, encoding: 'utf-8', as_root: true });
await call('read_text_file', { path: '/root/mcp_root_test/hello.txt', max_bytes: 8192, encoding: 'utf-8', as_root: true });
await call('upload_binary_file', { path: '/root/mcp_root_test/blob.bin', content_base64: 'aGVsbG8=', overwrite: true, as_root: true });
await call('download_binary_file', { path: '/root/mcp_root_test/blob.bin', max_bytes: 8192, as_root: true });
await call('list_directory', { path: '/root/mcp_root_test', as_root: true });
await call('delete_path', { path: '/root/mcp_root_test/blob.bin', recursive: false, as_root: true });
await call('delete_path', { path: '/root/mcp_root_test/hello.txt', recursive: false, as_root: true });
await call('delete_path', { path: '/root/mcp_root_test/subdir', recursive: true, as_root: true });
await call('delete_path', { path: '/root/mcp_root_test', recursive: true, as_root: true });

console.log(JSON.stringify(steps, null, 2));
