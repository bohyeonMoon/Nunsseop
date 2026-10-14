// The short-lived tab background.js opens for one Nunsseop request (its `muxy.data`). It does what only a page can: selects a tab,
// switches project, opens a terminal tab. Then it reports to background.js, which writes the answer, and closes itself.
(() => {
  const FRESH_MS = 30000;
  const PANE = /^[0-9a-f]{32}$/;
  // The same rule as background.js: only Nunsseop's fixed launcher may be run.
  const COMMAND = /^sh '\/[^'\\\n\r]*\/Nunsseop\/muxy-resume\.sh'$/;

  const report = (id, error) =>
    muxy.events.emit('extension.result', error === undefined ? { id, ok: true } : { id, ok: false, error: String(error) }).catch(() => {});

  const act = async (req) => {
    if (req.type === 'focus') {
      if (!PANE.test(String(req.pane))) throw new Error('invalid pane');
      // A pane id selects the tab that holds it, in whichever project that is.
      await muxy.tabs.switchTo(req.pane);
    } else if (req.type === 'resume') {
      if (!COMMAND.test(String(req.command))) throw new Error('invalid command');
      if (req.project != null) {
        if (!PANE.test(String(req.project))) throw new Error('invalid project');
        await muxy.projects.switchTo(req.project);
      }
      // Muxy asks once per exact command, and remembers the answer when the user allows it for good.
      await muxy.tabs.open({ kind: 'terminal', command: req.command });
    } else {
      throw new Error('unknown request');
    }
  };

  const run = async () => {
    const req = muxy.data;
    // A tab Muxy restored after a restart holds an old request: it is not acted on.
    if (req && typeof req.id === 'string' && typeof req.at === 'number' && Date.now() - req.at <= FRESH_MS) {
      try {
        await act(req);
        await report(req.id);
      } catch (error) {
        await report(req.id, error && error.message ? error.message : error);
      }
    }
    await muxy.lifecycle.close();
  };

  run().catch(() => {});
})();
