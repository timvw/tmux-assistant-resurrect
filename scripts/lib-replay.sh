#!/usr/bin/env bash
# Shared replay option metadata and policy. Sourced by save and restore.
# shellcheck disable=SC2034  # option families use indirect variable lookup

# Tool-specific exclusions extend the global lists. Cache only the tmux reads:
# tests and callers may deliberately change DROP_FLAGS/DROP_ENV between calls.
replay_load_tool_policy() {
	local tool="$1" loaded="_REPLAY_POLICY_LOADED_$1" flags env_names
	case "$tool" in claude | cursor | copilot | opencode | codex | pi | omp | grok) ;; *) return 0 ;; esac
	[ -z "${!loaded:-}" ] || return 0
	flags=$(tmux show-option -gqv "@assistant-resurrect-${tool}-drop-flags" 2>/dev/null || true)
	env_names=$(tmux show-option -gqv "@assistant-resurrect-${tool}-drop-env" 2>/dev/null || true)
	printf -v "_REPLAY_DROP_FLAGS_$tool" '%s' "$flags"
	printf -v "_REPLAY_DROP_ENV_$tool" '%s' "$env_names"
	printf -v "$loaded" '%s' 1
}

replay_drop_names() {
	local tool="$1" kind="$2" raw specific name result="" reglob="" valid
	case "$kind" in
	flags) raw="${DROP_FLAGS:-}"; specific="_REPLAY_DROP_FLAGS_$tool" ;;
	env) raw="${DROP_ENV:-}"; specific="_REPLAY_DROP_ENV_$tool" ;;
	*) return 1 ;;
	esac
	raw="$raw ${!specific:-}"
	case "$-" in *f*) ;; *) reglob=1 ;; esac
	set -f
	# shellcheck disable=SC2086 # configuration is a whitespace-separated list
	for name in $raw; do
		valid=0
		case "$kind" in
		flags) [[ "$name" =~ ^--?[A-Za-z0-9][A-Za-z0-9_-]*$ ]] && valid=1 ;;
		env) [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && valid=1 ;;
		esac
		if [ "$valid" -eq 0 ]; then
			log "ignoring invalid @assistant-resurrect-drop-$kind entry"
			continue
		fi
		case " $result " in *" $name "*) ;; *) result="${result:+$result }$name" ;; esac
	done
	[ -z "$reglob" ] || set +f
	printf '%s\n' "$result"
}

# Alias groups are discovered from option declarations, never from help prose.
# Keep a small fallback for model aliases when the binary is not on PATH.
_discover_replay_aliases() {
	local tool="$1" cache="_REPLAY_ALIASES_$1" result fallback=""
	if [ -n "${!cache:-}" ]; then
		[ "${!cache}" = '-' ] || printf '%s\n' "${!cache}"
		return 0
	fi
	case "$tool" in
	opencode | codex) fallback='-m=--model' ;;
	claude) fallback='--allowed-tools=--allowedTools --disallowed-tools=--disallowedTools' ;;
	pi) fallback='-t=--tools' ;;
	esac
	result=$(_tool_help "$tool" | awk '
		/^[[:space:]]+-/ {
			line=$0; sub(/^[[:space:]]+/, "", line)
			sub(/[[:space:]][[:space:]].*$/, "", line)
			sub(/[<\[].*$/, "", line)
			n=split(line, fields, /[[:space:],]+/); canonical=""
			for(i=1;i<=n;i++) if(fields[i] ~ /^--[A-Za-z0-9][A-Za-z0-9_-]*$/) {canonical=fields[i]; break}
			if(canonical=="") next
			for(i=1;i<=n;i++) if(fields[i] ~ /^--?[A-Za-z0-9][A-Za-z0-9_-]*$/ && fields[i]!=canonical)
				printf "%s=%s ", fields[i], canonical
		}')
	result="${result}${fallback}"
	printf -v "$cache" '%s' "${result:--}"
	printf '%s\n' "$result"
}

_replay_canonical_flag() {
	local flag="$1" aliases=" $2 " tail
	case "$aliases" in
	*" $flag="*) tail="${aliases#*" $flag="}"; printf '%s\n' "${tail%% *}" ;;
	*) printf '%s\n' "$flag" ;;
	esac
}

