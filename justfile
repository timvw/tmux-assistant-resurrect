# tmux-assistant-resurrect — session persistence for AI coding assistants
# Preserves Claude Code, GitHub Copilot CLI, OpenCode, Codex CLI, Pi, Oh My Pi,
# and Grok sessions across tmux restarts.

set shell := ["bash", "-euo", "pipefail", "-c"]

repo_dir := justfile_directory()
# State directory. Never inline the path here: the hooks and the save script must
# all agree on it, so assistant_state_dir() in scripts/lib-detect.sh is the only
# definition. A copy in this file would be a fourth one, free to drift — which is
# exactly how issue #65 happened. Injected into shebang recipes, which run as one
# shell, so the assignment survives to the following lines.
_state_dir_expr := 'source "' + justfile_directory() + '/scripts/lib-detect.sh"; STATE_DIR="$(assistant_state_dir)"'

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

# Install assistant integrations (Claude/Cursor hooks + OpenCode plugin;
# Pi/Oh My Pi need no hook)
install-hooks: install-claude-hook install-cursor-hook install-opencode-plugin
    @echo "All assistant hooks installed"

# Install Claude Code hooks and OpenCode plugin via the TPM entry point.
# Delegates to tmux-assistant-resurrect.tmux (single source of truth).
install-claude-hook:
    #!/usr/bin/env bash
    set -euo pipefail
    started_server=false
    if ! tmux list-sessions &>/dev/null; then
        tmux new-session -d -s __install_hooks_tmp
        started_server=true
    fi
    bash "{{repo_dir}}/tmux-assistant-resurrect.tmux"
    if [ "$started_server" = true ]; then
        tmux kill-session -t __install_hooks_tmp 2>/dev/null || true
    fi

# Install OpenCode session-tracker plugin (delegates to .tmux entry point above)
install-opencode-plugin:
    @echo "OpenCode plugin installed via install-claude-hook (shared entry point)"

# Cursor hooks are installed by the same shared TPM entry point.
install-cursor-hook: install-claude-hook
    @echo "Cursor Agent hooks installed via install-claude-hook (shared entry point)"

