#!/usr/bin/env bash
# TPM plugin entry point for tmux-assistant-resurrect.
# TPM executes this script when the plugin is installed or tmux starts.
#
# This sets up:
# 1. tmux-resurrect + tmux-continuum settings
# 2. Post-save/restore hooks for assistant session tracking
# 3. Claude Code hooks in ~/.claude/settings.json
# 4. Cursor Agent CLI hooks in ~/.cursor/hooks.json
# 5. OpenCode session-tracker plugin in ~/.config/opencode/plugins/
# 6. GitHub Copilot CLI support via its open session database (no hook required)
# 7. Pi and Oh My Pi support via local session-file lookup (no hook required)
# 8. Grok support via the ~/.grok/active_sessions.json registry (no hook required)

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Quote one shell word without allowing the path to expand when the hook runs.
# shellcheck disable=SC1003
shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

hook_command() {
    local path="$1"
    case "$path" in
        "$HOME"/*)
            # Keep dotfiles portable across machines: expand only $HOME, while
            # quoting the remainder as a separate, adjacent shell word fragment.
            # Expansion of $HOME is intentionally deferred until hook runtime.
            # shellcheck disable=SC2016
            printf 'bash "$HOME"%s' "$(shell_quote "${path#"$HOME"}")"
            ;;
        *)
            printf 'bash %s' "$(shell_quote "$path")"
            ;;
    esac
}

# --- tmux settings ---

# Do NOT set @resurrect-capture-pane-contents here — that is the user's choice.
# If it is enabled, the post-save hook strips captured content for assistant panes
# (see strip_assistant_pane_contents in save-assistant-sessions.sh) so restore
# won't briefly flash stale TUI output before the assistant is resumed.
#
# Do NOT add assistants to @resurrect-processes — that would launch bare
# binaries (without session IDs) and the post-restore hook would then type
# resume commands into the running TUI. The hook handles all resuming.
# Session-less modes are relaunched only through the exact user-owned voucher
# checked by the same restore hook. Enabled by default is safe because a
# missing/empty voucher authorizes nothing.
if [ -z "$(tmux show-option -gqv @assistant-resurrect-relaunch)" ]; then
    tmux set-option -g @assistant-resurrect-relaunch 'on'
fi
# @assistant-resurrect-relaunch-allow-file may override the default voucher
# beside tmux-resurrect's save files. Leaving it unset keeps save-dir discovery
# dynamic when users change @resurrect-dir.
tmux set-option -g @resurrect-hook-post-save-all "$(hook_command "${CURRENT_DIR}/scripts/save-assistant-sessions.sh")"
tmux set-option -g @resurrect-hook-post-restore-all "$(hook_command "${CURRENT_DIR}/scripts/restore-assistant-sessions.sh")"
# Respect user's @continuum-save-interval if already set
if [ -z "$(tmux show-option -gqv @continuum-save-interval)" ]; then
    tmux set-option -g @continuum-save-interval '5'
fi
# Respect user's @continuum-restore if already set (same guard as save-interval)
if [ -z "$(tmux show-option -gqv @continuum-restore)" ]; then
    tmux set-option -g @continuum-restore 'on'
fi

# --- Claude Code hooks ---

install_claude_hooks() {
    local settings="$HOME/.claude/settings.json"
    local hooks_dir="${CURRENT_DIR}/hooks"
    local track_cmd cleanup_cmd

    # Do not create or modify Claude's configuration when the dependency needed
    # to perform a safe JSON update is unavailable.
    if ! command -v jq >/dev/null 2>&1; then
        return
    fi

    # settings.json is a file users commonly track in a dotfiles repo, so the
    # command we persist must not embed a machine-specific absolute path.
    # Store it relative to $HOME and let the shell expand it when the hook runs;
    # that keeps the value byte-identical across machines with different
    # usernames. Only $HOME sits in double quotes -- the rest of the path stays
    # single-quoted and adjacent, so the shell concatenates the two without
    # interpreting a $, backtick or double quote in the install path.
    # Installs outside $HOME keep the single-quoted absolute path.
    track_cmd=$(hook_command "${hooks_dir}/claude-session-track.sh")
    cleanup_cmd=$(hook_command "${hooks_dir}/claude-session-cleanup.sh")

    # Ensure file exists
    if [ ! -f "$settings" ]; then
        (umask 077 && mkdir -p "$(dirname "$settings")" && printf '{}\n' > "$settings") || {
            echo "tmux-assistant-resurrect: cannot create $settings" >&2
            return
        }
    fi

    # Install SessionStart hook, refreshing stale paths if any exist.
    # Skip only when the current command is present AND no stale copies remain.
    local has_current_track has_stale_track
    has_current_track=$(jq --arg cmd "$track_cmd" '[.hooks.SessionStart[]?.hooks[]? | select((.command // "") == $cmd)] | length' "$settings" 2>/dev/null || echo 0)
    has_stale_track=$(jq --arg cmd "$track_cmd" '[.hooks.SessionStart[]?.hooks[]? | select(((.command // "") | contains("claude-session-track")) and ((.command // "") != $cmd))] | length' "$settings" 2>/dev/null || echo 0)
    if [ "$has_current_track" = "0" ] || [ "$has_stale_track" != "0" ]; then
        local tmp
        tmp=$(mktemp "${settings}.tmp.XXXXXX") || return
        if jq --arg cmd "$track_cmd" '
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
        ' "$settings" > "$tmp"; then
            if ! mv "$tmp" "$settings"; then
                rm -f "$tmp"
                echo "tmux-assistant-resurrect: cannot replace $settings" >&2
                return
            fi
        else
            rm -f "$tmp"
            echo "tmux-assistant-resurrect: $settings is not valid Claude settings JSON" >&2
            return
        fi
    fi

    # Install SessionEnd hook (same self-healing pattern as SessionStart).
    local has_current_cleanup has_stale_cleanup
    has_current_cleanup=$(jq --arg cmd "$cleanup_cmd" '[.hooks.SessionEnd[]?.hooks[]? | select((.command // "") == $cmd)] | length' "$settings" 2>/dev/null || echo 0)
    has_stale_cleanup=$(jq --arg cmd "$cleanup_cmd" '[.hooks.SessionEnd[]?.hooks[]? | select(((.command // "") | contains("claude-session-cleanup")) and ((.command // "") != $cmd))] | length' "$settings" 2>/dev/null || echo 0)
    if [ "$has_current_cleanup" = "0" ] || [ "$has_stale_cleanup" != "0" ]; then
        local tmp
        tmp=$(mktemp "${settings}.tmp.XXXXXX") || return
        if jq --arg cmd "$cleanup_cmd" '
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
        ' "$settings" > "$tmp"; then
            if ! mv "$tmp" "$settings"; then
                rm -f "$tmp"
                echo "tmux-assistant-resurrect: cannot replace $settings" >&2
                return
            fi
        else
            rm -f "$tmp"
            echo "tmux-assistant-resurrect: $settings is not valid Claude settings JSON" >&2
            return
        fi
    fi
}

# --- Cursor Agent CLI hooks ---

install_cursor_hooks() {
    local settings="$HOME/.cursor/hooks.json"
    local hooks_dir track_cmd cleanup_cmd
    hooks_dir="${CURRENT_DIR}/hooks"

    command -v jq >/dev/null 2>&1 || return
    track_cmd=$(hook_command "${hooks_dir}/cursor-session-track.sh")
    cleanup_cmd=$(hook_command "${hooks_dir}/cursor-session-cleanup.sh")

    if [ ! -f "$settings" ]; then
        (umask 077 && mkdir -p "$(dirname "$settings")" && printf '{"version":1}\n' > "$settings") || {
            echo "tmux-assistant-resurrect: cannot create $settings" >&2
            return
        }
    fi

    local has_current_track has_stale_track has_current_cleanup has_stale_cleanup
    has_current_track=$(jq --arg cmd "$track_cmd" '[.hooks.sessionStart[]? | select((.command // "") == $cmd)] | length' "$settings" 2>/dev/null || echo 0)
    has_stale_track=$(jq --arg cmd "$track_cmd" '[.hooks.sessionStart[]? | select(((.command // "") | contains("cursor-session-track")) and ((.command // "") != $cmd))] | length' "$settings" 2>/dev/null || echo 0)
    has_current_cleanup=$(jq --arg cmd "$cleanup_cmd" '[.hooks.sessionEnd[]? | select((.command // "") == $cmd)] | length' "$settings" 2>/dev/null || echo 0)
    has_stale_cleanup=$(jq --arg cmd "$cleanup_cmd" '[.hooks.sessionEnd[]? | select(((.command // "") | contains("cursor-session-cleanup")) and ((.command // "") != $cmd))] | length' "$settings" 2>/dev/null || echo 0)

    if [ "$has_current_track" = "0" ] || [ "$has_stale_track" != "0" ] || \
       [ "$has_current_cleanup" = "0" ] || [ "$has_stale_cleanup" != "0" ]; then
        # Keep this resolution/update sequence aligned with uninstall-cursor-hook
        # in justfile; both operations must preserve the same user-owned file.
        local target="$settings" link target_mode="" tmp link_depth=0
        while [ -L "$target" ] && [ "$link_depth" -lt 16 ]; do
            link=$(readlink "$target") || {
                echo "tmux-assistant-resurrect: cannot read symlink $target; left unchanged" >&2
                return
            }
            case "$link" in
                /*) target="$link" ;;
                *) target="$(dirname "$target")/$link" ;;
            esac
            link_depth=$((link_depth + 1))
        done
        if [ -L "$target" ]; then
            echo "tmux-assistant-resurrect: refusing deep or cyclic symlink chain at $settings" >&2
            return
        fi
        # BSD stat's %p includes the file type plus all permission bits; keep its
        # final four octal digits. The literal prefix makes GNU stat -f output
        # fail the octal guard before -c retries.
        target_mode=$(stat -f 'mode:%p' "$target" 2>/dev/null || true)
        case "$target_mode" in
            mode:*) target_mode=${target_mode#mode:} ;;
            *) target_mode="" ;;
        esac
        case "$target_mode" in
            '' | *[!0-7]*) target_mode="" ;;
            *)
                if [ "${#target_mode}" -ge 4 ]; then
                    target_mode=${target_mode#"${target_mode%????}"}
                else
                    target_mode=""
                fi
                ;;
        esac
        case "$target_mode" in
            '' | *[!0-7]*) target_mode=$(stat -c '%a' "$target" 2>/dev/null || true) ;;
        esac
        case "$target_mode" in
            '' | *[!0-7]*)
                echo "tmux-assistant-resurrect: cannot read mode for $settings; left unchanged" >&2
                return
                ;;
        esac
        tmp=$(mktemp "${target}.tmp.XXXXXX") || {
            echo "tmux-assistant-resurrect: cannot prepare update for $settings; left unchanged" >&2
            return
        }
        if jq --arg track "$track_cmd" --arg cleanup "$cleanup_cmd" '
            .version //= 1 |
            .hooks //= {} |
            .hooks.sessionStart //= [] |
            .hooks.sessionEnd //= [] |
            .hooks.sessionStart |= map(select((.command // "") | contains("cursor-session-track") | not)) |
            .hooks.sessionEnd |= map(select((.command // "") | contains("cursor-session-cleanup") | not)) |
            .hooks.sessionStart += [{"command": $track}] |
            .hooks.sessionEnd += [{"command": $cleanup}]
        ' "$settings" > "$tmp"; then
            if ! chmod "$target_mode" "$tmp"; then
                rm -f "$tmp"
                echo "tmux-assistant-resurrect: cannot preserve mode for $settings; left unchanged" >&2
                return
            fi
            # Replace the target atomically. A dotfile-managed symlink and the
            # target mode survive; hard links, ownership/group, ACLs and xattrs
            # are intentionally not retained because atomic replacement requires
            # a new inode. The resolved target directory must be writable; a
            # target in a read-only dotfile store is safely left unchanged.
            if ! mv -f "$tmp" "$target"; then
                rm -f "$tmp"
                echo "tmux-assistant-resurrect: cannot update $settings; left unchanged" >&2
                return
            fi
        else
            rm -f "$tmp"
            echo "tmux-assistant-resurrect: $settings is not valid Cursor hooks JSON" >&2
            return
        fi
    fi
}

# --- OpenCode plugin ---

install_opencode_plugin() {
    local plugin_dir="$HOME/.config/opencode/plugins"
    local plugin_file="$plugin_dir/session-tracker.js"
    local source_file="${CURRENT_DIR}/hooks/opencode-session-track.js"

    mkdir -p "$plugin_dir"

    # Only update if not already correctly linked.
    if [ -L "$plugin_file" ] && [ "$(readlink "$plugin_file")" = "$source_file" ]; then
        return
    fi

    # A regular file may be a user-owned plugin with the same generic name.
    # Never silently destroy it. Symlinks are ours to refresh; -n prevents ln
    # from following a stale symlink that happens to point at a directory.
    if [ -e "$plugin_file" ] && [ ! -L "$plugin_file" ]; then
        echo "tmux-assistant-resurrect: refusing to replace existing $plugin_file" >&2
        return
    fi
    ln -sfn "$source_file" "$plugin_file"
}

# --- Run assistant hook installation ---

install_claude_hooks
install_cursor_hooks
install_opencode_plugin