# A required value can itself start with '-'. Optional-value flags instead
# leave a following option alone. Preserve that distinction before exclusions
# can turn an option's value into an active replay flag.
_discover_replay_optional_flags() {
	local tool="$1" cache="_REPLAY_OPTIONAL_$1" result fallback=""
	if [ -n "${!cache:-}" ]; then
		[ "${!cache}" = '-' ] || printf '%s\n' "${!cache}"
		return 0
	fi
	case "$tool" in
	claude) fallback='--debug -d --remote-control --prompt-suggestions --worktree -w --cloud --teleport' ;;
	copilot) fallback='--share' ;;
	esac
	result=$(_tool_help "$tool" | awk '
		/^[[:space:]]+-/ {
			line=$0; sub(/^[[:space:]]+/, "", line)
			sub(/[[:space:]][[:space:]].*$/, "", line)
			if(line !~ /\[/ || line ~ /\[(boolean|string|number|array)\]/) next
			sub(/\[.*$/, "", line)
			n=split(line, fields, /[[:space:],=]+/)
			for(i=1;i<=n;i++) if(fields[i] ~ /^--?[A-Za-z0-9][A-Za-z0-9_-]*$/)
				printf "%s ", fields[i]
		}')
	result="$result$fallback"
	printf -v "$cache" '%s' "${result:--}"
	printf '%s\n' "$result"
}

replay_flag_is_dropped() {
	local tool="$1" flag="$2" names aliases name
	replay_load_tool_policy "$tool"
	names=$(replay_drop_names "$tool" flags)
	[ -n "$names" ] || return 1
	aliases=$(_discover_replay_aliases "$tool")
	flag=$(_replay_canonical_flag "$flag" "$aliases")
	for name in $names; do
		[ "$(_replay_canonical_flag "$name" "$aliases")" != "$flag" ] || return 0
	done
	return 1
}

# Receives real argv elements. Emit NUL-delimited output so a multi-word value
# stays one value until the existing exact-argv sanitizers have dealt with it.
# Never alter the first positional or anything following it: those consumers
# own prompt handling, including their permission-loss checks on that tail.
replay_filter_argv() {
	local tool="$1" names aliases drop="" name value_flags variadic_flags="" optional_flags
	shift
	replay_load_tool_policy "$tool"
	names=$(replay_drop_names "$tool" flags)
	if [ -z "$names" ]; then
		[ "$#" -eq 0 ] || printf '%s\0' "$@"
		return 0
	fi
	aliases=$(_discover_replay_aliases "$tool")
	for name in $names; do drop="$drop $(_replay_canonical_flag "$name" "$aliases")"; done
	drop="$drop "
	value_flags=" $(_discover_option_value_flags "$tool") "
	optional_flags=" $(_discover_replay_optional_flags "$tool") "
	case "$tool" in
	claude) variadic_flags=" $(_claude_variadic_flags) " ;;
	copilot) variadic_flags=" $(_copilot_variadic_flags) " ;;
	esac
	local token flag canonical remove value_count attached
	while [ "$#" -gt 0 ]; do
		token="$1"; shift
		case "$token" in
		-- | [!-]* | '')
			printf '%s\0' "$token"
			[ "$#" -eq 0 ] || printf '%s\0' "$@"
			return 0
			;;
		esac
		flag="${token%%=*}"
		attached=0
		case "$token" in
		--* | *=*) ;;
		-??*)
			name="${token:0:2}"
			case "$value_flags" in *" $name "*) flag="$name"; attached=1 ;; esac
			;;
		esac
		canonical=$(_replay_canonical_flag "$flag" "$aliases")
		remove=0
		case "$drop" in *" $canonical "*) remove=1 ;; esac
		[ "$remove" -eq 1 ] || printf '%s\0' "$token"
		[ "$attached" -eq 0 ] || continue
		case "$token" in *=*) continue ;; esac
		value_count=0
		case "$value_flags" in *" $flag "*) value_count=1 ;; esac
		case "$variadic_flags" in *" $flag "*) value_count=-1 ;; esac
		while [ "$value_count" -ne 0 ] && [ "$#" -gt 0 ]; do
			case "$1" in
			-*)
				[ "$value_count" -ne -1 ] || break
				case "$optional_flags" in *" $flag "*) break ;; esac
				;;
			esac
			[ "$remove" -eq 1 ] || printf '%s\0' "$1"
			shift
			[ "$value_count" -ne 1 ] || value_count=0
		done
	done
}

