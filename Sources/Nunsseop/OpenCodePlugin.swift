import Foundation

/// The plugin Nunsseop puts in OpenCode's plugins folder. It does three things, each failing silently so OpenCode never waits on
/// Nunsseop:
///
/// - shows a finished session as a notice (`/notify`);
/// - reports sessions to the agents count (`/agent`) with the headers and event names of Claude Code's hook: a session going
///   busy is `UserPromptSubmit`, idle `Stop`, one asking for a permission or an answer a `Notification` of type
///   `permission_prompt`, a created or deleted one `SessionStart` or `SessionEnd`. Subagents' sessions (they have a `parentID`) are
///   left out;
/// - lets a permission prompt be answered in the notch (`/permission`), proven with the permission key as the shell hook of
///   Claude Code does (see `NotifyServer.permissionHookCommand` and `PermissionWire`). A permission arrives in OpenCode 1.15 as the
///   `permission.asked` event (`id`, `sessionID`, `permission`, `patterns`, `metadata`), which the plugin answers through the client
///   (`permission.reply`, or the older `postSessionIdPermissionsPermissionId`); the `permission.ask` hook of the plugin API (`id`,
///   `type`, `pattern`, `title`, `metadata`) is no longer called by 1.15.6, but is answered too where it is. An answer other than
///   allow or deny, and every failure, leaves OpenCode's own prompt in charge.
enum OpenCodePlugin {
    static func source(port: UInt16 = NotifyServer.port) -> String {
        #"""
        // Added by Nunsseop: shows OpenCode's sessions in the notch and lets you answer its permission prompts there. Delete this file to stop.
        import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto"
        import { readFileSync } from "node:fs"
        import { homedir } from "node:os"

        const PORT = \#(port)
        const FOLDER = `${homedir()}/Library/Application Support/Nunsseop`
        const MAX_BODY = \#(PermissionGate.maxBodyBytes)
        const read = (name) => readFileSync(`${FOLDER}/${name}`, "utf8")
        const clean = (value) => String(value ?? "").replace(/[^A-Za-z0-9_.:%-]/g, "")
        const cleanPath = (value) => String(value ?? "").replace(/[^A-Za-z0-9_.:%+=,@\/-]/g, "")

        async function notify() {
          try {
            const token = read("notify-token").trim()
            await fetch(`http://127.0.0.1:${PORT}/notify`, {
              method: "POST",
              headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
              body: JSON.stringify({ title: "OpenCode", message: "Finished", app: process.env.__CFBundleIdentifier }),
              signal: AbortSignal.timeout(2000),
            })
          } catch {}
        }

        // One report at a time, in the order the events came: a Stop that overtook the UserPromptSubmit before it would leave the
        // session working.
        let chain = Promise.resolve()
        const report = (event, session, type) => {
          chain = chain.then(() => send(event, session, type))
        }

        async function send(event, session, type) {
          try {
            const token = read("notify-token").trim()
            const env = process.env
            await fetch(`http://127.0.0.1:${PORT}/agent`, {
              method: "POST",
              headers: {
                Authorization: `Bearer ${token}`,
                "X-Agent": "opencode",
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
              signal: AbortSignal.timeout(1000),
            })
          } catch {}
        }

        // The message and the answer are each proven by an HMAC-SHA256 under the permission key, over a domain, the nonce and the
        // SHA-256 of what is vouched for. The key never leaves this file's reads.
        const digest = (text) => createHash("sha256").update(text).digest("hex")
        const prove = (key, domain, nonce, text) => createHmac("sha256", key).update(`${domain}\n${nonce}\n${digest(text)}`).digest("hex")

        const asked = new Set()
        const waiting = new Map()

        // "allow" or "deny" from the notch; nothing when it was left to the terminal or anything went wrong.
        async function decide(request, directory) {
          const id = request.id
          try {
            const key = read("permission-key").replace(/[ \t\r\n]/g, "")
            if (key.length < 32) return
            const body = JSON.stringify({
              hook_event_name: "PermissionRequest",
              agent: "opencode",
              session_id: request.sessionID,
              cwd: directory,
              tool_name: request.permission ?? request.type,
              tool_input: { patterns: [].concat(request.patterns ?? request.pattern ?? []), title: request.title, metadata: request.metadata ?? {} },
            })
            if (Buffer.byteLength(body) > MAX_BODY) return
            const nonce = randomBytes(16).toString("hex")
            const controller = new AbortController()
            waiting.set(id, controller)
            const timer = setTimeout(() => controller.abort(), 590000)
            let response
            try {
              response = await fetch(`http://127.0.0.1:${PORT}/permission`, {
                method: "POST",
                headers: { "X-Nonce": nonce, "X-Proof": prove(key, "nunsseop-permission-request", nonce, body) },
                body,
                signal: controller.signal,
              })
              if (response.status !== 200) return
              response = await response.text()
            } finally {
              clearTimeout(timer)
            }
            const space = response.indexOf(" ")
            if (space < 1) return
            const answer = response.slice(space + 1)
            const proof = Buffer.from(response.slice(0, space))
            const expected = Buffer.from(prove(key, "nunsseop-permission-response", nonce, answer))
            if (proof.length !== expected.length || !timingSafeEqual(proof, expected)) return
            const behavior = JSON.parse(answer).behavior
            return behavior === "allow" || behavior === "deny" ? behavior : undefined
          } catch {
          } finally {
            waiting.delete(id)
          }
        }

        async function reply(client, request, decision) {
          const once = decision === "allow"
          try {
            if (client?.permission?.reply) {
              await client.permission.reply({ requestID: request.id, reply: once ? "once" : "reject", ...(once ? {} : { message: "Denied in Nunsseop" }) })
            } else {
              await client.postSessionIdPermissionsPermissionId({
                path: { id: request.sessionID, permissionID: request.id },
                body: { response: once ? "once" : "reject" },
              })
            }
          } catch {}
        }

        export const NunsseopPlugin = async ({ client, directory }) => {
          // Whether a session is a main one (false for a subagent's), and the last state sent for it.
          const mains = new Map()
          const last = new Map()

          const state = (session, next, event, type) => {
            if (!session || mains.get(session) === false || last.get(session) === next) return
            last.set(session, next)
            report(event, session, type)
          }
          const busy = (session) => state(session, "busy", "UserPromptSubmit")
          const idle = (session) => state(session, "idle", "Stop")
          const needsAnswer = (session) => state(session, "asking", "Notification", "permission_prompt")
          const answered = (session) => state(session, "busy", "Notification", "elicitation_complete")

          const permission = async (request) => {
            if (asked.has(request.id)) return
            asked.add(request.id)
            needsAnswer(request.sessionID)
            const decision = await decide(request, directory)
            if (decision) await reply(client, request, decision)
          }

          return {
            event: async ({ event }) => {
              const properties = event.properties ?? {}
              const session = properties.sessionID ?? properties.info?.id
              switch (event.type) {
                case "session.created":
                case "session.updated":
                  if (properties.info?.id) mains.set(properties.info.id, !properties.info.parentID)
                  if (event.type === "session.created" && !properties.info?.parentID) report("SessionStart", properties.info.id)
                  break
                case "session.status":
                  if (properties.status?.type === "idle") idle(session)
                  else busy(session)
                  break
                case "session.idle":
                  idle(session)
                  await notify()
                  break
                case "session.error":
                  idle(session)
                  break
                case "session.deleted":
                  mains.delete(session)
                  last.delete(session)
                  report("SessionEnd", session)
                  break
                case "permission.asked":
                case "permission.updated":
                  void permission(properties)
                  break
                case "permission.replied":
                  waiting.get(properties.requestID ?? properties.permissionID)?.abort()
                  answered(session)
                  break
                case "question.asked":
                  needsAnswer(session)
                  break
                case "question.replied":
                case "question.rejected":
                  answered(session)
                  break
              }
            },
            "permission.ask": async (input, output) => {
              if (asked.has(input.id)) return
              asked.add(input.id)
              const decision = await decide(input, directory)
              if (decision) output.status = decision
            },
          }
        }

        """#
    }
}
