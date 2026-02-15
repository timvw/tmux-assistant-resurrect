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

# --- tmux settings ---

tmux set-option -g @resurrect-capture-pane-contents 'on'
tmux set-option -g @resurrect-processes '"~claude" "~opencode" "~codex"'
tmux set-option -g @resurrect-hook-post-save-all "bash ${CURRENT_DIR}/scripts/save-assistant-sessions.sh"
tmux set-option -g @resurrect-hook-post-restore-all "bash ${CURRENT_DIR}/scripts/restore-assistant-sessions.sh"
tmux set-option -g @continuum-save-interval '5'
tmux set-option -g @continuum-restore 'on'

# --- Claude Code hooks ---

install_claude_hooks() {
    local settings="$HOME/.claude/settings.json"
    local track_cmd="bash ${CURRENT_DIR}/hooks/claude-session-track.sh"
    local cleanup_cmd="bash ${CURRENT_DIR}/hooks/claude-session-cleanup.sh"

    # Ensure file exists
    if [ ! -f "$settings" ]; then
        mkdir -p "$(dirname "$settings")"
        echo '{}' > "$settings"
    fi

    # Skip if jq not available
    if ! command -v jq >/dev/null 2>&1; then
        return
    fi

    # Install SessionStart hook if not present
    if ! jq -e '.hooks.SessionStart[]?.hooks[]? | select(.command == "'"$track_cmd"'")' "$settings" >/dev/null 2>&1; then
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
    if ! jq -e '.hooks.SessionEnd[]?.hooks[]? | select(.command == "'"$cleanup_cmd"'")' "$settings" >/dev/null 2>&1; then
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
