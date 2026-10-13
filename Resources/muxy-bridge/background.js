// Nunsseop's bridge into Muxy 2. Muxy gives scripts like this one only `tabs.open`, so each request opens a short-lived tab of this
// extension (helper.html), whose page can switch tabs and projects and open a terminal tab, then reports back and closes itself.
//
// Requests come through this extension's storage (Muxy reads `extension-storage/nunsseop-bridge.json` from disk on every call):
//   req    written by Nunsseop: { id, at, type: "focus", pane } or
//                               { id, at, type: "resume", folder, project?, command }   (`at`: epoch ms)
//   ack    written here:        { id, ok, error? }
//   alive  written here every few seconds: epoch ms, so Nunsseop knows this script runs.
// This script is the only writer of `ack` and `alive`, and a request is acted on once per id.
(() => {
  const POLL_MS = 500;
  const BEAT_MS = 5000;
  // A request older than this is not acted on: it was left from before this script started.
  const FRESH_MS = 30000;
  const PANE = /^[0-9a-f]{32}$/;
  // The only command a request may have a terminal tab run: Nunsseop's fixed launcher, so that Muxy's "Allow & Remember" covers it.
  const COMMAND = /^sh '\/[^'\\\n\r]*\/Nunsseop\/muxy-resume\.sh'$/;

  // The ids acted on (a request is acted on once), oldest first, and those whose helper has not reported yet. A request that arrives
  // while another one waits (the user answering Muxy's prompt) must not make this script forget the first.
  const SEEN_MAX = 64;
  const seen = [];
  const pending = new Set();
  let answer = null;

  const attempt = (what, call) => {
    try { return call(); } catch (error) { console.error(what + ': ' + (error && error.message ? error.message : error)); return undefined; }
  };

  const beat = () => attempt('heartbeat', () => muxy.storage.set('alive', Date.now()));

  const acknowledge = (id, ok, error) => {
    answer = ok ? { id, ok: true } : { id, ok: false, error: String(error) };
    attempt('ack', () => muxy.storage.set('ack', answer));
  };

  // Why a request can't be acted on, or null.
  const refusal = (req) => {
    if (req.type === 'focus') return PANE.test(String(req.pane)) ? null : 'invalid pane';
    if (req.type === 'resume') {
      if (typeof req.folder !== 'string' || req.folder.charAt(0) !== '/') return 'invalid folder';
      if (req.project != null && !PANE.test(String(req.project))) return 'invalid project';
      return COMMAND.test(String(req.command)) ? null : 'invalid command';
    }
    return 'unknown request';
  };

  const poll = () => {
    const req = attempt('read', () => muxy.storage.get('req'));
    if (!req || typeof req !== 'object' || typeof req.id !== 'string' || req.id === '') return;
    if (seen.includes(req.id)) {
      // Nunsseop's write of the request can take an ack out of the file, as Muxy's writes can take the request: write it again.
      if (answer && answer.id === req.id) {
        const stored = attempt('read', () => muxy.storage.get('ack'));
        if (!stored || stored.id !== answer.id) attempt('ack', () => muxy.storage.set('ack', answer));
      }
      return;
    }
    seen.push(req.id);
    if (seen.length > SEEN_MAX) seen.shift();
    if (typeof req.at !== 'number' || Date.now() - req.at > FRESH_MS) return;
    const why = refusal(req);
    if (why) return acknowledge(req.id, false, why);
    try {
      pending.add(req.id);
      muxy.tabs.open({ kind: 'extensionWebView', extension: { id: muxy.extensionID, tabType: 'helper', data: req } });
    } catch (error) {
      pending.delete(req.id);
      acknowledge(req.id, false, error && error.message ? error.message : error);
    }
  };

  // The helper page reports with an extension event; a result for a request whose helper this script did not open is ignored.
  muxy.events.subscribe('extension.result', (result) => {
    if (result && typeof result.id === 'string' && pending.delete(result.id)) acknowledge(result.id, result.ok === true, result.error || 'failed');
  });

  // A request that was acknowledged before this script started (it was restarted or reloaded) is not acted on again.
  const before = attempt('read', () => muxy.storage.get('ack'));
  if (before && typeof before.id === 'string') seen.push(before.id);

  beat();
  setInterval(beat, BEAT_MS);
  setInterval(poll, POLL_MS);
  poll();
})();
