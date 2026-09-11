# Process pane metadata and a ps snapshot, then emit every detected assistant
# candidate in breadth-first process-tree order. The detect_tool() function is
# provided by lib-detect.awk.

# Peel one delimiter-free field off the front of rec (a global), leaving the
# remainder in rec. Returns "" once rec has no delimiter left.
function peel(   i, field) {
	i = index(rec, "|")
	if (i == 0) return ""
	field = substr(rec, 1, i - 1)
	rec = substr(rec, i + 1)
	return field
}

NR == FNR {
	# First file: pane data, three record types keyed by pane id:
	#   P|pane_id|pane_pid|window_index|pane_index|pane_tty|session_name
	#   C|pane_id|pane_current_path
	#   G|pane_id|session_group
	# Each ends in a field that may contain the delimiter itself, so peel the
	# fixed-shape fields and keep the rest of the line verbatim.
	rec = $0
	tag = peel()
	key = peel()
	if (tag == "" || key == "") next
	if (tag == "C") { pane_cwd[key] = rec; next }
	if (tag == "G") {
		# A pane can be listed under several sessions (any combination of
		# groups and ungrouped link-window targets), each producing its own
		# G row. An ungrouped membership's row is empty and is skipped, not
		# recorded. Distinct non-empty groups are kept in listing order, each
		# once, for the selection below to try in that order.
		if (rec != "" && !((key, rec) in pane_group_seen)) {
			pane_group_seen[key, rec] = 1
			pane_group_at[key, ++pane_group_count[key]] = rec
		}
		next
	}
	if (tag != "P") next
	pid = peel()
	win = peel()
	idx = peel()
	tty = peel()
	if (pid == "" || tty == "") next
	pane_pid[key] = pid
	pane_session[key] = rec
	pane_window[key] = win
	pane_index[key] = idx
	pane_tty[key] = tty
	# A pane listed under several sessions produces one P row per
	# membership, sharing this key. Later rows overwrite these scalars
	# (last write wins); dedup below keeps this pane to one traversal.
	if (!(key in pane_seen)) {
		pane_seen[key] = 1
		pane_list[++pane_count] = key
	}
	# Record this membership and its own window/pane index, keyed by
	# (pane_id, session_name). This is what lets the selection below use
	# the address from the one row a chosen name actually came from.
	member_win[key, rec] = win
	member_idx[key, rec] = idx
	pane_member[key, rec] = 1
	next
}

{
	# Second file: ps output (whitespace-delimited)
	pid = $1+0
	ppid = $2+0
	line = $0
	sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]*/, "", line)
	gsub(/\n/, " ", line)  # Normalize multi-line args (Linux prctl)

	proc_args[pid] = line
	# First child concatenation produces "" SUBSEP pid; the k > 0 guard in the
	# BFS loop below filters the resulting empty first element.
	child_list[ppid] = (ppid in child_list) ? child_list[ppid] SUBSEP pid : "" pid

	tool = detect_tool(line)
	if (tool != "") proc_tool[pid] = tool
}

END {
	for (i = 1; i <= pane_count; i++) {
		# pane_list holds pane ids; the BFS below roots at the pid.
		key = pane_list[i]
		root = pane_pid[key]+0
		cwd = pane_cwd[key]
		tty = pane_tty[key]
		sess = pane_session[key]
		win = pane_window[key]
		idx = pane_index[key]

		# A window can be linked across sessions that belong to different
		# groups, so one pane can carry more than one distinct group value.
		# Try each in listing order and take the first one this pane also
		# has a membership row under; a group name existing on some other
		# pane's session does not qualify. The window and pane index come
		# from that same membership row, so the saved address always names
		# one real row for this pane. No qualifying group falls back to
		# whichever membership was listed last.
		for (g = 1; g <= pane_group_count[key]; g++) {
			candidate = pane_group_at[key, g]
			if ((key, candidate) in pane_member) {
				sess = candidate
				win = member_win[key, candidate]
				idx = member_idx[key, candidate]
				break
			}
		}
		target = sess ":" win "." idx

		# Check pane PID itself (handles exec-replaced shells)
		if (root in proc_tool && proc_tool[root] != "") {
			printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n", target, proc_tool[root], root, proc_args[root], cwd, tty, sess, win, idx
		}

		# BFS through descendant processes
		for (queue_index in queue) delete queue[queue_index]
		qs = 1
		qe = 0
		if (root in child_list) {
			nc = split(child_list[root], kids, SUBSEP)
			for (j = 1; j <= nc; j++) {
				k = kids[j]+0
				if (k > 0) { queue[++qe] = k }
			}
		}

		while (qs <= qe) {
			cur = queue[qs++]+0
			if (cur in proc_tool && proc_tool[cur] != "") {
				printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n", target, proc_tool[cur], cur, proc_args[cur], cwd, tty, sess, win, idx
			}
			if (cur in child_list) {
				nc = split(child_list[cur], kids, SUBSEP)
				for (j = 1; j <= nc; j++) {
					k = kids[j]+0
					if (k > 0) { queue[++qe] = k }
				}
			}
		}
	}
}
