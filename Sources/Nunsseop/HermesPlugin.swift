import Foundation

/// The plugin Nunsseop puts in `~/.hermes/plugins/nunsseop/` (a `plugin.yaml` and an `__init__.py`, the least a Hermes plugin is:
/// https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins). It reports the terminal session to `POST /agent` as Claude
/// Code's hook does, with the same headers and event names, and shows a finished turn as a notice (`POST /notify`). Hermes has no
/// approval Nunsseop could answer: `pre_approval_request` and `on_human_input_request` only say that the session waits.
///
/// - `on_session_start` is `SessionStart`; `pre_llm_call` (a turn begins) `UserPromptSubmit`; `post_llm_call` (its final reply) `Stop`;
/// - `on_session_end` fires at the end of every turn, whatever its outcome (it is no end of the session), so one that ended without a
///   final reply (cut short) is an `Interrupt`; `on_session_finalize` is the end of the session, `SessionEnd`;
/// - `pre_approval_request` and `on_human_input_request` are a `Notification` of type `permission_prompt`; `post_approval_response` and
///   the next tool that ran are `elicitation_complete`.
///
/// Only the sessions of a terminal are reported (`platform` is `cli`, `tui` or `desktop`): the gateway's chat and cron sessions are
/// nobody's to open from the notch. The hooks run on Hermes' own thread, so each event goes to a thread of the plugin's, one at a time and
/// in order, with a second to be delivered; every failure is swallowed, and a hook returns nothing, so what Hermes does is never changed.
/// The token is read from the `notify-auth` file when an event is sent, never kept in the plugin.
///
/// Hermes loads a plugin only once it is enabled (`hermes plugins enable nunsseop`, or `plugins.enabled` in `config.yaml`), which
/// Nunsseop doesn't do for the user: it shows the command (see `isEnabled`).
enum HermesPlugin {
    static let marker = "# Added by Nunsseop"
    static let name = "nunsseop"
    /// What Settings gives the user to run once, in a terminal.
    static let enableCommand = "hermes plugins enable \(name)"

    static var folder: URL { NotifyIntegration.home.appendingPathComponent(".hermes/plugins/\(name)", isDirectory: true) }
    static var manifestURL: URL { folder.appendingPathComponent("plugin.yaml") }

    static let manifest = """
    # Added by Nunsseop: shows this Hermes session in the notch. Delete this folder to stop.
    name: \(name)
    version: "1.0"
    description: Shows Hermes sessions in the Nunsseop notch

    """