# Add resurrect config to ~/.tmux.conf
configure-tmux:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{repo_dir}}/scripts/lib-fs.sh"
    conf="$HOME/.tmux.conf"
    tpm_line="run '~/.tmux/plugins/tpm/tpm'"
    begin_marker="# --- begin tmux-assistant-resurrect ---"
    end_marker="# --- end tmux-assistant-resurrect ---"

    touch "$conf"

    # ~/.tmux.conf is commonly a symlink into a dotfiles repo. Resolve it and
    # publish beside the resolved target so the link, and its mode, survive.
    conf_rc=0
    conf_target=$(resolve_symlink_target "$conf") || conf_rc=$?
    case "$conf_rc" in
        1)
            echo "tmux-assistant-resurrect: cannot read symlink chain at $conf; left unchanged" >&2
            exit 0
            ;;
        2)
            echo "tmux-assistant-resurrect: refusing deep or cyclic symlink chain at $conf" >&2
            exit 0
            ;;
    esac
    conf_mode=$(file_mode_of "$conf_target") || {
        echo "tmux-assistant-resurrect: cannot read mode for $conf; left unchanged" >&2
        exit 0
    }
    # Policy, not safety: a config the user made read-only is left alone, the
    # same call uninstall-claude-hook makes for a read-only dotfile store.
    # Nothing is lost without this guard -- the update below is assembled in a
    # caller-owned temp file and lands in one rename -- the config would simply
    # be edited against the user's wishes. (Cyclic chains do not reach the
    # refusal at all: the `touch` above fails on them first.)
    if [ ! -w "$conf_target" ]; then
        echo "tmux-assistant-resurrect: $conf_target is not writable; left unchanged" >&2
        exit 0
    fi

    # Assemble the whole update in one sibling temp file and publish it once.
    # Replacing the config per edit (strip the managed block, strip the legacy
    # line, strip the TPM line) and appending afterwards left it wearing the
    # temp file's 0600 from the first replacement until a final chmod, and a
    # failure inside that window made the next run read 0600 as the mode to
    # restore. One publish has no such window: until the rename the config is
    # exactly as the user left it, and the temp file carries the config's own
    # mode before it lands. The EXIT trap removes the working files on any
    # failure, so nothing is left beside the target either.
    tmp=$(mktemp "${conf_target}.tmp.XXXXXX")
    next=""
    trap 'rm -f "$tmp" ${next:+"$next"}' EXIT
    cp "$conf" "$tmp"

    # Rewrite the working copy through a second sibling temp (a filter cannot
    # read and write the same file). grep -v exits 1 when it drops every line,
    # which is a legitimate result here, not a failure.
    drop_lines() {
        next=$(mktemp "${conf_target}.tmp.XXXXXX")
        grep -v "$@" "$tmp" > "$next" || [ "$?" -eq 1 ]
        mv -f "$next" "$tmp"
        next=""
    }

    # Remove any existing marker block (handles re-runs and repo_dir changes).
    # NOTE: The sed range works because the marker strings contain no
    # sed-special characters (no /, *, ., etc.). If the markers ever change,
    # the sed command may need escaping.
    if grep -qF "$begin_marker" "$tmp"; then
        next=$(mktemp "${conf_target}.tmp.XXXXXX")
        sed "/$begin_marker/,/$end_marker/d" "$tmp" > "$next"
        mv -f "$next" "$tmp"
        next=""
    fi

    # Remove legacy source-file line (and its comment) from pre-marker installs
    if grep -qF "resurrect-assistants.conf" "$tmp"; then
        drop_lines -e "resurrect-assistants.conf" -e "# tmux-assistant-resurrect"
    fi

    # Capture and remove the TPM init line so we can re-add it at the very
    # end. TPM's run line must be the last line in tmux.conf — anything
    # after it won't be processed. We preserve the user's original line
    # verbatim (custom path, if-shell wrapper, etc.) instead of replacing
    # it with a hardcoded default.
    # Filter out comment lines when capturing — a commented example like
    # "# run '/old/tpm/tpm'" must not be mistaken for the real init line.
    existing_tpm_line=""
    if grep -F "tpm/tpm" "$tmp" | grep -qv '^[[:space:]]*#' 2>/dev/null; then
        existing_tpm_line=$(grep -F "tpm/tpm" "$tmp" | grep -v '^[[:space:]]*#' | tail -1)
        # Only remove non-comment lines containing tpm/tpm (preserve comments)
        drop_lines '^[^#]*tpm/tpm'
    fi

    # Write the new block with begin/end markers. The markers allow
    # unconfigure-tmux to remove exactly what we added (including plugin
    # lines) without affecting user settings outside the block.
    {
        echo ""
        echo "$begin_marker"
        echo "set -g @plugin 'tmux-plugins/tpm'"
        echo "set -g @plugin 'tmux-plugins/tmux-resurrect'"
        echo "set -g @plugin 'tmux-plugins/tmux-continuum'"
        echo "# Optional: restore terminal text in non-assistant panes after tmux restart."
        echo "# Assistant pane contents are stripped automatically by the save hook."
        echo "# set -g @resurrect-capture-pane-contents 'on'"
        echo "set -g @resurrect-hook-post-save-all \"bash '{{repo_dir}}/scripts/save-assistant-sessions.sh'\""
        echo "set -g @resurrect-hook-post-restore-all \"bash '{{repo_dir}}/scripts/restore-assistant-sessions.sh'\""
        echo "set -g @continuum-save-interval '5'"
        echo "set -g @continuum-restore 'on'"
        echo "$end_marker"
    } >> "$tmp"

    # Re-add TPM init as the very last line (required by TPM).
    # Use the user's original line if we captured one, otherwise the default.
    if [ -n "$existing_tpm_line" ]; then
        echo "$existing_tpm_line" >> "$tmp"
        tpm_message="TPM init moved to end of $conf"
    else
        echo "$tpm_line" >> "$tmp"
        tpm_message="Added TPM init to $conf"
    fi

    # Publish. The temp file takes the config's own mode first, so the rename
    # never exposes mktemp's 0600 and there is nothing to restore afterwards.
    # A mode without owner-write (a group-writable config owned by someone
    # else) is fine at this point: every append has already landed.
    chmod "$conf_mode" "$tmp"
    mv -f "$tmp" "$conf_target"
    trap - EXIT
    echo "Added tmux-assistant-resurrect settings to $conf"
    echo "$tpm_message"

