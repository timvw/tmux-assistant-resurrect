#!/usr/bin/env bash
# TPM plugin entry point for tmux-assistant-resurrect.
# TPM executes this script when the plugin is installed or tmux starts.
#
# This sets up:
# 1. tmux-resurrect + tmux-continuum settings
# 2. Post-save/restore hooks for assistant session tracking
# 3. Claude Code hooks in ~/.claude/settings.json
# 4. OpenCode session-tracker plugin in ~/.config/opencode/plugins/

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Limitation: hook commands use single-quoted paths (bash '${CURRENT_DIR}/...').
# If the plugin install path contains a single quote, the quoting breaks.
# This is unlikely in practice (TPM installs to ~/.tmux/plugins/).

# --- tmux settings ---

# Do NOT set @resurrect-capture-pane-contents here — that is the user's choice.
# If it is enabled, the post-save hook strips captured content for assistant panes
# (see strip_assistant_pane_contents in save-assistant-sessions.sh) so restore
# won't briefly flash stale TUI output before the assistant is resumed.
#
# Do NOT add assistants to @resurrect-processes — that would launch bare
# binaries (without session IDs) and the post-restore hook would then type
# resume commands into the running TUI. The hook handles all resuming.
tmux set-option -g @resurrect-hook-post-save-all "bash '${CURRENT_DIR}/scripts/save-assistant-sessions.sh'"
tmux set-option -g @resurrect-hook-post-restore-all "bash '${CURRENT_DIR}/scripts/restore-assistant-sessions.sh'"
tmux set-option -g @continuum-save-interval '5'
tmux set-option -g @continuum-restore 'on'

# --- Claude Code hooks ---

install_claude_hooks() {
    local settings="$HOME/.claude/settings.json"
    local track_cmd="bash '${CURRENT_DIR}/hooks/claude-session-track.sh'"
    local cleanup_cmd="bash '${CURRENT_DIR}/hooks/claude-session-cleanup.sh'"

    # Ensure file exists
    if [ ! -f "$settings" ]; then
        mkdir -p "$(dirname "$settings")"
        echo '{}' > "$settings"
    fi

    # Skip if jq not available
    if ! command -v jq >/dev/null 2>&1; then
        return
    fi

    # Install SessionStart hook if not present.
    # Use contains() for matching — tolerates quoting changes across versions
    # (e.g., upgrading from unquoted to quoted paths won't create duplicates).
    if ! jq -e '.hooks.SessionStart[]?.hooks[]? | select((.command // "") | contains("claude-session-track"))' "$settings" >/dev/null 2>&1; then
        local tmp
        tmp=$(mktemp)
        jq --arg cmd "$track_cmd" '
            .hooks //= {} |
            .hooks.SessionStart //= [] |
            .hooks.SessionStart += [{
                "matcher": "",
                "hooks": [{"type": "command", "command": $cmd}]
            }]
        ' "$settings" > "$tmp" && mv "$tmp" "$settings"
    fi

    # Install SessionEnd hook if not present
    if ! jq -e '.hooks.SessionEnd[]?.hooks[]? | select((.command // "") | contains("claude-session-cleanup"))' "$settings" >/dev/null 2>&1; then
        local tmp
        tmp=$(mktemp)
        jq --arg cmd "$cleanup_cmd" '
            .hooks //= {} |
            .hooks.SessionEnd //= [] |
            .hooks.SessionEnd += [{
                "matcher": "",
                "hooks": [{"type": "command", "command": $cmd}]
            }]
        ' "$settings" > "$tmp" && mv "$tmp" "$settings"
    fi
}

# --- OpenCode plugin ---

install_opencode_plugin() {
    local plugin_dir="$HOME/.config/opencode/plugins"
    local plugin_file="$plugin_dir/session-tracker.js"
    local source_file="${CURRENT_DIR}/hooks/opencode-session-track.js"

    mkdir -p "$plugin_dir"

    # Only update if not already correctly linked
    if [ -L "$plugin_file" ] && [ "$(readlink "$plugin_file")" = "$source_file" ]; then
        return
    fi

    ln -sf "$source_file" "$plugin_file"
}

# --- Run assistant hook installation ---

install_claude_hooks
install_opencode_plugin
