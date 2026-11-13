#!/usr/bin/env bash
# TPM plugin entry point for tmux-assistant-resurrect.
# TPM executes this script when the plugin is installed or tmux starts.
#
# This sets up:
# 1. tmux-resurrect + tmux-continuum settings
# 2. Post-save/restore hooks for assistant session tracking
# 3. Claude Code hooks in ~/.claude/settings.json
# 4. Cursor Agent CLI hooks in ~/.cursor/hooks.json
# 5. OpenCode session-tracker plugin in ~/.config/opencode/plugins/ (V1 or V2)
# 6. GitHub Copilot CLI support via its open session database (no hook required)
# 7. Pi and Oh My Pi support via local session-file lookup (no hook required)
# 8. Grok support via the ~/.grok/active_sessions.json registry (no hook required)
# 9. Kiro CLI support via ~/.kiro/sessions/cli/<uuid>.lock files (no hook required)

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib-fs.sh
# Fail rather than degrade: without these helpers every config writer below
# reports "cannot read mode" and installs nothing, which reads like a
# successful run. TPM discards this script's output and ignores its status, so
# the message itself lands only on a manual run or `just install-claude-hook`;
# exiting also stops the tmux set-option block below, whose hook paths would
# point into the same missing scripts/ anyway.
source "$CURRENT_DIR/scripts/lib-fs.sh" || {
    echo "tmux-assistant-resurrect: missing $CURRENT_DIR/scripts/lib-fs.sh; not installing" >&2
    exit 1
}

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

# Installer opt-outs also remove previously installed hooks. Keep dotfile
# symlinks, target modes, and unrelated settings/hooks; publish beside the
# resolved target atomically, just like Cursor's install/update path below.
remove_assistant_json_hooks() {
    local tool="$1" settings="$2" target target_mode tmp count track cleanup resolve_rc
    [ -f "$settings" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    track=$(hook_command "${CURRENT_DIR}/hooks/${tool}-session-track.sh")
    cleanup=$(hook_command "${CURRENT_DIR}/hooks/${tool}-session-cleanup.sh")
    count=$(jq --arg tool "$tool" --arg track "$track" --arg cleanup "$cleanup" '
        def owned: (.command // "") | (. == $track or . == $cleanup or (if type == "string" then
            test("^bash (\"\\$HOME\")?(\u0027/[^\u0027]*/" + $tool + "-session-(track|cleanup)\\.sh\u0027|\"/[^\"\\n]*/" + $tool + "-session-(track|cleanup)\\.sh\")$")
        else false end));
        [.hooks | if $tool == "claude" then
            .SessionStart[]?.hooks[]?, .SessionEnd[]?.hooks[]?
        else .sessionStart[]?, .sessionEnd[]? end | select(owned)] | length
    ' "$settings" 2>/dev/null) || {
        echo "tmux-assistant-resurrect: cannot inspect $settings; left unchanged" >&2
        return
    }
    [ "$count" != 0 ] || return 0
    resolve_rc=0
    target=$(resolve_symlink_target "$settings") || resolve_rc=$?
    case "$resolve_rc" in
        1 | 2)
            if [ "$resolve_rc" = 1 ]; then
                echo "tmux-assistant-resurrect: cannot read symlink chain at $settings; left unchanged" >&2
            else
                echo "tmux-assistant-resurrect: refusing deep or cyclic symlink chain at $settings" >&2
            fi
            # Keep the resolver's status rather than the echo's: the inline
            # copy this replaced propagated readlink's failure here, and a
            # bare `return` after the message would silently make it 0.
            return "$resolve_rc"
            ;;
    esac
    target_mode=$(file_mode_of "$target") || {
        echo "tmux-assistant-resurrect: cannot read mode for $settings; left unchanged" >&2
        return
    }
    tmp=$(mktemp "${target}.tmp.XXXXXX") || return
    if jq --arg tool "$tool" --arg track "$track" --arg cleanup "$cleanup" '
        def owned: (.command // "") | (. == $track or . == $cleanup or (if type == "string" then
            test("^bash (\"\\$HOME\")?(\u0027/[^\u0027]*/" + $tool + "-session-(track|cleanup)\\.sh\u0027|\"/[^\"\\n]*/" + $tool + "-session-(track|cleanup)\\.sh\")$")
        else false end));
        (if $tool == "claude" then ["SessionStart", "SessionEnd"] else ["sessionStart", "sessionEnd"] end) as $events |
        reduce $events[] as $event (. ;
            if .hooks[$event] then
                .hooks[$event] |= map(
                    if $tool == "claude" then
                        # Leave malformed/unrelated groups alone. Only a group
                        # containing one of our hooks needs to be rewritten.
                        if any(.hooks[]?; owned) then
                            .hooks |= map(select(owned | not)) |
                            select(.hooks | length > 0)
                        else . end
                    else select(owned | not) end
                )
            else . end
        )
    ' "$target" > "$tmp" && chmod "$target_mode" "$tmp" && mv -f "$tmp" "$target"; then
        return
    fi
    rm -f "$tmp"
    echo "tmux-assistant-resurrect: cannot remove hooks from $settings; left unchanged" >&2
}

