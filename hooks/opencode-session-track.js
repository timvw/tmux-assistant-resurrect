// OpenCode plugin — tracks the active session ID to a file on disk.
// Fires on session.created, session.updated, and session.idle events.
// Cleans up state file on process exit.
//
// Install: symlink into ~/.config/opencode/plugins/ (global) or .opencode/plugins/ (project).

import { writeFileSync, mkdirSync, unlinkSync } from "fs";
import { tmpdir } from "os";

export const SessionTracker = async ({ client }) => {
  const stateDir =
    process.env.TMUX_ASSISTANT_RESURRECT_DIR ||
    `${process.env.XDG_RUNTIME_DIR || tmpdir()}/tmux-assistant-resurrect`;
  const pid = process.pid;
  const stateFile = `${stateDir}/opencode-${pid}.json`;

  mkdirSync(stateDir, { recursive: true, mode: 0o700 });

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

  const writeSessionFile = (sessionID) => {
    if (!sessionID) return;
    const data = JSON.stringify(
      {
        tool: "opencode",
        session_id: sessionID,
        pid: pid,
        timestamp: new Date().toISOString(),
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
        const sessionID = event.properties?.id;
        writeSessionFile(sessionID);
      }
    },
  };
};
