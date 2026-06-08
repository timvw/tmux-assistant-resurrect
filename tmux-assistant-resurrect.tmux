#!/usr/bin/env bash
# TPM plugin entry point for tmux-assistant-resurrect.
# TPM executes this script when the plugin is installed or tmux starts.
#
# This sets up:
# 1. tmux-resurrect + tmux-continuum settings
# 2. Post-save/restore hooks for assistant session tracking
# 3. Claude Code hooks in ~/.claude/settings.json
# 4. OpenCode session-tracker plugin in ~/.config/opencode/plugins/
# 5. Pi support via ~/.pi/agent/sessions lookup (no hook required)

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
# Respect user's @continuum-save-interval if already set
if [ -z "$(tmux show-option -gqv @continuum-save-interval)" ]; then
    tmux set-option -g @continuum-save-interval '5'
fi
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

    # Install SessionStart hook, refreshing stale paths if any exist.
    # Skip only when the current command is present AND no stale copies remain.
    local has_current_track has_stale_track
    has_current_track=$(jq --arg cmd "$track_cmd" '[.hooks.SessionStart[]?.hooks[]? | select((.command // "") == $cmd)] | length' "$settings" 2>/dev/null || echo 0)
    has_stale_track=$(jq --arg cmd "$track_cmd" '[.hooks.SessionStart[]?.hooks[]? | select(((.command // "") | contains("claude-session-track")) and ((.command // "") != $cmd))] | length' "$settings" 2>/dev/null || echo 0)
    if [ "$has_current_track" = "0" ] || [ "$has_stale_track" != "0" ]; then
        local tmp
        tmp=$(mktemp)
        jq --arg cmd "$track_cmd" '
            .hooks //= {} |
            .hooks.SessionStart //= [] |
            # Drop any prior instance of this hook (different paths included).
            .hooks.SessionStart |= map(
                .hooks = ((.hooks // []) | map(select((.command // "") | contains("claude-session-track") | not)))
            ) |
            # Drop entries whose hooks list became empty after the filter.
            .hooks.SessionStart |= map(select((.hooks // []) | length > 0)) |
            .hooks.SessionStart += [{
                "matcher": "",
                "hooks": [{"type": "command", "command": $cmd}]
            }]
        ' "$settings" > "$tmp" && mv "$tmp" "$settings"
    fi

    # Install SessionEnd hook (same self-healing pattern as SessionStart).
    local has_current_cleanup has_stale_cleanup
    has_current_cleanup=$(jq --arg cmd "$cleanup_cmd" '[.hooks.SessionEnd[]?.hooks[]? | select((.command // "") == $cmd)] | length' "$settings" 2>/dev/null || echo 0)
    has_stale_cleanup=$(jq --arg cmd "$cleanup_cmd" '[.hooks.SessionEnd[]?.hooks[]? | select(((.command // "") | contains("claude-session-cleanup")) and ((.command // "") != $cmd))] | length' "$settings" 2>/dev/null || echo 0)
    if [ "$has_current_cleanup" = "0" ] || [ "$has_stale_cleanup" != "0" ]; then
        local tmp
        tmp=$(mktemp)
        jq --arg cmd "$cleanup_cmd" '
            .hooks //= {} |
            .hooks.SessionEnd //= [] |
            .hooks.SessionEnd |= map(
                .hooks = ((.hooks // []) | map(select((.command // "") | contains("claude-session-cleanup") | not)))
            ) |
            .hooks.SessionEnd |= map(select((.hooks // []) | length > 0)) |
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
