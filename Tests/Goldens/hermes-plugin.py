# Added by Nunsseop: reports this Hermes session to the notch for the agents count. Delete this folder to stop.
import json
import os
import queue
import re
import threading
import urllib.request

PORT = 47750
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
