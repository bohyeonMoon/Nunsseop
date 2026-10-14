// Runs the bridge extension (Resources/muxy-bridge) against stand-ins for the `muxy` object Muxy 2 gives a background script and a page.
// Their shape follows Muxy's docs/extensions/api.md and its bridge scripts: the background one is synchronous and has only `tabs.open`;
// the page one is async and has `tabs.switchTo`, `projects.switchTo`, `events.emit` and `lifecycle.close`.
// Run by Swift (MuxyBridgeTests) when node is installed, or by hand: node --test Tests/muxy-bridge
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const vm = require('node:vm');

const folder = `${__dirname}/../../Resources/muxy-bridge`;
const read = (name) => readFileSync(`${folder}/${name}`, 'utf8');
const clone = (value) => (value === undefined ? undefined : JSON.parse(JSON.stringify(value)));
const settled = async () => { for (let i = 0; i < 10; i++) await new Promise((resolve) => setImmediate(resolve)); };

const PANE = '8f074f0d13c34a0fbd206cd8bf291bfc';
const PROJECT = 'aa2932bc99a44172845b99e03f715c77';
const COMMAND = "sh '/Users/me/Library/Application Support/Nunsseop/muxy-resume.sh'";
const NOW = 1_800_000_000_000;

function background({ storage = {}, openFails = false } = {}) {
  const store = new Map(Object.entries(storage));
  const opened = [], intervals = [], handlers = {}, logged = [];
  let clock = NOW;
  const muxy = Object.freeze({
    extensionID: 'nunsseop-bridge',
    storage: {
      get: (key) => (store.has(key) ? clone(store.get(key)) : null),
      set: (key, value) => { store.set(key, clone(value)); return null; },
    },
    tabs: { open: (request) => { if (openFails) throw new Error('could not open'); opened.push(clone(request)); return 'tab'; } },
    events: { subscribe: (name, handler) => { handlers[name] = handler; return () => {}; } },
  });
  const context = vm.createContext({
    muxy,
    console: { log: (m) => logged.push(m), warn: (m) => logged.push(m), error: (m) => logged.push(m) },
    setInterval: (callback, ms) => { intervals.push({ callback, ms }); return intervals.length; },
    Date: { now: () => clock },
  });
  vm.runInContext(read('background.js'), context);
  const every = (ms) => intervals.find((interval) => interval.ms === ms).callback;
  return {
    store, opened, handlers, logged,
    poll: () => every(100)(),
    beat: () => every(5000)(),
    intervals: () => intervals.map((interval) => interval.ms),
    advance: (ms) => { clock += ms; },
    request: (extra = {}) => { store.set('req', { id: 'r1', at: clock, type: 'focus', pane: PANE, ...extra }); },
  };
}

test('the manifest asks for exactly what the bridge uses', () => {
  const manifest = JSON.parse(read('package.json'));
  assert.equal(manifest.name, 'nunsseop-bridge');
  assert.match(manifest.name, /^[a-z0-9.-]+$/);
  assert.equal(manifest.muxy.background, 'background.js');
  assert.deepEqual([...manifest.muxy.permissions].sort(), ['projects:write', 'storage:read', 'storage:write', 'tabs:write']);
  assert.deepEqual(manifest.muxy.tabTypes, [{ id: 'helper', title: 'Nunsseop', entry: 'helper.html' }]);
  assert.match(read('helper.html'), /<script src="helper\.js"><\/script>/);
});

test('it writes a heartbeat at once and then every five seconds, and looks for a request every tenth of a second', () => {
  const b = background();
  assert.equal(b.store.get('alive'), NOW);
  assert.deepEqual(b.intervals().sort((x, y) => x - y), [100, 5000]);
  b.advance(5000);
  b.beat();
  assert.equal(b.store.get('alive'), NOW + 5000);
});

test('a fresh request opens the helper tab of this extension with the request as its data, once', () => {
  const b = background();
  b.request();
  b.poll();
  b.poll();
  assert.deepEqual(b.opened, [{ kind: 'extensionWebView', extension: { id: 'nunsseop-bridge', tabType: 'helper', data: { id: 'r1', at: NOW, type: 'focus', pane: PANE } } }]);
  assert.equal(b.store.has('ack'), false);
  b.store.set('req', { id: 'r2', at: NOW, type: 'focus', pane: PANE });
  b.poll();
  assert.equal(b.opened.length, 2);
});

