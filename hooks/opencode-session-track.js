// OpenCode plugin — tracks the active session ID to a file on disk.
// Fires on session.created, session.updated, and session.idle events.
//
// Install: symlink into ~/.config/opencode/plugins/ (global) or .opencode/plugins/ (project).

import { writeFileSync, mkdirSync } from "fs";

export const SessionTracker = async ({ client }) => {
  const stateDir =
    process.env.TMUX_ASSISTANT_RESURRECT_DIR ||
    "/tmp/tmux-assistant-resurrect";
  const pid = process.pid;

  mkdirSync(stateDir, { recursive: true });

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
      writeFileSync(`${stateDir}/opencode-${pid}.json`, data);
    } catch (err) {
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
