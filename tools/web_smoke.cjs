// Release-build smoke checks in an isolated headless Chrome profile. No login
// or authenticated writes. Usage: node tools/web_smoke.cjs [https://host/]
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { spawn } = require('node:child_process');
const assert = require('node:assert/strict');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const root = path.resolve('build/web');
const output = path.resolve('build/audit');
fs.mkdirSync(output, { recursive: true });
let server, chrome, socket, next = 0;
const pending = new Map(), errors = [], rendering = new Set();
function call(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++next;
    const timer = setTimeout(() => { pending.delete(id); reject(Error(`CDP timeout: ${method}`)); }, 15000);
    pending.set(id, value => { clearTimeout(timer); value.error ? reject(Error(value.error.message)) : resolve(value.result); });
    socket.send(JSON.stringify({ id, method, params }));
  });
}
async function evaluate(expression) {
  const r = await call('Runtime.evaluate', { expression, returnByValue: true });
  if (r.exceptionDetails) throw Error(r.exceptionDetails.text);
  return r.result.value;
}
async function waitFor(expression, ms = 25000) {
  const start = Date.now();
  while (Date.now() - start < ms) {
    if (await evaluate(expression)) return Date.now() - start;
    await sleep(200);
  }
  throw Error(`Page did not become ready: ${expression}`);
}
async function loginReady() {
  await waitFor("!document.getElementById('bootstrap-status') && !!document.querySelector('flutter-view')");
  await evaluate("document.querySelector('flt-semantics-placeholder')?.click()");
  await waitFor(`(() => {
    const roots = [document];
    for (let i = 0; i < roots.length; i++) {
      for (const node of roots[i].querySelectorAll('*')) if (node.shadowRoot) roots.push(node.shadowRoot);
    }
    return roots.some(root => [...root.querySelectorAll('[aria-label]')].some(n => /PLAYER LOGIN|SIGN UP|ALREADY A HERO/.test(n.getAttribute('aria-label'))));
  })()`);
}
(async () => {
  try {
    let url = process.argv[2];
    if (url) assert.match(url, /^https:\/\/hakbanghero(?:\.web\.app|\.firebaseapp\.com)\/$/);
    else {
      const types = { '.js': 'text/javascript', '.json': 'application/json', '.wasm': 'application/wasm', '.html': 'text/html', '.png': 'image/png', '.ttf': 'font/ttf', '.otf': 'font/otf' };
      server = http.createServer((req, res) => {
        const relative = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
        let file = path.resolve(root, '.' + relative);
        if (file !== root && !file.startsWith(root + path.sep)) { res.writeHead(403).end(); return; }
        if (file === root || !fs.existsSync(file)) file = path.join(root, 'index.html');
        res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream' });
        fs.createReadStream(file).pipe(res);
      });
      await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
      url = `http://127.0.0.1:${server.address().port}/`;
    }
    const profile = path.join(output, `chrome-smoke-${Date.now()}`);
    fs.mkdirSync(profile);
    chrome = spawn(process.env.CHROME_EXECUTABLE || 'C:/Program Files/Google/Chrome/Application/chrome.exe',
      ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'],
      { windowsHide: true, stdio: 'ignore' });
    const activePort = path.join(profile, 'DevToolsActivePort');
    for (let i = 0; !fs.existsSync(activePort) && i < 100; i++) await sleep(100);
    const port = fs.readFileSync(activePort, 'utf8').split('\n')[0];
    const target = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find(t => t.type === 'page');
    socket = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise(resolve => socket.addEventListener('open', resolve, { once: true }));
    socket.addEventListener('message', event => {
      const m = JSON.parse(event.data);
      if (m.id) { pending.get(m.id)?.(m); pending.delete(m.id); }
      if (m.method === 'Runtime.exceptionThrown') errors.push(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text);
      if (m.method === 'Network.requestWillBeSent' && /canvaskit\.(wasm|js)/.test(m.params.request.url)) rendering.add(m.params.request.url);
    });
    await call('Runtime.enable'); await call('Page.enable'); await call('Network.enable');
    await call('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
    const began = Date.now();
    await call('Page.navigate', { url }); await loginReady();
    const first = Date.now() - began;
    const screenshot = await call('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(output, 'web-smoke.png'), Buffer.from(screenshot.data, 'base64'));
    const refreshed = Date.now();
    await call('Page.reload', { ignoreCache: false }); await sleep(250); await loginReady();
    const refresh = Date.now() - refreshed;
    assert.equal(errors.length, 0, errors.join('\n'));
    assert.ok(rendering.size > 0, 'The rendering engine must load.');
    assert.ok([...rendering].every(u => new URL(u).origin === new URL(url).origin), 'Rendering assets should use the app origin.');
    const report = { url, browser: 'Desktop Chrome, 390x844 viewport', firstLoginMs: first, refreshLoginMs: refresh,
      uncaughtErrors: errors, renderingAssets: [...rendering] };
    fs.writeFileSync(path.join(output, 'web-smoke.json'), JSON.stringify(report, null, 2));
    console.log(JSON.stringify(report, null, 2));
  } finally {
    socket?.close(); chrome?.kill(); server?.closeAllConnections(); server?.close();
  }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