install_claude_hooks() {
    local settings="$HOME/.claude/settings.json"
    local hooks_dir="${CURRENT_DIR}/hooks"
    local track_cmd cleanup_cmd

    if [ "$(tmux show-option -gqv @assistant-resurrect-claude)" = 'off' ]; then
        remove_assistant_json_hooks claude "$settings"
        return
    fi

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

    # settings.json is commonly a symlink into a dotfiles repo, and the comment
    # above says as much -- but the write below would mv onto the link path and
    # replace the link with a regular file, detaching it from the repo tracking
    # it. Resolve first and publish beside the resolved target, keeping this
    # sequence aligned with remove_assistant_json_hooks and the Cursor installer.
    local target="" target_mode="" resolve_rc
    resolve_rc=0
    target=$(resolve_symlink_target "$settings") || resolve_rc=$?
    case "$resolve_rc" in
        1)
            echo "tmux-assistant-resurrect: cannot read symlink chain at $settings; left unchanged" >&2
            return
            ;;
        2)
            echo "tmux-assistant-resurrect: refusing deep or cyclic symlink chain at $settings" >&2
            return
            ;;
    esac
    target_mode=$(file_mode_of "$target") || {
        echo "tmux-assistant-resurrect: cannot read mode for $settings; left unchanged" >&2
        return
    }

    # Install SessionStart hook, refreshing stale paths if any exist.
    # Skip only when the current command is present AND no stale copies remain.
    local has_current_track has_stale_track
    has_current_track=$(jq --arg cmd "$track_cmd" '[.hooks.SessionStart[]?.hooks[]? | select((.command // "") == $cmd)] | length' "$settings" 2>/dev/null || echo 0)
    has_stale_track=$(jq --arg cmd "$track_cmd" '[.hooks.SessionStart[]?.hooks[]? | select(((.command // "") | contains("claude-session-track")) and ((.command // "") != $cmd))] | length' "$settings" 2>/dev/null || echo 0)
    if [ "$has_current_track" = "0" ] || [ "$has_stale_track" != "0" ]; then
        local tmp
        tmp=$(mktemp "${target}.tmp.XXXXXX") || {
            echo "tmux-assistant-resurrect: cannot prepare update for $settings; left unchanged" >&2
            return
        }
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
            if ! chmod "$target_mode" "$tmp" || ! mv -f "$tmp" "$target"; then
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
        tmp=$(mktemp "${target}.tmp.XXXXXX") || {
            echo "tmux-assistant-resurrect: cannot prepare update for $settings; left unchanged" >&2
            return
        }
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
            if ! chmod "$target_mode" "$tmp" || ! mv -f "$tmp" "$target"; then
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

    if [ "$(tmux show-option -gqv @assistant-resurrect-cursor)" = 'off' ]; then
        remove_assistant_json_hooks cursor "$settings"
        return
    fi

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
        local target="" target_mode="" tmp resolve_rc
        resolve_rc=0
        target=$(resolve_symlink_target "$settings") || resolve_rc=$?
        case "$resolve_rc" in
            1)
                echo "tmux-assistant-resurrect: cannot read symlink chain at $settings; left unchanged" >&2
                return
                ;;
            2)
                echo "tmux-assistant-resurrect: refusing deep or cyclic symlink chain at $settings" >&2
                return
                ;;
        esac
        target_mode=$(file_mode_of "$target") || {
            echo "tmux-assistant-resurrect: cannot read mode for $settings; left unchanged" >&2
            return
        }
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

# Remove only a link to our tracker, including a stale checkout/TPM path. A
# regular file or a link to another plugin belongs to the user. Never follow
# the link (it may be dangling or point at a directory).
remove_opencode_plugin_link() {
    local plugin_file="$1" target
    [ -L "$plugin_file" ] || return 0
    target=$(readlink "$plugin_file") || return 0
    case "$target" in
        */hooks/opencode-session-track.js) rm -f "$plugin_file" ;;
    esac
}