test('a request left from before is not acted on', () => {
  const b = background();
  b.request({ at: NOW - 31000 });
  b.poll();
  b.store.set('req', { id: 'r2', type: 'focus', pane: PANE });
  b.poll();
  assert.deepEqual(b.opened, []);
  assert.equal(b.store.has('ack'), false);
});

test('a request that was answered before the script started is not acted on again', () => {
  const b = background({ storage: { req: { id: 'r1', at: NOW, type: 'focus', pane: PANE }, ack: { id: 'r1', ok: true } } });
  b.poll();
  assert.deepEqual(b.opened, []);
});

test('a request with anything unexpected in it is refused with an ack and opens nothing', () => {
  const cases = [
    [{ pane: 'not-a-pane' }, 'invalid pane'],
    [{ pane: `${PANE}; x` }, 'invalid pane'],
    [{ type: 'resume', folder: 'relative', command: COMMAND }, 'invalid folder'],
    [{ type: 'resume', folder: '/tmp', command: COMMAND, project: 'x' }, 'invalid project'],
    [{ type: 'resume', folder: '/tmp', command: "sh '/tmp/other.sh'" }, 'invalid command'],
    [{ type: 'resume', folder: '/tmp', command: `${COMMAND}; rm -rf /` }, 'invalid command'],
    [{ type: 'resume', folder: '/tmp', command: "sh '/a'b/Nunsseop/muxy-resume.sh'" }, 'invalid command'],
    [{ type: 'resume', folder: '/tmp', command: 'sh \'/a/Nunsseop/muxy-resume.sh\'\n' }, 'invalid command'],
    [{ type: 'delete-everything' }, 'unknown request'],
  ];
  for (const [extra, error] of cases) {
    const b = background();
    b.request(extra);
    b.poll();
    assert.deepEqual(b.opened, [], JSON.stringify(extra));
    assert.deepEqual(b.store.get('ack'), { id: 'r1', ok: false, error }, JSON.stringify(extra));
  }
});

test('a resume request with the fixed command is passed to the helper', () => {
  const b = background();
  b.request({ type: 'resume', folder: '/Users/me/dev', project: PROJECT, command: COMMAND, pane: undefined });
  b.poll();
  assert.equal(b.opened.length, 1);
  assert.equal(b.opened[0].extension.data.command, COMMAND);
  assert.equal(b.opened[0].extension.data.project, PROJECT);
});

test('the helper tab failing to open is answered at once', () => {
  const b = background({ openFails: true });
  b.request();
  b.poll();
  assert.deepEqual(b.store.get('ack'), { id: 'r1', ok: false, error: 'could not open' });
});

test('the helper reports through an extension event, which becomes the ack; another request\'s report is ignored', () => {
  const b = background();
  b.request();
  b.poll();
  b.handlers['extension.result']({ id: 'other', ok: true });
  assert.equal(b.store.has('ack'), false);
  b.handlers['extension.result']({ id: 'r1', ok: true });
  assert.deepEqual(b.store.get('ack'), { id: 'r1', ok: true });
  const f = background();
  f.request();
  f.poll();
  f.handlers['extension.result']({ id: 'r1', ok: false, error: 'tab not found x' });
  assert.deepEqual(f.store.get('ack'), { id: 'r1', ok: false, error: 'tab not found x' });
});

test('an ack that a write of Nunsseop\'s took out of the file is written again', () => {
  const b = background();
  b.request();
  b.poll();
  b.handlers['extension.result']({ id: 'r1', ok: true });
  b.store.delete('ack');
  b.poll();
  assert.deepEqual(b.store.get('ack'), { id: 'r1', ok: true });
  assert.equal(b.opened.length, 1);
});

test('the result of a request that another one superseded is still acked, and the request is not opened again when it is written back', () => {
  const b = background();
  // R waits on Muxy's prompt; F arrives meanwhile and takes the place of R in the file.
  b.request({ id: 'R', type: 'resume', folder: '/tmp', command: COMMAND });
  b.poll();
  b.request({ id: 'F' });
  b.poll();
  assert.equal(b.opened.length, 2);
  // Nunsseop, still waiting for R, writes R back.
  b.request({ id: 'R', type: 'resume', folder: '/tmp', command: COMMAND });
  b.poll();
  assert.equal(b.opened.length, 2);
  b.handlers['extension.result']({ id: 'R', ok: true });
  assert.deepEqual(b.store.get('ack'), { id: 'R', ok: true });
  // The report is acted on once: the same one again, or one nobody asked for, writes nothing.
  b.store.delete('ack');
  b.handlers['extension.result']({ id: 'R', ok: true });
  b.handlers['extension.result']({ id: 'X', ok: true });
  assert.equal(b.store.has('ack'), false);
  b.handlers['extension.result']({ id: 'F', ok: false, error: 'tab not found' });
  assert.deepEqual(b.store.get('ack'), { id: 'F', ok: false, error: 'tab not found' });
});

