// OpenCode plugin — tracks active session context to a file on disk.
// Fires on session.created, session.updated, and session.idle events.
// Captures full session metadata (model, title, etc.) and configurable
// environment variables for richer save/restore context.
// Cleans up state file on process exit.
//
// Install: symlink into ~/.config/opencode/plugins/ (global) or .opencode/plugins/ (project).

import { writeFileSync, mkdirSync, unlinkSync } from "fs";
import { execSync } from "child_process";
import { tmpdir } from "os";

export const SessionTracker = async ({ client, directory }) => {
  const stateDir =
    process.env.TMUX_ASSISTANT_RESURRECT_DIR ||
    `${process.env.XDG_RUNTIME_DIR || tmpdir()}/tmux-assistant-resurrect`;
  // OpenCode loads plugins in-process via `await import()` (no child process),
  // so process.pid is the opencode binary's PID — matching what the save script
  // finds via `ps` tree walk.
  const pid = process.pid;
  const stateFile = `${stateDir}/opencode-${pid}.json`;

  mkdirSync(stateDir, { recursive: true, mode: 0o700 });

  // Read user-configured env vars to capture from the tmux option
  // @assistant-resurrect-capture-env (space-separated list).
  let captureEnvVars = [];
  try {
    const raw = execSync(
      "tmux show-option -gqv @assistant-resurrect-capture-env 2>/dev/null",
      { encoding: "utf8", timeout: 2000 },
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
  process.on("SIGINT", () => {
    cleanup();
    process.exit(0);
  });
  process.on("SIGTERM", () => {
    cleanup();
    process.exit(0);
  });

  const writeSessionFile = (event) => {
    const sessionInfo = event.properties?.info || {};
    const sessionID = sessionInfo.id || event.properties?.id;
    if (!sessionID) return;

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
        event_type: event.type,
        init: initContext,
        env: env,
      },
      null,
      2,
    );
    try {
      writeFileSync(stateFile, data);
    } catch {
      // Best-effort — don't crash OpenCode if state dir is unavailable
    }
  };

  return {
    event: async ({ event }) => {
      const sessionEvents = [
        "session.created",
        "session.updated",
        "session.idle",
      ];
      if (sessionEvents.includes(event.type)) {
        writeSessionFile(event);
      }
    },
  };
};