# Print which OpenCode majors are on tmux's PATH, as "1", "2" or "1 2". Fails
# when there is no OpenCode, or any found command reports something other than
# a recognized 1.x or 2.x version: unknown is not evidence of a compatible API.
# The official V2 package also installs opencode2, and both commands discover
# the same global plugins, so both are probed.
opencode_plugin_majors() {
    local binary version found=false has_v1=false has_v2=false
    for binary in opencode opencode2; do
        command -v "$binary" >/dev/null 2>&1 || continue
        found=true
        version=$("$binary" --version 2>/dev/null) || return 1
        # Validate the whole response, not one line in a diagnostic dump.
        case "$version" in *$'\n'*) return 1 ;; esac
        if printf '%s\n' "$version" | grep -Eq '^(opencode )?v?1\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'; then
            has_v1=true
        elif printf '%s\n' "$version" | grep -Eq '^(opencode )?v?2\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'; then
            has_v2=true
        else
            return 1
        fi
    done
    [ "$found" = true ] || return 1
    if [ "$has_v1" = true ] && [ "$has_v2" = true ]; then
        echo '1 2'
    elif [ "$has_v2" = true ]; then
        echo 2
    else
        echo 1
    fi
}

# The V2 tracker is a plugin directory, linked as a whole. Same ownership rule
# as the V1 file: remove only a link to our tracker, never follow it.
remove_opencode2_plugin_link() {
    local plugin_dir="$1" target
    [ -L "$plugin_dir" ] || return 0
    target=$(readlink "$plugin_dir") || return 0
    case "$target" in
        */hooks/opencode2 | */hooks/opencode2/) rm -f "$plugin_dir" ;;
    esac
}

install_opencode2_plugin() {
    local plugin_link="$1" source_dir="${CURRENT_DIR}/hooks/opencode2"
    if [ -L "$plugin_link" ] && [ "$(readlink "$plugin_link")" = "$source_dir" ]; then
        return
    fi
    # Refresh our own link from a stale checkout path. Anything else at this
    # path, including a symlink to somewhere else, belongs to the user.
    remove_opencode2_plugin_link "$plugin_link"
    if [ -e "$plugin_link" ] || [ -L "$plugin_link" ]; then
        echo "tmux-assistant-resurrect: refusing to replace existing $plugin_link" >&2
        return
    fi
    mkdir -p "${plugin_link%/*}"
    ln -s "$source_dir" "$plugin_link"
}

install_opencode_plugin() {
    local plugin_dir="$HOME/.config/opencode/plugins"
    local plugin_file="$plugin_dir/session-tracker.js"
    local plugin2_link="$plugin_dir/assistant-resurrect"
    local source_file="${CURRENT_DIR}/hooks/opencode-session-track.js"
    local majors

    # This switch controls automatic plugin installation only; other assistants
    # and OpenCode's argv/database save/restore fallbacks remain independent.
    if [ "$(tmux show-option -gqv @assistant-resurrect-opencode)" = 'off' ]; then
        remove_opencode_plugin_link "$plugin_file"
        remove_opencode2_plugin_link "$plugin2_link"
        return
    fi

    # V1 and V2 need different trackers. V2 requires a default { id, setup }
    # definition and rejects the V1 file; it also runs server plugins in one
    # background server shared by every TUI, so the V2 tracker is a TUI plugin,
    # which runs in the opencode process inside the pane. V1 discovers plugin
    # files only, so it never loads the V2 directory. Unknown/dev versions are
    # not evidence of either API. --version does not load plugins or start a
    # server. Probe before the already-linked guards so an upgrade also removes
    # the tracker for the version that went away.
    if ! majors=$(opencode_plugin_majors); then
        remove_opencode_plugin_link "$plugin_file"
        remove_opencode2_plugin_link "$plugin2_link"
        if command -v opencode >/dev/null 2>&1 || command -v opencode2 >/dev/null 2>&1; then
            echo 'tmux-assistant-resurrect: OpenCode tracker requires recognized v1 or v2 versions for all available OpenCode commands; skipping plugin installation (disable with @assistant-resurrect-opencode off)' >&2
        fi
        return
    fi

    case "$majors" in
    *2*) install_opencode2_plugin "$plugin2_link" ;;
    *) remove_opencode2_plugin_link "$plugin2_link" ;;
    esac

    # V2 reports the V1 file as a failed plugin, so it is installed only when
    # every OpenCode command found is V1.
    if [ "$majors" != 1 ]; then
        remove_opencode_plugin_link "$plugin_file"
        return
    fi

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