# Remove all installed hooks and config
uninstall: uninstall-claude-hook uninstall-cursor-hook uninstall-opencode-plugin unconfigure-tmux
    @echo ""
    @echo "Uninstalled. You may also want to:"
    @echo "  - Remove TPM: rm -rf ~/.tmux/plugins/"
    @echo "  - Reload tmux: tmux source-file ~/.tmux.conf"

# Remove Claude Code hooks (SessionStart + SessionEnd)
uninstall-claude-hook:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{repo_dir}}/scripts/lib-fs.sh"
    settings="$HOME/.claude/settings.json"
    if [ ! -f "$settings" ]; then
        echo "No Claude settings to modify"
        exit 0
    fi
    # settings.json is commonly a symlink into a dotfiles repo. Resolve it and
    # publish beside the resolved target so the link survives; keep this
    # sequence aligned with install_claude_hooks() in tmux-assistant-resurrect.tmux
    # and with uninstall-cursor-hook below.
    resolve_rc=0
    target=$(resolve_symlink_target "$settings") || resolve_rc=$?
    case "$resolve_rc" in
        1)
            echo "tmux-assistant-resurrect: cannot read symlink chain at $settings; left unchanged" >&2
            exit 0
            ;;
        2)
            echo "tmux-assistant-resurrect: refusing deep or cyclic symlink chain at $settings" >&2
            exit 0
            ;;
    esac
    target_mode=$(file_mode_of "$target") || {
        echo "tmux-assistant-resurrect: cannot read mode for $settings; left unchanged" >&2
        exit 0
    }
    tmp=$(mktemp "${target}.tmp.XXXXXX") || {
        echo "tmux-assistant-resurrect: cannot prepare update for $settings; left unchanged" >&2
        exit 0
    }
    if ! jq '
        # Remove both hooks in one pass. contains() matching removes old
        # (unquoted) and new (quoted) forms, so an upgrade leaves no stragglers.
        (if .hooks.SessionStart then
            .hooks.SessionStart = [
                .hooks.SessionStart[] |
                # A group without a hooks array (Claude accepts that) is kept as is;
                # iterating null would abort jq and leave the managed hooks behind.
                if (.hooks | type) == "array" then
                    .hooks = [.hooks[] | select((.command // "") | contains("claude-session-track") | not)] |
                    select(.hooks | length > 0)
                else . end
            ] |
            if .hooks.SessionStart | length == 0 then del(.hooks.SessionStart) else . end
        else . end) |
        (if .hooks.SessionEnd then
            .hooks.SessionEnd = [
                .hooks.SessionEnd[] |
                # A group without a hooks array (Claude accepts that) is kept as is;
                # iterating null would abort jq and leave the managed hooks behind.
                if (.hooks | type) == "array" then
                    .hooks = [.hooks[] | select((.command // "") | contains("claude-session-cleanup") | not)] |
                    select(.hooks | length > 0)
                else . end
            ] |
            if .hooks.SessionEnd | length == 0 then del(.hooks.SessionEnd) else . end
        else . end) |
        if .hooks and (.hooks | length == 0) then del(.hooks) else . end
    ' "$settings" > "$tmp"; then
        rm -f "$tmp"
        echo "tmux-assistant-resurrect: $settings is not valid JSON; left unchanged" >&2
        exit 0
    fi
    if ! chmod "$target_mode" "$tmp"; then
        rm -f "$tmp"
        echo "tmux-assistant-resurrect: cannot preserve mode for $settings; left unchanged" >&2
        exit 0
    fi
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp"
        echo "tmux-assistant-resurrect: cannot update $settings; left unchanged" >&2
        exit 0
    fi
    # Atomic replacement requires the resolved target directory to be writable.
    # Hard links, ownership/group, ACLs and xattrs are intentionally not
    # retained; a target in a read-only dotfile store is left unchanged above.
    echo "Claude hooks removed"

# Remove Cursor Agent CLI hooks without disturbing user-owned hooks.
uninstall-cursor-hook:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{repo_dir}}/scripts/lib-fs.sh"
    settings="$HOME/.cursor/hooks.json"
    if [ ! -f "$settings" ]; then
        echo "No Cursor hooks to modify"
        exit 0
    fi
    # Keep this resolution/update sequence aligned with install_cursor_hooks()
    # in tmux-assistant-resurrect.tmux.
    resolve_rc=0
    target=$(resolve_symlink_target "$settings") || resolve_rc=$?
    case "$resolve_rc" in
        1)
            echo "tmux-assistant-resurrect: cannot read symlink chain at $settings; left unchanged" >&2
            exit 0
            ;;
        2)
            echo "tmux-assistant-resurrect: refusing deep or cyclic symlink chain at $settings" >&2
            exit 0
            ;;
    esac
    target_mode=$(file_mode_of "$target") || {
        echo "tmux-assistant-resurrect: cannot read mode for $settings; left unchanged" >&2
        exit 0
    }
    tmp=$(mktemp "${target}.tmp.XXXXXX") || {
        echo "tmux-assistant-resurrect: cannot prepare update for $settings; left unchanged" >&2
        exit 0
    }
    if ! jq '
        if .hooks.sessionStart then
            .hooks.sessionStart |= map(select((.command // "") | contains("cursor-session-track") | not)) |
            if .hooks.sessionStart | length == 0 then del(.hooks.sessionStart) else . end
        else . end |
        if .hooks.sessionEnd then
            .hooks.sessionEnd |= map(select((.command // "") | contains("cursor-session-cleanup") | not)) |
            if .hooks.sessionEnd | length == 0 then del(.hooks.sessionEnd) else . end
        else . end |
        if .hooks and (.hooks | length == 0) then del(.hooks) else . end
    ' "$settings" > "$tmp"; then
        rm -f "$tmp"
        echo "tmux-assistant-resurrect: $settings is not valid JSON; left unchanged" >&2
        exit 0
    fi
    if ! chmod "$target_mode" "$tmp"; then
        rm -f "$tmp"
        echo "tmux-assistant-resurrect: cannot preserve mode for $settings; left unchanged" >&2
        exit 0
    fi
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp"
        echo "tmux-assistant-resurrect: cannot update $settings; left unchanged" >&2
        exit 0
    fi
    # Atomic replacement requires the resolved target directory to be writable.
    # Hard links, ownership/group, ACLs and xattrs are intentionally not
    # retained; a target in a read-only dotfile store is left unchanged above.
    echo "Cursor Agent hooks removed"

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
    source "{{repo_dir}}/scripts/lib-fs.sh"
    conf="$HOME/.tmux.conf"
    if [ ! -f "$conf" ]; then
        exit 0
    fi

    # ~/.tmux.conf is commonly a symlink into a dotfiles repo. Resolve it and
    # publish beside the resolved target so the link, and its mode, survive.
    conf_rc=0
    conf_target=$(resolve_symlink_target "$conf") || conf_rc=$?
    case "$conf_rc" in
        1)
            echo "tmux-assistant-resurrect: cannot read symlink chain at $conf; left unchanged" >&2
            exit 0
            ;;
        2)
            echo "tmux-assistant-resurrect: refusing deep or cyclic symlink chain at $conf" >&2
            exit 0
            ;;
    esac
    conf_mode=$(file_mode_of "$conf_target") || {
        echo "tmux-assistant-resurrect: cannot read mode for $conf; left unchanged" >&2
        exit 0
    }

    begin_marker="# --- begin tmux-assistant-resurrect ---"
    end_marker="# --- end tmux-assistant-resurrect ---"

    # Remove the marker block (current format).
    # NOTE: sed range pattern works because markers contain no sed-special
    # characters. If markers ever change, escaping may be needed.
    if grep -qF "$begin_marker" "$conf"; then
        tmp=$(mktemp "${conf_target}.tmp.XXXXXX")
        sed "/$begin_marker/,/$end_marker/d" "$conf" > "$tmp"
        chmod "$conf_mode" "$tmp"
        mv -f "$tmp" "$conf_target"
    fi

    # Also remove legacy format (source-file + comment, pre-marker installs)
    if grep -qF "resurrect-assistants.conf" "$conf"; then
        tmp=$(mktemp "${conf_target}.tmp.XXXXXX")
        grep -v "resurrect-assistants.conf" "$conf" | grep -v "# tmux-assistant-resurrect" > "$tmp" || true
        chmod "$conf_mode" "$tmp"
        mv -f "$tmp" "$conf_target"
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

    # Cursor Agent hooks
    cursor_hooks="$HOME/.cursor/hooks.json"
    if jq -e '.hooks.sessionStart[]? | select((.command // "") | contains("cursor-session-track"))' "$cursor_hooks" >/dev/null 2>&1; then
        echo "[ok] Cursor SessionStart hook installed"
    else
        echo "[--] Cursor SessionStart hook not installed"
    fi
    if jq -e '.hooks.sessionEnd[]? | select((.command // "") | contains("cursor-session-cleanup"))' "$cursor_hooks" >/dev/null 2>&1; then
        echo "[ok] Cursor SessionEnd hook installed"
    else
        echo "[--] Cursor SessionEnd hook not installed"
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
    saved="$(resurrect_data_dir)/assistant-sessions.json"
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
# TEST_BASH overrides the interpreter (e.g. bash3.2 for compat testing).
save:
    @"${TEST_BASH:-bash}" "{{repo_dir}}/scripts/save-assistant-sessions.sh"

# Manually trigger a restore of saved assistant sessions
restore:
    @"${TEST_BASH:-bash}" "{{repo_dir}}/scripts/restore-assistant-sessions.sh"

# Show structurally plausible session-less commands observed by the save hook.
# This ledger is advisory only; entries are not authorized until explicitly
# added to the voucher with `just relaunch-add '<command>'`.
relaunch-candidates:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{repo_dir}}/scripts/lib-detect.sh"
    resurrect_dir=$(resurrect_data_dir)
    ledger="$resurrect_dir/assistant-relaunch-candidates.json"
    if [ ! -f "$ledger" ] || [ "$(jq 'length' "$ledger" 2>/dev/null || echo 0)" -eq 0 ]; then
        echo "No relaunch candidates observed yet."
        exit 0
    fi
    duration() {
        local total="$1" days hours mins secs
        days=$((total / 86400))
        hours=$(((total % 86400) / 3600))
        mins=$(((total % 3600) / 60))
        secs=$((total % 60))
        if [ "$days" -gt 0 ]; then printf '%dd%02dh' "$days" "$hours"
        elif [ "$hours" -gt 0 ]; then printf '%dh%02dm' "$hours" "$mins"
        elif [ "$mins" -gt 0 ]; then printf '%dm%02ds' "$mins" "$secs"
        else printf '%ds' "$secs"
        fi
    }
    printf '%6s %10s   %s\n' seen longest command
    while IFS=$'\t' read -r seen longest cmd; do
        printf '%6s %10s   %s\n' "$seen" "$(duration "$longest")" "$cmd"
    done < <(jq -r 'sort_by(.seen, .longest_seconds) | reverse[] | [.seen, .longest_seconds, .cmd] | @tsv' "$ledger")
    echo
    echo "Allow one: just relaunch-add 'claude agents'"

# Create the empty user-owned relaunch voucher with explanatory comments.
# Seeding never authorizes a command.
relaunch-seed:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{repo_dir}}/scripts/lib-detect.sh"
    voucher=$(relaunch_voucher_file)
    mkdir -p "$(dirname "$voucher")"
    if [ ! -f "$voucher" ]; then
        printf '%s\n' \
            '# tmux-assistant-resurrect session-less relaunch vouchers' \
            '# One canonical command per line. Comments and blank lines are ignored.' \
            "# Add observed commands with: just relaunch-add 'claude agents'" >"$voucher"
        chmod 600 "$voucher"
        echo "Created empty voucher: $voucher"
    else
        echo "Voucher already exists: $voucher"
    fi

# Authorize one canonical command already present in the advisory ledger.
# Hazard words only produce this interactive warning; save and restore never
# consult this deliberately incomplete list.
relaunch-add cmd force='':
    #!/usr/bin/env bash
    set -euo pipefail
    requested={{quote(cmd)}}
    force={{quote(force)}}
    source "{{repo_dir}}/scripts/lib-detect.sh"
    resurrect_dir=$(resurrect_data_dir)
    ledger="$resurrect_dir/assistant-relaunch-candidates.json"
    voucher=$(relaunch_voucher_file)
    if [ ! -f "$ledger" ] || ! jq -e --arg cmd "$requested" '.[] | select(.cmd == $cmd)' "$ledger" >/dev/null; then
        echo "Refusing: command is absent from $ledger" >&2
        echo "Run 'just relaunch-candidates' after a save and copy the command exactly." >&2
        exit 1
    fi
    tool=$(jq -r --arg cmd "$requested" '[.[] | select(.cmd == $cmd)] | first | .tool // empty' "$ledger")
    canonical=$(relaunch_canon "$tool" "$requested" 2>/dev/null || true)
    if [ "$canonical" != "$requested" ] || ! relaunch_shape_ok "$requested"; then
        echo "Refusing: ledger entry is not a canonical relaunch candidate." >&2
        exit 1
    fi
    hazard=0
    set -f
    for token in $requested; do
        case "${token%%=*}" in
            --dangerously-skip-permissions|--dangerously-bypass-approvals-and-sandbox|--allow-all|--yolo|--full-auto|--cloud|--environment|--worktree|--bare)
                hazard=1
                ;;
        esac
    done
    set +f
    if [ "$hazard" -eq 1 ] && [ "$force" != "--force" ]; then
        echo "Warning: command contains a permission, remote, or workspace hazard token." >&2
        echo "Review it, then rerun with a final --force argument to authorize it." >&2
        exit 1
    fi
    mkdir -p "$(dirname "$voucher")"
    touch "$voucher"
    chmod 600 "$voucher"
    if sed 's/\r$//' "$voucher" | grep -Fxq -- "$requested"; then
        echo "Already vouched: $requested"
        exit 0
    fi
    printf '\n# added %s via just relaunch-add\n%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$requested" >>"$voucher"
    echo "Vouched: $requested"

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
            # The Cursor hook keys its file by `pid` (see
            # hooks/cursor-session-track.sh), not `ppid` like Claude's.
            cursor | opencode)
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

# Run Antigravity CLI session tests (no binary or login required)
test-agy:
    @"${TEST_BASH:-bash}" "{{repo_dir}}/test/agy-unit-tests.sh"

# Real agy + tmux, private socket/home; seeded logs, no account needed.
test-agy-e2e:
    python3 "{{repo_dir}}/test/agy-e2e.py"

# Existing account/conversation; independently verifies visible old history.
test-agy-authenticated resurrect_dir session_id history_text:
    python3 {{quote(repo_dir + "/test/agy-live-lifecycle.py")}} {{quote(resurrect_dir)}} {{quote(session_id)}} {{quote(history_text)}}

# Run hermetic Grok unit tests (no Docker / no grok binary needed)
test-grok:
    @"${TEST_BASH:-bash}" "{{repo_dir}}/test/grok-unit-tests.sh"

# Run hermetic Cursor Agent CLI tests (no binary or login required)
test-cursor:
    @"${TEST_BASH:-bash}" "{{repo_dir}}/test/cursor-unit-tests.sh"

# Run hermetic saved-pane target resolution tests (no Docker / no tmux needed)
test-targets:
    @"${TEST_BASH:-bash}" "{{repo_dir}}/test/target-resolution-unit-tests.sh"

# Assert tmux's session-name and target-grammar behaviour against a real tmux.
# Runs on its own socket; skips without tmux or below tmux 3.7.
test-tmux-contract:
    @"${TEST_BASH:-bash}" "{{repo_dir}}/test/tmux-target-contract-test.sh"

# Real grouped membership, own socket; no assistant binary needed.
test-grouped-contract:
    @"${TEST_BASH:-bash}" "{{repo_dir}}/test/grouped-session-contract-test.sh"

# Real upstream save/restart/restore with a recording CLI fixture.
test-grouped-lifecycle resurrect_plugin:
    @"${TEST_BASH:-bash}" "{{repo_dir}}/test/grouped-session-lifecycle-test.sh" "{{resurrect_plugin}}"

# Run hermetic state-directory tests (no Docker / no assistant binaries needed).
# Covers the hook/save-hook rendezvous that issue #65 broke; worth running on
# macOS, where $TMPDIR really does differ between the two sides.
test-state-dir:
    @"${TEST_BASH:-bash}" "{{repo_dir}}/test/state-dir-unit-tests.sh"

# Run save and process-detection hardening tests (no assistant binaries needed)
test-save-hardening:
    @"${TEST_BASH:-bash}" "{{repo_dir}}/test/save-hardening-unit-tests.sh"

# Run hook/plugin installer and helper hardening tests (no assistant login needed)
test-plugin-hardening:
    @REQUIRE_JUST=1 bash "{{repo_dir}}/test/plugin-hardening-unit-tests.sh"

# Run hermetic Copilot session-discovery tests (no binary or login required)
test-copilot:
    @"${TEST_BASH:-bash}" "{{repo_dir}}/test/copilot-unit-tests.sh"

# Run hermetic session-less relaunch voucher tests (no tmux or CLI needed)
test-relaunch:
    @"${TEST_BASH:-bash}" "{{repo_dir}}/test/relaunch-unit-tests.sh"

# Run hermetic restore validation/quoting tests (no tmux or CLI needed)
test-restore:
    @"${TEST_BASH:-bash}" "{{repo_dir}}/test/restore-unit-tests.sh"

# Authenticated Copilot round trip: prompt -> save -> kill -> restore -> recall.
# Needs a real Copilot login and spends a few AI credits; skips without a token.
#   GH_TOKEN=$(gh auth token) just test-copilot-e2e
test-copilot-e2e:
    @"${TEST_BASH:-bash}" "{{repo_dir}}/test/copilot-e2e-authenticated.sh"

# Assert Copilot's upstream on-disk contract against the real binary.
# Needs `copilot` on PATH (skips if absent); no login required.
test-copilot-contract:
    @"${TEST_BASH:-bash}" "{{repo_dir}}/test/copilot-contract-test.sh"

# Run save-hook benchmark matrix in Docker (writes CSV + Markdown summary)
benchmark runs='7' base_repo='':
    #!/usr/bin/env bash
    set -euo pipefail
    docker build -t tmux-assistant-resurrect-test -f "{{repo_dir}}/test/Dockerfile" "{{repo_dir}}"
    mkdir -p "{{repo_dir}}/test-results"
    cmd=(bash "{{repo_dir}}/test/bench-matrix.sh" --head-repo "{{repo_dir}}" --runs "{{runs}}" --output-csv "{{repo_dir}}/test-results/benchmark.csv" --output-md "{{repo_dir}}/test-results/benchmark.md")
    if [ -n "{{base_repo}}" ]; then
        cmd+=(--base-repo "{{base_repo}}")
    fi
    "${cmd[@]}"
    cat "{{repo_dir}}/test-results/benchmark.md"
