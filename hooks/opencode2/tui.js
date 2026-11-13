// OpenCode 2 plugin — records which session each TUI is showing, for tmux-assistant-resurrect.
//
// OpenCode 2 runs one background server for every TUI, so a server plugin's process.pid is the
// server's and says nothing about a tmux pane. The TUI part of a plugin runs inside the opencode
// process in the pane, whose PID is what the save hook finds, so this file is the TUI part. Its
// state file has the shape hooks/opencode-session-track.js writes for OpenCode 1.
//
// Install: the installer links this directory to ~/.config/opencode/plugins/assistant-resurrect.

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

export default {
  id: "tmux-assistant-resurrect.tui",
  setup(context) {
    // Must resolve to exactly what assistant_state_dir() in scripts/lib-detect.sh produces; see
    // hooks/opencode-session-track.js for why this is $HOME and not XDG_RUNTIME_DIR/tmpdir().
    const stateDir =
      process.env.TMUX_ASSISTANT_RESURRECT_DIR ||
      `${process.env.HOME || homedir()}/.local/state/tmux-assistant-resurrect`;
    const pid = process.pid;
    const stateFile = `${stateDir}/opencode-${pid}.json`;

    // Mirrors ensure_assistant_state_dir() in scripts/lib-detect.sh: parents at the umask
    // default, the leaf private, and an existing directory left as the user set it up.
    if (!existsSync(stateDir)) {
      const trimmed = stateDir.replace(/\/+$/, "");
      const parent = trimmed.replace(/\/[^/]*$/, "");
      if (parent && parent !== trimmed) mkdirSync(parent, { recursive: true });
      try {
        mkdirSync(stateDir, { mode: 0o700 });
      } catch (err) {
        if (err.code !== "EEXIST") {
          mkdirSync(stateDir, { recursive: true, mode: 0o700 });
        }
      }
    }

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

    const cleanup = () => {
      try {
        unlinkSync(stateFile);
      } catch {
        // File may already be gone
      }
    };

    let recorded = null;
    const forget = () => {
      if (recorded === null) return;
      recorded = null;
      cleanup();
    };

    const record = () => {
      let route;
      try {
        route = context.ui.router.current();
      } catch {
        return;
      }
      // The home screen and plugin pages show no session. Dropping the file hands the next save
      // to the argv and database fallbacks instead of restoring a session the user left.
      if (route?.type !== "session" || !route.sessionID) return forget();

      let session;
      try {
        session = context.data.session.get(route.sessionID);
      } catch {
        // Session data not loaded yet; the next poll retries
      }
      // Subagent (child) and archived sessions are not resumable top-level conversations, and
      // scripts/py/opencode_db.py excludes them too. Viewing a child keeps its root on record.
      let sessionID = route.sessionID;
      if (session?.parentID) {
        try {
          sessionID = context.data.session.root(route.sessionID) || sessionID;
          session = context.data.session.get(sessionID);
        } catch {
          return;
        }
        if (session?.parentID) return;
      }
      if (session?.time?.archived) return forget();
      if (sessionID === recorded) return;

      const env = {
        tmux_pane: process.env.TMUX_PANE || "",
        shell: process.env.SHELL || "",
      };
      for (const varName of captureEnvVars) {
        env[varName] = process.env[varName] || "";
      }

      const directory =
        session?.location?.directory || context.location?.directory || process.cwd();
      const data = JSON.stringify(
        {
          tool: "opencode",
          session_id: sessionID,
          pid: pid,
          cwd: directory,
          timestamp: new Date().toISOString(),
          session: session || { id: sessionID },
          event_type: "route",
          init: { directory, argv: process.argv, execPath: process.execPath },
          env: env,
        },
        null,
        2,
      );
      // Atomic and 0600 for the same reasons as the OpenCode 1 plugin: the save hook reads this
      // file concurrently, and it holds captured environment values.
      const tempFile = `${stateFile}.${randomUUID()}.tmp`;
      try {
        writeFileSync(tempFile, data, { encoding: "utf8", mode: 0o600, flag: "wx" });
        renameSync(tempFile, stateFile);
        recorded = sessionID;
      } catch {
        try {
          unlinkSync(tempFile);
        } catch {
          // The write may have failed before the temporary file was created
        }
      }
    };

    // Switching tabs, opening a session from the list, or going back to the home screen emits no
    // server event, so the route is polled. Server events only make the common cases immediate.
    record();
    const stop = context.data.listen(record);
    const timer = setInterval(record, 1000);
    timer.unref?.();

    process.on("exit", cleanup);
    const signalHandlers = [];
    for (const signal of ["SIGINT", "SIGTERM"]) {
      const cleanupOnSignal = () => {
        cleanup();
        process.removeListener(signal, cleanupOnSignal);
        if (process.listenerCount(signal) === 0) process.kill(process.pid, signal);
      };
      process.prependListener(signal, cleanupOnSignal);
      signalHandlers.push([signal, cleanupOnSignal]);
    }

    return () => {
      stop();
      clearInterval(timer);
      process.removeListener("exit", cleanup);
      for (const [signal, handler] of signalHandlers) process.removeListener(signal, handler);
      cleanup();
    };
  },
};
