# tmux-assistant-resurrect — session persistence for AI coding assistants
# Preserves Claude Code, OpenCode, and Codex CLI sessions across tmux restarts.

set shell := ["bash", "-euo", "pipefail", "-c"]

repo_dir := justfile_directory()
# State directory: uses TMUX_ASSISTANT_RESURRECT_DIR if set, else XDG_RUNTIME_DIR/TMPDIR/tmp.
# The just env() function can't do nested expansion, so recipes compute the
# default via shell. This variable is only used when the env var IS set.
state_dir_override := env("TMUX_ASSISTANT_RESURRECT_DIR", "")
_state_dir_expr := 'STATE_DIR="${TMUX_ASSISTANT_RESURRECT_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-assistant-resurrect}"'

# Show available recipes
default:
    @just --list

# Install everything: TPM, hooks, and tmux config
install: install-tpm install-hooks configure-tmux
    @echo ""
    @echo "Installation complete!"
    @echo ""
    @echo "Next steps:"
    @echo "  1. Reload tmux config:  tmux source-file ~/.tmux.conf"
    @echo "  2. Install TPM plugins: press prefix + I (capital I) inside tmux"
    @echo "  3. Verify:              just status"

# Install TPM (Tmux Plugin Manager)
install-tpm:
    @if [ -d ~/.tmux/plugins/tpm ]; then \
        echo "TPM already installed"; \
    else \
        echo "Installing TPM..."; \
        git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm; \
        echo "TPM installed at ~/.tmux/plugins/tpm"; \
    fi

# Install TPM plugins (resurrect + continuum)
install-plugins:
    @if [ -x ~/.tmux/plugins/tpm/bin/install_plugins ]; then \
        ~/.tmux/plugins/tpm/bin/install_plugins; \
    else \
        echo "TPM not found — run 'just install-tpm' first, then press prefix+I in tmux"; \
    fi

# Install assistant hooks (Claude hook + OpenCode plugin)
install-hooks: install-claude-hook install-opencode-plugin
    @echo "All assistant hooks installed"

# Install Claude Code hooks (SessionStart + SessionEnd) into ~/.claude/settings.json
install-claude-hook:
    #!/usr/bin/env bash
    set -euo pipefail
    settings="$HOME/.claude/settings.json"
    track_cmd="bash '{{repo_dir}}/hooks/claude-session-track.sh'"
    cleanup_cmd="bash '{{repo_dir}}/hooks/claude-session-cleanup.sh'"

    if [ ! -f "$settings" ]; then
        mkdir -p "$(dirname "$settings")"
        echo '{}' > "$settings"
    fi

    # Install SessionStart hook (session tracking)
    if jq -e '.hooks.SessionStart[]?.hooks[]? | select((.command // "") | contains("claude-session-track"))' "$settings" >/dev/null 2>&1; then
        echo "Claude SessionStart hook already configured"
    else
        tmp=$(mktemp)
        jq --arg cmd "$track_cmd" '
            .hooks //= {} |
            .hooks.SessionStart //= [] |
            .hooks.SessionStart += [{
                "matcher": "",
                "hooks": [{
                    "type": "command",
                    "command": $cmd
                }]
            }]
        ' "$settings" > "$tmp" && mv "$tmp" "$settings"
        echo "Claude SessionStart hook installed in $settings"
    fi

    # Install SessionEnd hook (state file cleanup)
    if jq -e '.hooks.SessionEnd[]?.hooks[]? | select((.command // "") | contains("claude-session-cleanup"))' "$settings" >/dev/null 2>&1; then
        echo "Claude SessionEnd hook already configured"
    else
        tmp=$(mktemp)
        jq --arg cmd "$cleanup_cmd" '
            .hooks //= {} |
            .hooks.SessionEnd //= [] |
            .hooks.SessionEnd += [{
                "matcher": "",
                "hooks": [{
                    "type": "command",
                    "command": $cmd
                }]
            }]
        ' "$settings" > "$tmp" && mv "$tmp" "$settings"
        echo "Claude SessionEnd hook installed in $settings"
    fi