replay_filter_exact_argv() {
	local tool="$1" token
	local -a argv=()
	while IFS= read -r -d '' token; do argv[${#argv[@]}]="$token"; done
	[ "${#argv[@]}" -gt 0 ] || return 0
	replay_filter_argv "$tool" "${argv[@]}"
}

replay_filter_cli_args() {
	local tool="$1" args="$2" names reglob="" token result=""
	replay_load_tool_policy "$tool"
	names=$(replay_drop_names "$tool" flags)
	if [ -z "$names" ]; then printf '%s\n' "$args"; return 0; fi
	# Establish the prompt boundary before removing a boolean or its neighbor.
	args=$(_drop_positional_args "$tool" "$args")
	case "$-" in *f*) ;; *) reglob=1 ;; esac
	set -f
	# shellcheck disable=SC2086 # saved cli_args are already whitespace-joined
	set -- $args
	[ -z "$reglob" ] || set +f
	while IFS= read -r -d '' token; do result="${result:+$result }$token"; done < <(replay_filter_argv "$tool" "$@")
	printf '%s\n' "$result"
}

replay_filter_env() {
	local tool="$1" env_json="$2" names
	replay_load_tool_policy "$tool"
	names=$(replay_drop_names "$tool" env)
	if [ -z "$names" ] || [ "$env_json" = null ]; then printf '%s\n' "$env_json"; return 0; fi
	printf '%s\n' "$env_json" | jq -c --arg names "$names" 'delpaths($names | split(" ") | map([.]))'
}

# Copilot's variadic options -- the ones whose --help spelling ends in `...`,
# e.g. `--allow-tool[=tools...]`. They legitimately occupy several argv tokens.
SESSION_VARIADIC_FALLBACK_copilot="--allow-tool --allow-url --available-tools --deny-tool --deny-url --excluded-tools --secret-env-vars"
SESSION_VARIADIC_FALLBACK_claude="--add-dir --allowedTools --allowed-tools --betas --disallowedTools --disallowed-tools --file --mcp-config --tools"