    static func isOurs(_ url: URL) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8))?.hasPrefix(marker) == true
    }

    // MARK: Enabled

    /// Whether `config.yaml` lists the plugin under `plugins.enabled`; nil when Settings can't tell (the shape of the file isn't one that
    /// is understood). Nothing else of the file is looked at, kept or shown.
    static func isEnabled(config text: String) -> Bool? {
        enabledPlugins(in: text).map { $0.contains(name) }
    }

    /// The same, read from `~/.hermes/config.yaml`; nil without one.
    static func isEnabled() -> Bool? {
        let url = NotifyIntegration.home.appendingPathComponent(".hermes/config.yaml")
        guard let data = try? Data(contentsOf: url), data.count <= 4 << 20, let text = String(data: data, encoding: .utf8) else { return nil }
        return isEnabled(config: text)
    }

    /// The names under `plugins:` `enabled:`, as a block list (`- name`) or a list on one line (`[a, b]`); empty when there is no such
    /// key; nil for any other form (`plugins: {…}`, a scalar).
    static func enabledPlugins(in text: String) -> [String]? {
        struct Line { let indent: Int; let content: String }
        let lines: [Line] = text.components(separatedBy: .newlines).compactMap { raw in
            let indent = raw.prefix { $0 == " " }.count
            var content = String(raw.dropFirst(indent))
            if content.hasPrefix("#") { return nil }
            if let comment = content.range(of: " #") { content = String(content[..<comment.lowerBound]) }
            content = content.trimmingCharacters(in: .whitespaces)
            return content.isEmpty ? nil : Line(indent: indent, content: content)
        }
        guard let start = lines.firstIndex(where: { $0.indent == 0 && $0.content.hasPrefix("plugins:") }) else { return [] }
        guard lines[start].content == "plugins:" else { return nil }
        let block = lines[(start + 1)...].prefix { $0.indent > 0 }
        guard let first = block.first, let key = block.firstIndex(where: { $0.indent == first.indent && $0.content.hasPrefix("enabled:") }) else { return [] }
        let value = block[key].content.dropFirst("enabled:".count).trimmingCharacters(in: .whitespaces)
        func name(_ text: String) -> String { text.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
        if value.hasPrefix("[") {
            guard value.hasSuffix("]") else { return nil }
            return value.dropFirst().dropLast().split(separator: ",").map { name(String($0)) }.filter { !$0.isEmpty }
        }
        if ["null", "~"].contains(value) { return [] }
        guard value.isEmpty else { return nil }
        // A block list may stand level with its key.
        return block[(key + 1)...].prefix { $0.indent >= block[key].indent && $0.content.hasPrefix("-") }
            .map { name(String($0.content.dropFirst())) }.filter { !$0.isEmpty }
    }

    // MARK: Source

    static func source(port: UInt16 = NotifyServer.port) -> String {
        #"""
        # Added by Nunsseop: reports this Hermes session to the notch for the agents count. Delete this folder to stop.
        import json
        import os
        import queue
        import re
        import threading
        import urllib.request

        PORT = \#(port)
        AUTH = os.path.expanduser("~/Library/Application Support/Nunsseop/notify-auth")
        # The sessions of a terminal. The gateway's (chat apps, cron jobs) are nobody's to open from the notch.
        LOCAL = ("cli", "tui", "desktop")
        _UNSAFE = re.compile(r"[^A-Za-z0-9_.:%-]")
        _UNSAFE_PATH = re.compile(r"[^A-Za-z0-9_.:%+=,@/-]")

        _state = {"session": "", "working": False, "asking": False}
        _lock = threading.Lock()
        _outbox = queue.Queue(maxsize=64)
        _worker = []


        def _clean(value):
            return _UNSAFE.sub("", str(value or ""))


        def _clean_path(value):
            return _UNSAFE_PATH.sub("", str(value or ""))


        def _terminal():
            env = os.environ
            return {
                "X-App": _clean(env.get("__CFBundleIdentifier")),
                "X-Herdr": "1" if env.get("HERDR_PANE_ID") else "",
                "X-Muxy": _clean(env.get("MUXY_SESSION_ID")),
                "X-Cmux": _clean(env.get("CMUX_SURFACE_ID")),
                "X-Mux": "1" if (env.get("TMUX") or env.get("ZELLIJ") or env.get("STY")) else "",
                "X-Wezterm": _clean(env.get("WEZTERM_PANE")),
                "X-Wezterm-Socket": _clean_path(env.get("WEZTERM_UNIX_SOCKET")),
                "X-Kitty": _clean(env.get("KITTY_WINDOW_ID")),
                "X-Kitty-Socket": _clean_path(env.get("KITTY_LISTEN_ON")),
                "X-Iterm": _clean(env.get("ITERM_SESSION_ID")),
                "X-Orca": _clean(env.get("ORCA_PANE_KEY")),
            }


        def _post(path, headers, body=b""):
            with open(AUTH, encoding="utf-8") as handle:
                line = handle.readline().strip()
            name, _, value = line.partition(":")
            if not name.strip():
                return
            request = urllib.request.Request("http://127.0.0.1:%d%s" % (PORT, path), data=body, method="POST")
            request.add_header(name.strip(), value.strip())
            for key, text in headers.items():
                request.add_header(key, text)
            # Straight to the loopback address, whatever proxy the environment names.
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            opener.open(request, timeout=1).close()


        def _run():
            while True:
                item = _outbox.get()
                try:
                    _post(*item)
                except Exception:
                    pass


        def _enqueue(*item):
            try:
                if not _worker:
                    thread = threading.Thread(target=_run, name="nunsseop", daemon=True)
                    _worker.append(thread)
                    thread.start()
                _outbox.put_nowait(item)
            except Exception:
                pass


        def _send(event, type_=""):
            session = _state["session"]
            if not session:
                return
            headers = _terminal()
            headers.update({"X-Agent": "hermes", "X-Session": _clean(session), "X-Event": event, "X-Type": type_,
                            "X-Pid": str(os.getpid())})
            _enqueue("/agent", headers)


        def _notice(message):
            body = json.dumps({"title": "Hermes", "message": message, "app": _clean(os.environ.get("__CFBundleIdentifier"))}).encode("utf-8")
            _enqueue("/notify", {"Content-Type": "application/json"}, body)


        def _track(session_id, platform):
            # True for a session of a terminal; remembers which one it is.
            if platform not in LOCAL or not session_id:
                return False
            if _state["session"] != session_id:
                _state.update(session=session_id, working=False, asking=False)
            return True


        def _safe(hook):
            def run(*args, **kwargs):
                try:
                    with _lock:
                        hook(*args, **kwargs)
                except Exception:
                    pass
                # A hook adds nothing to the turn: pre_llm_call would put what it returned into the prompt.
                return None
            run.__name__ = hook.__name__
            return run


        def _ask():
            if _state["session"] and not _state["asking"]:
                _state["asking"] = True
                _send("Notification", "permission_prompt")


        def _resume():
            if _state["asking"]:
                _state["asking"] = False
                _send("Notification", "elicitation_complete")


        def on_session_start(session_id=None, platform=None, **kwargs):
            if _track(session_id, platform):
                _send("SessionStart")


        def pre_llm_call(session_id=None, platform=None, **kwargs):
            if _track(session_id, platform):
                _state.update(working=True, asking=False)
                _send("UserPromptSubmit")


        def post_llm_call(session_id=None, platform=None, **kwargs):
            if _track(session_id, platform):
                _state.update(working=False, asking=False)
                _send("Stop")
                _notice("Finished")


        def on_session_end(session_id=None, **kwargs):
            # The end of a turn, whatever came of it: one with no final reply was cut short.
            if session_id == _state["session"] and _state["working"]:
                _state.update(working=False, asking=False)
                _send("Interrupt")


        def on_session_finalize(session_id=None, **kwargs):
            if session_id and session_id == _state["session"]:
                _send("SessionEnd")
                _state.update(session="", working=False, asking=False)


        def pre_approval_request(**kwargs):
            _ask()


        def on_human_input_request(session_id=None, platform=None, **kwargs):
            if session_id == _state["session"] or _track(session_id, platform):
                _ask()


        def post_approval_response(**kwargs):
            _resume()


        def post_tool_call(*args, **kwargs):
            _resume()


        HOOKS = (on_session_start, pre_llm_call, post_llm_call, on_session_end, on_session_finalize, pre_approval_request,
                 on_human_input_request, post_approval_response, post_tool_call)


        def register(ctx):
            for hook in HOOKS:
                try:
                    ctx.register_hook(hook.__name__, _safe(hook))
                except Exception:
                    pass

        """#
    }
}
