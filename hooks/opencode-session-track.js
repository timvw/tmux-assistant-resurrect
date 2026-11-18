// OpenCode plugin — tracks the session this OpenCode process is working in.
//
// The save hook reads this file before -s/--session in argv, so it must name
// the session the user is actually using, not merely the last one any event
// mentioned. A server plugin cannot see which session the TUI shows, and
// `session.updated` fires for *every* session that changes -- renaming another
// session in the picker looks exactly like activity. So only these events
// decide which session is recorded:
//   - session.created for a top-level session (this process just made it)
//   - a user message (message.updated, role "user") in a top-level session:
//     someone prompted it, which is what using a session looks like
//   - tui.session.select (an explicit selection through the TUI API)
// session.updated only refreshes the metadata of the session already on
// record (or drops it once archived). Subagent sessions are never recorded:
// the task tool prompts them with "user" messages of its own.
//
// Captures session metadata (model, title, etc.) and configurable environment
// variables for richer save/restore context. Cleans up on process exit.
//
// Install: symlink into ~/.config/opencode/plugins/ (global) or .opencode/plugins/ (project).

import {
  writeFileSync,
  readFileSync,
  mkdirSync,
  renameSync,
  unlinkSync,
  existsSync,
} from "fs";
import { execFileSync } from "child_process";
import { randomUUID } from "crypto";
import { homedir } from "os";

