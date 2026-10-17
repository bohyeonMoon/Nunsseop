// Added by Nunsseop: reports this Amp session to the notch for the agents count. Delete this file to stop.
// @ts-nocheck
import { readFileSync } from "node:fs"
import { homedir } from "node:os"

export const description = "Shows Amp threads in the Nunsseop notch"

const PORT = 47750
const AUTH = `${homedir()}/Library/Application Support/Nunsseop/notify-auth`

const clean = (value) => String(value ?? "").replace(/[^A-Za-z0-9_.:%-]/g, "")
const cleanPath = (value) => String(value ?? "").replace(/[^A-Za-z0-9_.:%+=,@\/-]/g, "")

// One request at a time, in the order the events came: a Stop that overtook the UserPromptSubmit before it would leave the
// session working. Each is given up on after a second.
let chain = Promise.resolve()
const enqueue = (path, headers, body) => {
  chain = chain.then(() => post(path, headers, body))
}

async function post(path, headers, body) {
  try {
    const line = readFileSync(AUTH, "utf8").split("\n")[0]
    const colon = line.indexOf(":")
    if (colon < 1) return
    await fetch(`http://127.0.0.1:${PORT}${path}`, {
      method: "POST",
      headers: { [line.slice(0, colon).trim()]: line.slice(colon + 1).trim(), ...headers },
      body,
      signal: AbortSignal.timeout(1000),
    })
  } catch {}
}

const app = () => clean(process.env.__CFBundleIdentifier)

function report(event, thread, type) {
  const id = thread?.id
  if (!id) return
  const env = process.env
  enqueue("/agent", {
    "X-Agent": "amp",
    "X-Session": clean(id),
    "X-Event": event,
    "X-Type": type ?? "",
    "X-App": app(),
    "X-Herdr": env.HERDR_PANE_ID ? "1" : "",
    "X-Muxy": clean(env.MUXY_SESSION_ID),
    "X-Cmux": clean(env.CMUX_SURFACE_ID),
    "X-Mux": env.TMUX || env.ZELLIJ || env.STY ? "1" : "",
    "X-Wezterm": clean(env.WEZTERM_PANE),
    "X-Wezterm-Socket": cleanPath(env.WEZTERM_UNIX_SOCKET),
    "X-Kitty": clean(env.KITTY_WINDOW_ID),
    "X-Kitty-Socket": cleanPath(env.KITTY_LISTEN_ON),
    "X-Iterm": clean(env.ITERM_SESSION_ID),
    "X-Orca": clean(env.ORCA_PANE_KEY),
  })
}

const notice = (message) =>
  enqueue("/notify", { "Content-Type": "application/json" }, JSON.stringify({ title: "Amp", message, app: app() }))

export default function (amp) {
  const known = new Set()
  const on = (name, handler) => {
    try {
      amp.on(name, (event) => {
        try {
          if (event?.thread?.id) known.add(event.thread.id)
          handler(event)
        } catch {}
      })
    } catch {}
  }

  on("session.start", (event) => report("SessionStart", event.thread))
  on("agent.start", (event) => report("UserPromptSubmit", event.thread))
  on("agent.end", (event) => {
    if (event.status === "done") {
      report("Stop", event.thread)
      notice("Finished")
    } else {
      report(event.status === "cancelled" ? "Interrupt" : "StopFailure", event.thread)
    }
  })

  try {
    amp.onDispose(async () => {
      for (const id of known) report("SessionEnd", { id })
      await chain
    })
  } catch {}
}
