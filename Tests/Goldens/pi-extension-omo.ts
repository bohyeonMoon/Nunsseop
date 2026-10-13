// Added by Nunsseop: reports this session to the notch for the agents count. Delete this file to stop.
// @ts-nocheck
import http from "node:http"
import { readFileSync } from "node:fs"
import { homedir } from "node:os"

const AGENT = "omo"
const PORT = 47750
// Whether the tool says when a turn has settled (agent_settled); omp doesn't.
const SETTLES = true
const AUTH = `${homedir()}/Library/Application Support/Nunsseop/notify-auth`

const clean = (value) => String(value ?? "").replace(/[^A-Za-z0-9_.:%-]/g, "")
const cleanPath = (value) => String(value ?? "").replace(/[^A-Za-z0-9_.:%+=,@\/-]/g, "")

// One request at a time, in the order the events came: a Stop that overtook the UserPromptSubmit before it would leave the
// session working. Each is given up on after a second.
let chain = Promise.resolve()
const post = (event, session, type) => {
  chain = chain.then(() => send(event, session, type))
}

function send(event, session, type) {
  return new Promise((resolve) => {
    try {
      const line = readFileSync(AUTH, "utf8").split("\n")[0]
      const colon = line.indexOf(":")
      if (colon < 1) return resolve()
      const env = process.env
      const request = http.request({
        host: "127.0.0.1",
        port: PORT,
        path: "/agent",
        method: "POST",
        timeout: 1000,
        headers: {
          [line.slice(0, colon).trim()]: line.slice(colon + 1).trim(),
          "Content-Length": "0",
          "X-Agent": AGENT,
          "X-Session": clean(session),
          "X-Event": event,
          "X-Type": type ?? "",
          "X-App": clean(env.__CFBundleIdentifier),
          "X-Herdr": env.HERDR_PANE_ID ? "1" : "",
          "X-Muxy": clean(env.MUXY_SESSION_ID),
          "X-Cmux": clean(env.CMUX_SURFACE_ID),
          "X-Mux": env.TMUX || env.ZELLIJ || env.STY ? "1" : "",
          "X-Wezterm": clean(env.WEZTERM_PANE),
          "X-Wezterm-Socket": cleanPath(env.WEZTERM_UNIX_SOCKET),
          "X-Kitty": clean(env.KITTY_WINDOW_ID),
          "X-Kitty-Socket": cleanPath(env.KITTY_LISTEN_ON),
          "X-Iterm": clean(env.ITERM_SESSION_ID),
          "X-Pid": String(process.pid),
        },
      })
      request.on("close", resolve)
      request.on("error", () => {})
      request.on("timeout", () => request.destroy())
      request.on("response", (response) => response.resume())
      request.end()
    } catch {
      resolve()
    }
  })
}

export default function (pi) {
  let session = ""
  let working = false
  let settle
  const blocked = new Set()

  const send = (event, type) => { if (session) post(event, session, type) }

  // The tool's main session in the terminal; remembers its id.
  const adopt = (ctx) => {
    const terminal = ctx?.mode ? ctx.mode === "tui" : ctx?.hasUI === true
    if (!terminal || (ctx.agent?.kind ?? "main") !== "main") return false
    try {
      session = ctx.sessionManager.getSessionId() || session
    } catch {}
    return session !== ""
  }

  const finish = () => {
    clearTimeout(settle)
    if (!working) return
    working = false
    send("Stop")
  }

  const block = (id) => {
    blocked.add(id)
    if (blocked.size === 1) send("Notification", "permission_prompt")
  }
  const unblock = (id) => {
    if (blocked.delete(id) && blocked.size === 0) send("Notification", working ? "elicitation_complete" : "idle_prompt")
  }

  const on = (name, handler) => {
    try {
      pi.on(name, (...args) => {
        try {
          handler(...args)
        } catch {}
      })
    } catch {}
  }

  const begin = (_event, ctx) => {
    if (!adopt(ctx)) return
    clearTimeout(settle)
    blocked.clear()
    // A reload can replace the extension in the middle of a turn.
    working = ctx.isIdle?.() === false
    send("SessionStart")
    if (working) send("UserPromptSubmit")
  }
  on("session_start", begin)
  on("session_switch", begin)

  on("agent_start", (_event, ctx) => {
    if (!adopt(ctx)) return
    clearTimeout(settle)
    working = true
    send("UserPromptSubmit")
  })
  on("agent_end", (event) => {
    if (!session || !working) return
    clearTimeout(settle)
    // omp marks an end that is only a pause (retry, compaction, a queued follow-up) with isTerminal: false; the next start
    // can be seconds away, so it waits as long as for a settle.
    settle = setTimeout(finish, SETTLES || event?.isTerminal === false ? 30000 : 1000)
    settle.unref?.()
  })
  on("agent_settled", (_event, ctx) => {
    if (session && ctx?.isIdle?.() !== false) finish()
  })

  // pi and omo say "herdr:blocked" when a dialog opens and closes; omp has approvals and its ask tool.
  try {
    pi.events?.on?.("herdr:blocked", (data) => {
      if (session) data?.active ? block(data.id ?? "dialog") : unblock(data?.id ?? "dialog")
    })
  } catch {}
  on("tool_approval_requested", (event) => block(event?.toolCallId ?? "approval"))
  on("tool_approval_resolved", (event) => unblock(event?.toolCallId ?? "approval"))
  on("tool_execution_start", (event) => { if (event?.toolName === "ask") block(event.toolCallId ?? "ask") })
  on("tool_execution_end", (event) => { if (event?.toolName === "ask") unblock(event.toolCallId ?? "ask") })

  on("session_shutdown", (event) => {
    if (!session || event?.reason === "reload") return
    clearTimeout(settle)
    send("SessionEnd")
  })
}