test('a stored request that is not an object is ignored', () => {
  const b = background();
  b.store.set('req', 'not an object');
  assert.doesNotThrow(() => b.poll());
  assert.deepEqual(b.opened, []);
});

function page(data, { fail = {}, now = NOW } = {}) {
  const calls = [];
  let closed = false;
  const step = (name, ...args) => {
    calls.push([name, ...args.map(clone)]);
    if (fail[name]) return Promise.reject(new Error(fail[name]));
    return Promise.resolve(null);
  };
  const muxy = {
    data,
    tabs: { switchTo: (id) => step('tabs.switchTo', id), open: (request) => step('tabs.open', request) },
    projects: { switchTo: (id) => step('projects.switchTo', id) },
    events: { emit: (name, payload) => step('events.emit', name, payload) },
    lifecycle: { close: () => { closed = true; return step('lifecycle.close'); } },
  };
  const context = vm.createContext({ muxy, Date: { now: () => now }, console });
  vm.runInContext(read('helper.js'), context);
  return { calls, closed: () => closed };
}

test('helper: a focus request selects the pane\'s tab, reports success and closes itself, in that order', async () => {
  const h = page({ id: 'r1', at: NOW, type: 'focus', pane: PANE });
  await settled();
  assert.deepEqual(h.calls, [
    ['tabs.switchTo', PANE],
    ['events.emit', 'extension.result', { id: 'r1', ok: true }],
    ['lifecycle.close'],
  ]);
});

test('helper: a resume request switches to its project, then opens a terminal tab with the fixed command', async () => {
  const h = page({ id: 'r2', at: NOW, type: 'resume', folder: '/Users/me/dev', project: PROJECT, command: COMMAND });
  await settled();
  assert.deepEqual(h.calls, [
    ['projects.switchTo', PROJECT],
    ['tabs.open', { kind: 'terminal', command: COMMAND }],
    ['events.emit', 'extension.result', { id: 'r2', ok: true }],
    ['lifecycle.close'],
  ]);
});

test('helper: a resume request without a project opens the tab in the current one', async () => {
  const h = page({ id: 'r3', at: NOW, type: 'resume', folder: '/Users/me/dev', command: COMMAND });
  await settled();
  assert.deepEqual(h.calls.map((call) => call[0]), ['tabs.open', 'events.emit', 'lifecycle.close']);
});

test('helper: a command other than the launcher is refused and nothing is opened', async () => {
  for (const command of ["sh '/tmp/x.sh'", 'rm -rf /', `${COMMAND} && id`, undefined]) {
    const h = page({ id: 'r4', at: NOW, type: 'resume', folder: '/tmp', command });
    await settled();
    assert.deepEqual(h.calls.map((call) => call[0]), ['events.emit', 'lifecycle.close'], String(command));
    assert.deepEqual(h.calls[0][2], { id: 'r4', ok: false, error: 'invalid command' });
  }
});

test('helper: an invalid pane is refused, and a call that Muxy rejects is reported with its message', async () => {
  const bad = page({ id: 'r5', at: NOW, type: 'focus', pane: '../x' });
  await settled();
  assert.deepEqual(bad.calls.map((call) => call[0]), ['events.emit', 'lifecycle.close']);
  assert.equal(bad.calls[0][2].ok, false);
  const rejected = page({ id: 'r6', at: NOW, type: 'focus', pane: PANE }, { fail: { 'tabs.switchTo': 'tab not found x' } });
  await settled();
  assert.deepEqual(rejected.calls.slice(1), [
    ['events.emit', 'extension.result', { id: 'r6', ok: false, error: 'tab not found x' }],
    ['lifecycle.close'],
  ]);
  const denied = page({ id: 'r7', at: NOW, type: 'resume', folder: '/tmp', command: COMMAND }, { fail: { 'tabs.open': 'user denied consent' } });
  await settled();
  assert.equal(denied.calls[1][2].error, 'user denied consent');
  assert.equal(denied.closed(), true);
});

test('helper: a tab restored with an old request, or none, only closes', async () => {
  const old = page({ id: 'r8', at: NOW - 31000, type: 'focus', pane: PANE });
  await settled();
  assert.deepEqual(old.calls, [['lifecycle.close']]);
  const empty = page(null);
  await settled();
  assert.deepEqual(empty.calls, [['lifecycle.close']]);
});