# Install OpenCode session-tracker plugin
install-opencode-plugin:
    #!/usr/bin/env bash
    set -euo pipefail
    plugin_dir="$HOME/.config/opencode/plugins"
    plugin_file="$plugin_dir/session-tracker.js"
    source_file="{{repo_dir}}/hooks/opencode-session-track.js"

    mkdir -p "$plugin_dir"

    if [ -L "$plugin_file" ] && [ "$(readlink "$plugin_file")" = "$source_file" ]; then
        echo "OpenCode session-tracker plugin already linked"
        exit 0
    fi

    ln -sf "$source_file" "$plugin_file"
    echo "OpenCode session-tracker plugin linked at $plugin_file"

# Add resurrect config to ~/.tmux.conf
configure-tmux:
    #!/usr/bin/env bash
    set -euo pipefail
    conf="$HOME/.tmux.conf"
    tpm_line="run '~/.tmux/plugins/tpm/tpm'"
    begin_marker="# --- begin tmux-assistant-resurrect ---"
    end_marker="# --- end tmux-assistant-resurrect ---"

    touch "$conf"

    # Remove any existing marker block (handles re-runs and repo_dir changes).
    if grep -qF "$begin_marker" "$conf"; then
        tmp=$(mktemp)
        sed "/$begin_marker/,/$end_marker/d" "$conf" > "$tmp"
        mv "$tmp" "$conf"
    fi

    # Remove legacy source-file line from pre-marker installs
    if grep -qF "resurrect-assistants.conf" "$conf"; then
        tmp=$(mktemp)
        grep -v "resurrect-assistants.conf" "$conf" | grep -v "# tmux-assistant-resurrect" > "$tmp" || true
        mv "$tmp" "$conf"
    fi

    # Capture and remove the TPM init line so we can re-add it at the very
    # end. TPM's run line must be the last line in tmux.conf — anything
    # after it won't be processed. We preserve the user's original line
    # verbatim (custom path, if-shell wrapper, etc.) instead of replacing
    # it with a hardcoded default.
    existing_tpm_line=""
    if grep -qF "tpm/tpm" "$conf" 2>/dev/null; then
        existing_tpm_line=$(grep -F "tpm/tpm" "$conf" | tail -1)
        tmp=$(mktemp)
        grep -v "tpm/tpm" "$conf" > "$tmp" || true
        mv "$tmp" "$conf"
    fi

    # Write the new block with begin/end markers. The markers allow
    # unconfigure-tmux to remove exactly what we added (including plugin
    # lines) without affecting user settings outside the block.
    # NOTE: The sed patterns in this recipe work because the marker
    # strings contain no sed-special characters (no /, *, ., etc.).
    # If the markers ever change, the sed commands may need escaping.
    {
        echo ""
        echo "$begin_marker"
        echo "set -g @plugin 'tmux-plugins/tpm'"
        echo "set -g @plugin 'tmux-plugins/tmux-resurrect'"
        echo "set -g @plugin 'tmux-plugins/tmux-continuum'"
        echo "set -g @resurrect-capture-pane-contents 'on'"
        echo "set -g @resurrect-hook-post-save-all \"bash '{{repo_dir}}/scripts/save-assistant-sessions.sh'\""
        echo "set -g @resurrect-hook-post-restore-all \"bash '{{repo_dir}}/scripts/restore-assistant-sessions.sh'\""
        echo "set -g @continuum-save-interval '5'"
        echo "set -g @continuum-restore 'on'"
        echo "$end_marker"
    } >> "$conf"
    echo "Added tmux-assistant-resurrect settings to $conf"

    # Re-add TPM init as the very last line (required by TPM).
    # Use the user's original line if we captured one, otherwise the default.
    if [ -n "$existing_tpm_line" ]; then
        echo "$existing_tpm_line" >> "$conf"
        echo "TPM init moved to end of $conf"
    else
        echo "$tpm_line" >> "$conf"
        echo "Added TPM init to $conf"
    fi

# Remove all installed hooks and config
uninstall: uninstall-claude-hook uninstall-opencode-plugin unconfigure-tmux
    @echo ""
    @echo "Uninstalled. You may also want to:"
    @echo "  - Remove TPM: rm -rf ~/.tmux/plugins/"
    @echo "  - Reload tmux: tmux source-file ~/.tmux.conf"