export const SessionTracker = async ({ client, directory }) => {
  // Must resolve to exactly what assistant_state_dir() in scripts/lib-detect.sh
  // produces: this plugin runs inside opencode, the save hook runs as a child of
  // the tmux server, and the two never share an environment. Anything the two
  // sides can disagree about silently loses the session ID (issue #65) — which is
  // why this is $HOME and not XDG_RUNTIME_DIR/tmpdir(). Prefer process.env.HOME
  // over homedir() so the two implementations agree byte for byte; homedir() is
  // only the fallback for the (never, under tmux) case where HOME is unset.
  const stateDir =
    process.env.TMUX_ASSISTANT_RESURRECT_DIR ||
    `${process.env.HOME || homedir()}/.local/state/tmux-assistant-resurrect`;
  // OpenCode loads plugins in-process via `await import()` (no child process),
  // so process.pid is the opencode binary's PID — matching what the save script
  // finds via `ps` tree walk.
  const pid = process.pid;
  const stateFile = `${stateDir}/opencode-${pid}.json`;

  // Mirrors ensure_assistant_state_dir() in scripts/lib-detect.sh — see the long
  // comment there for why. The Node-specific trap: `recursive` applies `mode` to
  // every level it creates, not just the deepest, so the one-liner this replaces
  // would have clamped ~/.local and ~/.local/state to 0700 the moment the path
  // moved under $HOME. Create the parents at the umask default, the leaf private,
  // and leave a directory that already exists exactly as the user set it up.
  if (!existsSync(stateDir)) {
    const trimmed = stateDir.replace(/\/+$/, "");
    const parent = trimmed.replace(/\/[^/]*$/, "");
    // A slashless override ("state") leaves parent === trimmed, and creating that
    // would make the leaf itself at the ambient mode — the private mkdirSync below
    // would then just swallow EEXIST and hand back 0755. Same guard as the shell.
    if (parent && parent !== trimmed) mkdirSync(parent, { recursive: true });
    try {
      mkdirSync(stateDir, { mode: 0o700 });
    } catch (err) {
      // EEXIST: the save hook won the race, and it created the leaf the same way.
      // Anything else (a parent that could not be made): retry recursively but
      // still under 0700, never at the ambient mode, so a missing state file — not
      // a world-readable one, and not a dead plugin — is the worst outcome.
      if (err.code !== "EEXIST") {
        mkdirSync(stateDir, { recursive: true, mode: 0o700 });
      }
    }
  }

  // Read user-configured env vars to capture from the tmux option
  // @assistant-resurrect-capture-env (space-separated list).
  let captureEnvVars = [];
  try {
    const raw = execFileSync(
      "tmux",
      ["show-option", "-gqv", "@assistant-resurrect-capture-env"],
      { encoding: "utf8", timeout: 2000, stdio: ["ignore", "pipe", "ignore"] },
    ).trim();
    if (raw) captureEnvVars = raw.split(/\s+/);
  } catch {
    // Not in tmux or option not set — no extra env vars to capture
  }

  // Capture init-time context (recorded once, included in every state write)
  const initContext = {
    directory: directory || process.cwd(),
    argv: process.argv,
    execPath: process.execPath,
    clientKeys: Object.keys(client || {}),
  };

  // Clean up state file when the process exits
  const cleanup = () => {
    try {
      unlinkSync(stateFile);
    } catch {
      // File may already be gone
    }
  };
  process.on("exit", cleanup);
  // A signal listener suppresses Node's default exit, so clean up first and
  // then restore the default only when the host has no handler of its own. Host
  // handlers still receive the original signal and retain shutdown control.
  for (const signal of ["SIGINT", "SIGTERM"]) {
    const cleanupOnSignal = () => {
      cleanup();
      process.removeListener(signal, cleanupOnSignal);
      if (process.listenerCount(signal) === 0) process.kill(process.pid, signal);
    };
    process.prependListener(signal, cleanupOnSignal);
  }

  // Session metadata seen on this server, by id. Lets a user message (which
  // carries only a sessionID) be checked for a parent and recorded with its
  // title/model, and is kept current by session.created/updated.
  const sessions = new Map();
  const remember = (info) => {
    if (info?.id) sessions.set(info.id, info);
  };
  // A session from before this process started (a restored pane resumed with
  // -s) has not been announced; ask the server once. Best effort: unknown
  // stays unknown, and is then treated as top-level.
  const lookup = async (sessionID) => {
    if (sessions.has(sessionID)) return sessions.get(sessionID);
    try {
      const res = await client?.session?.get?.({ path: { id: sessionID } });
      if (res?.data?.id === sessionID) {
        remember(res.data);
        return res.data;
      }
    } catch {
      // Older client or no server: fall through
    }
    return { id: sessionID };
  };

  const recordedSessionID = () => {
    try {
      return JSON.parse(readFileSync(stateFile, "utf8")).session_id;
    } catch {
      return null; // No file or unreadable
    }
  };

  const writeSessionFile = (sessionInfo, eventType) => {
    const sessionID = sessionInfo?.id;
    if (!sessionID) return;
    // Subagent (child) and archived sessions are not resumable top-level
    // conversations. The DB fallback (scripts/py/opencode_db.py) excludes them
    // too; recording one here would let it win over the DB on the next save
    // and resume the wrong session. A child never touches the file. An
    // archived session is dropped only if it is the one on record: the save
    // script reads the file before the DB, so a stale id would still be
    // restored. Removing it hands the next save to the DB fallback.
    if (sessionInfo.parentID) return;
    if (sessionInfo.time?.archived) {
      if (recordedSessionID() === sessionID) cleanup();
      return;
    }

    // Build env object: always capture TMUX_PANE and SHELL, plus user-configured vars
    const env = {
      tmux_pane: process.env.TMUX_PANE || "",
      shell: process.env.SHELL || "",
    };
    for (const varName of captureEnvVars) {
      env[varName] = process.env[varName] || "";
    }

    const data = JSON.stringify(
      {
        tool: "opencode",
        session_id: sessionID,
        pid: pid,
        cwd: directory || process.cwd(),
        timestamp: new Date().toISOString(),
        session: sessionInfo,
        event_type: eventType,
        init: initContext,
        env: env,
      },
      null,
      2,
    );
    // Write beside the destination and atomically rename it into place. The
    // save hook can read this file concurrently, and must never observe a
    // truncated JSON document. Explicit 0600 protects captured environment
    // values even when the user supplied a shared state directory.
    const tempFile = `${stateFile}.${randomUUID()}.tmp`;
    try {
      writeFileSync(tempFile, data, { encoding: "utf8", mode: 0o600, flag: "wx" });
      renameSync(tempFile, stateFile);
    } catch {
      // Best-effort — don't crash OpenCode if state dir is unavailable
      try {
        unlinkSync(tempFile);
      } catch {
        // The write may have failed before the temporary file was created
      }
    }
  };

  return {
    event: async ({ event }) => {
      const props = event.properties || {};
      switch (event.type) {
        case "session.created":
          remember(props.info);
          writeSessionFile(props.info, event.type);
          break;
        case "session.updated":
          remember(props.info);
          // Only the session on record: an update to any other session (a
          // rename in the picker, say) says nothing about where the user is.
          if (props.info?.id && props.info.id === recordedSessionID()) {
            writeSessionFile(props.info, event.type);
          }
          break;
        case "session.deleted":
          if (props.info?.id) sessions.delete(props.info.id);
          if (props.info?.id && props.info.id === recordedSessionID()) cleanup();
          break;
        case "message.updated":
          if (props.info?.role === "user" && props.info.sessionID) {
            writeSessionFile(await lookup(props.info.sessionID), event.type);
          }
          break;
        case "tui.session.select":
          if (props.sessionID) {
            writeSessionFile(await lookup(props.sessionID), event.type);
          }
          break;
      }
    },
  };
};
