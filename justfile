# tmux-assistant-resurrect — session persistence for AI coding assistants
# Preserves Claude Code, OpenCode, and Codex CLI sessions across tmux restarts.

set shell := ["bash", "-euo", "pipefail", "-c"]

repo_dir := justfile_directory()
state_dir := env("TMUX_ASSISTANT_RESURRECT_DIR", "/tmp/tmux-assistant-resurrect")

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

# Install Claude Code SessionStart hook into ~/.claude/settings.json
install-claude-hook:
    #!/usr/bin/env bash
    set -euo pipefail
    settings="$HOME/.claude/settings.json"
    hook_cmd="bash {{repo_dir}}/hooks/claude-session-track.sh"

    if [ ! -f "$settings" ]; then
        echo '{}' > "$settings"
    fi

    # Check if hook already exists
    if jq -e '.hooks.SessionStart[]?.hooks[]? | select(.command == "'"$hook_cmd"'")' "$settings" >/dev/null 2>&1; then
        echo "Claude SessionStart hook already configured"
        exit 0
    fi

    # Add the hook using jq
    tmp=$(mktemp)
    jq --arg cmd "$hook_cmd" '
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
    source_line="source-file {{repo_dir}}/config/resurrect-assistants.conf"
    tpm_line="run '~/.tmux/plugins/tpm/tpm'"

    # Check if already sourced
    if grep -qF "resurrect-assistants.conf" "$conf" 2>/dev/null; then
        echo "tmux config already sources resurrect-assistants.conf"
    else
        echo "" >> "$conf"
        echo "# tmux-assistant-resurrect" >> "$conf"
        echo "$source_line" >> "$conf"
        echo "Added source line to $conf"
    fi

    # Ensure TPM init is present and is the last line
    if grep -qF "tpm/tpm" "$conf" 2>/dev/null; then
        echo "TPM init already present in $conf"
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

# Remove Claude Code SessionStart hook
uninstall-claude-hook:
    #!/usr/bin/env bash
    set -euo pipefail
    settings="$HOME/.claude/settings.json"
    hook_cmd="bash {{repo_dir}}/hooks/claude-session-track.sh"

    if [ ! -f "$settings" ]; then
        echo "No Claude settings to modify"
        exit 0
    fi

    tmp=$(mktemp)
    jq --arg cmd "$hook_cmd" '
        if .hooks.SessionStart then
            .hooks.SessionStart = [
                .hooks.SessionStart[] |
                .hooks = [.hooks[] | select(.command != $cmd)] |
                select(.hooks | length > 0)
            ] |
            if .hooks.SessionStart | length == 0 then del(.hooks.SessionStart) else . end |
            if .hooks | length == 0 then del(.hooks) else . end
        else . end
    ' "$settings" > "$tmp" && mv "$tmp" "$settings"

    echo "Claude SessionStart hook removed"

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

    tmp=$(mktemp)
    grep -v "resurrect-assistants.conf" "$conf" | grep -v "# tmux-assistant-resurrect" > "$tmp"
    mv "$tmp" "$conf"
    echo "Removed resurrect-assistants.conf source from $conf"

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

    # tmux.conf
    if grep -qF "resurrect-assistants.conf" ~/.tmux.conf 2>/dev/null; then
        echo "[ok] tmux.conf configured"
    else
        echo "[--] tmux.conf not configured"
    fi

    # Claude hook
    hook_cmd="bash {{repo_dir}}/hooks/claude-session-track.sh"
    if jq -e '.hooks.SessionStart[]?.hooks[]? | select(.command == "'"$hook_cmd"'")' ~/.claude/settings.json >/dev/null 2>&1; then
        echo "[ok] Claude SessionStart hook installed"
    else
        echo "[--] Claude SessionStart hook not installed"
    fi

    # OpenCode plugin
    if [ -L ~/.config/opencode/plugins/session-tracker.js ]; then
        echo "[ok] OpenCode session-tracker plugin linked"
    else
        echo "[--] OpenCode session-tracker plugin not linked"
    fi

    echo ""

    # State files
    state_dir="{{state_dir}}"
    if [ -d "$state_dir" ]; then
        file_count=$(ls "$state_dir"/*.json 2>/dev/null | wc -l | tr -d ' ')
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
    @bash {{repo_dir}}/scripts/save-assistant-sessions.sh

# Manually trigger a restore of saved assistant sessions
restore:
    @bash {{repo_dir}}/scripts/restore-assistant-sessions.sh

# Clean up stale state files (from dead processes)
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    state_dir="{{state_dir}}"
    if [ ! -d "$state_dir" ]; then
        echo "Nothing to clean"
        exit 0
    fi

    removed=0
    for f in "$state_dir"/*.json; do
        [ -f "$f" ] || continue
        tool=$(jq -r '.tool' "$f" 2>/dev/null || continue)

        case "$tool" in
            claude)
                pid=$(jq -r '.ppid' "$f" 2>/dev/null || echo "0")
                ;;
            opencode)
                pid=$(jq -r '.pid' "$f" 2>/dev/null || echo "0")
                ;;
            *)
                continue
                ;;
        esac

        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$f"
            removed=$((removed + 1))
        fi
    done

    echo "Cleaned $removed stale state file(s)"