# Remove Claude Code hooks (SessionStart + SessionEnd)
uninstall-claude-hook:
    #!/usr/bin/env bash
    set -euo pipefail
    settings="$HOME/.claude/settings.json"

    if [ ! -f "$settings" ]; then
        echo "No Claude settings to modify"
        exit 0
    fi

    # Remove both hooks in one pass.
    # Use contains() matching to remove both old (unquoted) and new (quoted)
    # forms — ensures clean upgrade without leftover entries.
    tmp=$(mktemp)
    jq '
        # Remove SessionStart hook entries containing "claude-session-track"
        (if .hooks.SessionStart then
            .hooks.SessionStart = [
                .hooks.SessionStart[] |
                .hooks = [.hooks[] | select((.command // "") | contains("claude-session-track") | not)] |
                select(.hooks | length > 0)
            ] |
            if .hooks.SessionStart | length == 0 then del(.hooks.SessionStart) else . end
        else . end) |
        # Remove SessionEnd hook entries containing "claude-session-cleanup"
        (if .hooks.SessionEnd then
            .hooks.SessionEnd = [
                .hooks.SessionEnd[] |
                .hooks = [.hooks[] | select((.command // "") | contains("claude-session-cleanup") | not)] |
                select(.hooks | length > 0)
            ] |
            if .hooks.SessionEnd | length == 0 then del(.hooks.SessionEnd) else . end
        else . end) |
        # Clean up empty hooks object
        if .hooks and (.hooks | length == 0) then del(.hooks) else . end
    ' "$settings" > "$tmp" && mv "$tmp" "$settings"

    echo "Claude hooks removed"

# Remove OpenCode session-tracker plugin
uninstall-opencode-plugin:
    #!/usr/bin/env bash
    set -euo pipefail
    plugin_file="$HOME/.config/opencode/plugins/session-tracker.js"
    if [ -L "$plugin_file" ] || [ -f "$plugin_file" ]; then
        rm -f "$plugin_file"
        echo "OpenCode session-tracker plugin removed"
    else
        echo "OpenCode plugin not found, nothing to remove"
    fi

# Remove resurrect config from ~/.tmux.conf
unconfigure-tmux:
    #!/usr/bin/env bash
    set -euo pipefail
    conf="$HOME/.tmux.conf"
    if [ ! -f "$conf" ]; then
        exit 0
    fi

    begin_marker="# --- begin tmux-assistant-resurrect ---"
    end_marker="# --- end tmux-assistant-resurrect ---"

    # Remove the marker block (current format).
    # NOTE: sed range pattern works because markers contain no sed-special
    # characters. If markers ever change, escaping may be needed.
    if grep -qF "$begin_marker" "$conf"; then
        tmp=$(mktemp)
        sed "/$begin_marker/,/$end_marker/d" "$conf" > "$tmp"
        mv "$tmp" "$conf"
    fi

    # Also remove legacy format (source-file + comment, pre-marker installs)
    if grep -qF "resurrect-assistants.conf" "$conf"; then
        tmp=$(mktemp)
        grep -v "resurrect-assistants.conf" "$conf" | grep -v "# tmux-assistant-resurrect" > "$tmp" || true
        mv "$tmp" "$conf"
    fi

    echo "Removed tmux-assistant-resurrect settings from $conf"

# Show current status: installed hooks, tracked sessions, state files
status:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== tmux-assistant-resurrect status ==="
    echo ""

    # TPM
    if [ -d ~/.tmux/plugins/tpm ]; then
        echo "[ok] TPM installed"
    else
        echo "[--] TPM not installed"
    fi

    # Resurrect plugin
    if [ -d ~/.tmux/plugins/tmux-resurrect ]; then
        echo "[ok] tmux-resurrect installed"
    else
        echo "[--] tmux-resurrect not installed (press prefix+I in tmux)"
    fi

    # Continuum plugin
    if [ -d ~/.tmux/plugins/tmux-continuum ]; then
        echo "[ok] tmux-continuum installed"
    else
        echo "[--] tmux-continuum not installed (press prefix+I in tmux)"
    fi

    # tmux.conf — check for marker block, legacy source-file, or any reference
    if grep -qF "begin tmux-assistant-resurrect" ~/.tmux.conf 2>/dev/null || \
       grep -qF "resurrect-assistants.conf" ~/.tmux.conf 2>/dev/null; then
        echo "[ok] tmux.conf configured"
    else
        echo "[--] tmux.conf not configured"
    fi

    # Claude hooks — use contains() matching to detect both old and new quoting forms
    if jq -e '.hooks.SessionStart[]?.hooks[]? | select((.command // "") | contains("claude-session-track"))' ~/.claude/settings.json >/dev/null 2>&1; then
        echo "[ok] Claude SessionStart hook installed"
    else
        echo "[--] Claude SessionStart hook not installed"
    fi
    if jq -e '.hooks.SessionEnd[]?.hooks[]? | select((.command // "") | contains("claude-session-cleanup"))' ~/.claude/settings.json >/dev/null 2>&1; then
        echo "[ok] Claude SessionEnd hook installed"
    else
        echo "[--] Claude SessionEnd hook not installed"
    fi

    # OpenCode plugin
    if [ -L ~/.config/opencode/plugins/session-tracker.js ]; then
        echo "[ok] OpenCode session-tracker plugin linked"
    else
        echo "[--] OpenCode session-tracker plugin not linked"
    fi

    echo ""

    # State files
    {{_state_dir_expr}}
    state_dir="$STATE_DIR"
    if [ -d "$state_dir" ]; then
        file_count=$(find "$state_dir" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
        echo "State directory: $state_dir ($file_count active tracking file(s))"
        if [ "$file_count" -gt 0 ]; then
            echo ""
            for f in "$state_dir"/*.json; do
                tool=$(jq -r '.tool' "$f" 2>/dev/null || echo "?")
                sid=$(jq -r '.session_id' "$f" 2>/dev/null || echo "?")
                ts=$(jq -r '.timestamp' "$f" 2>/dev/null || echo "?")
                echo "  $tool: $sid (tracked at $ts)"
            done
        fi
    else
        echo "State directory: $state_dir (not created yet)"
    fi

    echo ""

    # Last saved assistant sessions
    saved="${HOME}/.tmux/resurrect/assistant-sessions.json"
    if [ -f "$saved" ]; then
        count=$(jq '.sessions | length' "$saved" 2>/dev/null || echo 0)
        ts=$(jq -r '.timestamp' "$saved" 2>/dev/null || echo "?")
        echo "Last save: $ts ($count session(s))"
        if [ "$count" -gt 0 ]; then
            jq -r '.sessions[] | "  \(.tool) in \(.pane): \(.session_id)"' "$saved" 2>/dev/null
        fi
    else
        echo "No saved assistant sessions yet"
    fi

# Manually trigger a save of current assistant sessions
save:
    @bash "{{repo_dir}}/scripts/save-assistant-sessions.sh"

# Manually trigger a restore of saved assistant sessions
restore:
    @bash "{{repo_dir}}/scripts/restore-assistant-sessions.sh"

# Clean up stale state files (from dead processes)
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    {{_state_dir_expr}}
    state_dir="$STATE_DIR"
    if [ ! -d "$state_dir" ]; then
        echo "Nothing to clean"
        exit 0
    fi

    removed=0
    for f in "$state_dir"/*.json; do
        [ -f "$f" ] || continue
        # NOTE: || continue inside $() is a no-op (subshell context). Use
        # a separate step so the loop actually skips corrupt files.
        tool=$(jq -r '.tool' "$f" 2>/dev/null) || continue

        case "$tool" in
            claude)
                pid=$(jq -r '.ppid' "$f" 2>/dev/null || echo "")
                ;;
            opencode)
                pid=$(jq -r '.pid' "$f" 2>/dev/null || echo "")
                ;;
            *)
                continue
                ;;
        esac

        # Treat non-numeric, empty, or <=1 PIDs as invalid (stale/corrupt).
        # Without this, pid="0" would cause `kill -0 0` to succeed (checks
        # current process group), keeping the corrupt file forever.
        if ! [[ "$pid" =~ ^[0-9]+$ ]] || [ "${pid:-0}" -le 1 ]; then
            rm -f "$f"
            removed=$((removed + 1))
            continue
        fi

        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$f"
            removed=$((removed + 1))
        fi
    done

    echo "Cleaned $removed stale state file(s)"

# Run integration tests in Docker
test:
    docker build -t tmux-assistant-resurrect-test -f test/Dockerfile .
    docker run --rm tmux-assistant-resurrect-test
