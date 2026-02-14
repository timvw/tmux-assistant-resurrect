# Design Principles

## ZFC: Zero False Commands

Inspired by [Gastown](https://github.com/steveyegge/gastown) by Steve Yegge and
adopted from [teamctl/pane-patrol](https://github.com/timvw/teamctl).

**Core tenet: "Scripts transport. AI decides."**

### What scripts do

- Capture pane metadata from tmux (PIDs, working directories)
- Read session ID state files written by tool-native hooks/plugins
- Parse process arguments for session identifiers
- Format and write JSON output
- Send commands to tmux panes via `tmux send-keys`

### What scripts NEVER do

- Decide whether a pane is running an AI coding assistant
- Interpret pane content or screen output
- Apply heuristics or regex to classify agents
- Hardcode lists of process names for agent detection

### What the LLM decides (via pane-patrol)

Agent detection is delegated entirely to
[pane-patrol](https://github.com/timvw/pane-patrol), which uses an LLM to
classify each tmux pane:

- Is this an AI coding agent? Which one?
- What kind of agent is it? (Claude Code, OpenCode, Codex, etc.)

### Acceptable exceptions

Some operations are infrastructure plumbing, not cognitive interpretation:

- **Agent name normalization**: Mapping the LLM's free-form agent name
  (e.g., "Claude Code", "claude-code") to canonical tool names ("claude",
  "opencode", "codex") for session ID extraction. This is string mapping, not
  classification.
- **Session ID extraction**: Reading state files, parsing process arguments for
  `-s ses_XXX` flags, and looking up PIDs in `session-tags.jsonl`. This is
  mechanical data retrieval from known locations.
- **Process tree inspection**: Finding child processes of a tmux pane's shell via
  `ps`. This is OS-level plumbing.
- **tmux interaction**: Listing panes, sending keys, reading pane metadata. This
  is transport.

### Dependencies

- [pane-patrol](https://github.com/timvw/pane-patrol) (or
  [teamctl](https://github.com/timvw/teamctl)) must be installed and an LLM API
  key configured for agent detection to work.
- Tool-native hooks (Claude `SessionStart` hook, OpenCode plugin) must be
  installed for session ID tracking.