_claude_variadic_flags() {
	local cached="${_CLAUDE_VARIADIC_FLAGS:-}"
	if [ -n "$cached" ]; then
		[ "$cached" = "-" ] || echo "$cached"
		return 0
	fi

	local help_out result=""
	help_out=$(_tool_help claude)
	if [ -n "$help_out" ]; then
		result=$(printf '%s\n' "$help_out" |
			awk '
				match($0, /<[^>]*\.\.\.[^>]*>/) {
					prefix = substr($0, 1, RSTART - 1)
					# A scalar option may precede the variadic one in help prose.
					# Keep only the alias group after its last completed metavar.
					sub(/^.*>[[:space:],]*/, "", prefix)
					while (match(prefix, /--[A-Za-z][A-Za-z0-9-]*/)) {
						print substr(prefix, RSTART, RLENGTH)
						prefix = substr(prefix, RSTART + RLENGTH)
					}
				}' | sort -u | tr '\n' ' ') || true
		result="${result% }"
	fi
	result=$(printf '%s\n%s\n' "$result" "$SESSION_VARIADIC_FALLBACK_claude" |
		tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')
	result="${result% }"

	printf -v _CLAUDE_VARIADIC_FLAGS '%s' "${result:--}"
	[ -n "$result" ] && echo "$result"
	return 0
}

_copilot_variadic_flags() {
	local cached="${_COPILOT_VARIADIC_FLAGS:-}"
	if [ -n "$cached" ]; then
		[ "$cached" = "-" ] || echo "$cached"
		return 0
	fi

	local help_out result=""
	help_out=$(_tool_help copilot)
	if [ -n "$help_out" ]; then
		result=$(echo "$help_out" |
			grep -E '^[[:space:]]+(-[a-zA-Z],[[:space:]]+)?--[a-z][-a-z]*\[=[^]]*\.\.\.\]' |
			grep -oE -- '--[a-z][-a-z]*' | sort -u | tr '\n' ' ')
		result="${result% }"
	fi
	[ -n "$result" ] || result="$SESSION_VARIADIC_FALLBACK_copilot"

	printf -v _COPILOT_VARIADIC_FLAGS '%s' "${result:--}"
	[ -n "$result" ] && echo "$result"
	return 0
}

# Run `<tool> --help`, neutralizing any side effects the tool performs on
# startup. The save hook fires every few minutes, so a probe that phones home is
# not acceptable: Copilot's native binary runs its auto-updater unless told not
# to. Per-tool overrides live in HELP_PROBE_ENV_<tool> (word-split on purpose).
HELP_PROBE_ENV_copilot="COPILOT_AUTO_UPDATE=false"

# Cached per tool in _TOOL_HELP_<tool>: several discovery passes read the same
# help text, and the callers run in a $() subshell per pane.
# shellcheck disable=SC2178,SC2128  # out is a plain string; printf -v writes to a dynamic name
_tool_help() {
	local tool="$1"
	local cache_var="_TOOL_HELP_${tool}"
	local cached="${!cache_var:-}"
	if [ -n "$cached" ]; then
		[ "$cached" = "-" ] || printf '%s\n' "$cached"
		return 0
	fi

	local probe_env_var="HELP_PROBE_ENV_${tool}"
	local probe_env="${!probe_env_var:-}"
	local out="" help_binary="$tool"
	if [ "$tool" = "cursor" ]; then
		# Prefer the Cursor-specific compatibility name. A generic unrelated
		# `agent` on PATH must never be executed by a periodic save hook.
		if command -v cursor-agent >/dev/null 2>&1; then
			help_binary="cursor-agent"
		else
			help_binary=""
		fi
	fi
	if [ -n "$probe_env" ]; then
		# shellcheck disable=SC2086  # deliberate split into env KEY=VAL args
		[ -z "$help_binary" ] || out=$(env $probe_env "$help_binary" --help 2>/dev/null) || out=""
	elif [ -n "$help_binary" ]; then
		out=$("$help_binary" --help 2>/dev/null) || out=""
	fi

	printf -v "$cache_var" '%s' "${out:--}"
	[ -n "$out" ] && printf '%s\n' "$out"
	return 0
}

# Static value-taking option fallbacks for when a running assistant is not on
# the save hook's PATH. Dynamic discovery below is authoritative when --help is
# available; these keep common replay settings intact in the degraded path.
#
# claude's --system-prompt-file and --append-system-prompt-file are the
# exception to "dynamic discovery is authoritative": they are accepted but
# absent from the option list in `claude --help`, named only in the prose of
# --setting-sources. Discovery cannot see them even with --help available, so
# the argv filter reads them as booleans, takes the path for the first
# positional, and drops it along with the whole tail. Restore then replays a
# bare --append-system-prompt-file and claude consumes the next flag as its
# filename ("Append system prompt file not found: --model"). Pinning them here
# is load-bearing on the normal path, not just the degraded one.
OPTION_VALUE_FLAGS_FALLBACK_claude="--add-dir --agent --agents --allowedTools --allowed-tools --append-system-prompt --append-system-prompt-file --autocompact --betas --cloud -d --debug --debug-file --disallowedTools --disallowed-tools --effort --environment --fallback-model --file --input-format --json-schema --max-budget-usd --mcp-config --model -n --name --output-format --permission-mode --plugin-dir --plugin-url --prompt-suggestions --remote-control --remote-control-session-name-prefix --setting-sources --settings --system-prompt --system-prompt-file --teleport --tools -w --worktree"
OPTION_VALUE_FLAGS_FALLBACK_copilot="--add-dir --add-github-mcp-tool --add-github-mcp-toolset --additional-mcp-config --agent --allow-tool --allow-url --attachment --available-tools --bash-env -C --context --deny-tool --deny-url --disable-mcp-server --effort --reasoning-effort --excluded-tools --extension-sdk-path --log-dir --log-level --max-ai-credits --max-autopilot-continues --mode --model --mouse --output-format --plugin-dir --secret-env-vars --share --stream"
OPTION_VALUE_FLAGS_FALLBACK_opencode="--log-level --port --hostname --mdns-domain --cors -m --model --prompt --agent --replay-limit"
OPTION_VALUE_FLAGS_FALLBACK_codex="-c --config --enable --disable --remote --remote-auth-token-env -i --image -m --model --local-provider -p --profile -s --sandbox -C --cd --add-dir -a --ask-for-approval"
OPTION_VALUE_FLAGS_FALLBACK_pi="--provider --model --api-key --system-prompt --append-system-prompt --mode -n --name --models -t --tools -xt --exclude-tools --thinking -e --extension --skill --prompt-template --theme --use-theme --export --list-models --tui-mode"
OPTION_VALUE_FLAGS_FALLBACK_omp="--model --smol --slow --plan --prewalk-into --plan-yolo-into --provider --api-key --system-prompt --append-system-prompt --profile --alias --cwd --mode --config --session-dir --models --tools --thinking --hook -e --extension --skills --export --max-time --approval-mode --plugin-dir"
OPTION_VALUE_FLAGS_FALLBACK_grok="--model --effort --cwd"
OPTION_VALUE_FLAGS_FALLBACK_cursor="--header -e --endpoint --output-format --mode --model --sandbox --workspace --add-dir --plugin-dir -w --worktree --worktree-base"

# Discover options that accept a separate value from the top-level --help.
# Commander/clap-style help marks values as <...> or [...]; yargs-style help
# uses type annotations such as [string], [number], or [array], sometimes on a
# continuation line. Emit both long and short spellings so the argv filter can
# distinguish an option value from a positional prompt.
_discover_option_value_flags() {
	local tool="$1"
	local cache_var="_OPTION_VALUE_FLAGS_${tool}"
	local cached="${!cache_var:-}"
	if [ -n "$cached" ]; then
		[ "$cached" = "-" ] || echo "$cached"
		return 0
	fi

	local fallback_var="OPTION_VALUE_FLAGS_FALLBACK_${tool}"
	local fallback="${!fallback_var:-}"
	local help_out result=""
	help_out=$(_tool_help "$tool") || true
	if [ -n "$help_out" ]; then
		result=$(printf '%s\n' "$help_out" | awk '
			function flush() {
				if (head == "") return
				decl = head
				sub(/^[[:space:]]+/, "", decl)
				sub(/[[:space:]][[:space:]].*$/, "", decl)
				if (decl ~ /<[^>]+>/ ||
				    (decl ~ /\[[^]]+\]/ && decl !~ /\[boolean\]/) ||
				    entry ~ /\[(string|number|array)\]/) {
					print decl
				}
				head = ""
				entry = ""
			}
			/^[[:space:]]+(-[A-Za-z][A-Za-z0-9-]*[[:space:],]|--[A-Za-z][A-Za-z0-9-]*)/ {
				flush()
				head = $0
				entry = $0
				next
			}
			{ if (head != "") entry = entry "\n" $0 }
			END { flush() }
		' | grep -oE -- '--[A-Za-z][A-Za-z0-9-]*|(^|[[:space:],])-[A-Za-z][A-Za-z0-9-]*' |
			sed -E 's/^[[:space:],]+//') || true
	fi

	# Help output can be partial (and some supported options are hidden), so
	# supplement discovery with the pinned safe fallback just as session-flag
	# discovery does.
	result=$(printf '%s\n%s\n' "$result" "$fallback" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')
	result="${result% }"
	printf -v "$cache_var" '%s' "${result:--}"
	[ -n "$result" ] && echo "$result"
	return 0
}

# Remove positional argv while retaining values belonging to known options.
# Once the first positional is seen, discard it and the entire remaining tail:
# a prompt can contain flag-looking words that must never become replayed flags.
_drop_positional_args() {
	local tool="$1" args="$2"
	# Bash 3.2 treats an empty array expansion as an unbound variable under
	# nounset.  Avoid constructing/iterating that array when there is no argv.
	case "$args" in
	*[![:space:]]*) ;;
	*) return 0 ;;
	esac
	local value_flags
	value_flags=" $(_discover_option_value_flags "$tool") "
	local variadic_flags=""
	case "$tool" in
	claude) variadic_flags=" $(_claude_variadic_flags) " ;;
	copilot) variadic_flags=" $(_copilot_variadic_flags) " ;;
	esac

	# Word-split with pathname expansion disabled: argv is data, so values such
	# as '*' must never expand against the save hook's working directory.
	local reglob=""
	case "$-" in
	*f*) ;;
	*) reglob=1 ;;
	esac
	set -f
	# shellcheck disable=SC2206  # deliberate word-split of flattened argv
	local -a words=($args)
	[ -n "$reglob" ] && set +f

	local -a out=()
	local word flag="" expects_value=0 variadic=0
	for word in "${words[@]}"; do
		case "$word" in
		-*)
			out[${#out[@]}]="$word"
			flag="${word%%=*}"
			expects_value=0
			variadic=0
			case "$word" in
			*=*) ;;
			*)
				case "$value_flags" in
				*" $flag "*) expects_value=1 ;;
				esac
				case "$variadic_flags" in
				*" $flag "*) variadic=1 ;;
				esac
				;;
			esac
			;;
		*)
			if [ "$expects_value" -eq 1 ]; then
				out[${#out[@]}]="$word"
				if [ "$variadic" -eq 0 ]; then
					expects_value=0
					flag=""
				fi
			else
				break
			fi
			;;
		esac
	done

	[ "${#out[@]}" -gt 0 ] && echo "${out[*]}"
	return 0
}
