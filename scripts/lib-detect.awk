# Shared awk assistant detector.
#
# Loaded by save-assistant-sessions.sh together with its process-tree program.
# Tests set classify_only=1 to exercise this exact production implementation
# without maintaining another copy of the patterns.

function detect_tool(line) {
	# Whole-array `delete word` is an extension, not POSIX awk. Clear entries
	# individually so repeated classifications also work with older BSD awk.
	for (word_index in word) delete word[word_index]
	sub(/^[ \t]+/, "", line)
	n = split(line, word, /[ \t]+/)
	if (n < 1) return ""

	first = word[1]
	sub(/^.*\//, "", first)
	tool_at = 1
	if (first == "claude" || first == "copilot" || first == "opencode" ||
	    first == "codex" || first == "pi" || first == "omp" || first == "grok") {
		tool = first
	} else if (first == "cursor-agent") {
		tool = "cursor"
	} else if (first == "agent" && word[2] == "--use-system-ca" && word[3] ~ /\/index\.js$/) {
		tool = "cursor"
	} else if (first == "node" || first == "nodejs" || first == "bun" ||
	           first == "deno" || first == "bash" || first == "sh" ||
	           first == "dash" || first == "ksh" || first == "zsh") {
		if (n < 2) return ""
		tool = word[2]
		sub(/^.*\//, "", tool)
		if (tool == "cursor-agent") {
			tool = "cursor"
		} else if (tool == "agent" && word[3] == "--use-system-ca" && word[4] ~ /\/index\.js$/) {
			tool = "cursor"
		} else if (!(tool == "claude" || tool == "copilot" || tool == "opencode" ||
		             tool == "codex" || tool == "pi" || tool == "omp" || tool == "grok")) return ""
		tool_at = 2
	} else {
		return ""
	}

	if (tool == "opencode" && word[tool_at + 1] == "run") return ""
	if (tool == "omp" && word[tool_at + 1] ~ /^__omp_worker_/) return ""
	return tool
}

classify_only {
	detected_tool = detect_tool($0)
	if (detected_tool != "") print detected_tool
	next
}
