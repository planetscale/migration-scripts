#!/bin/bash
set -eo pipefail

usage() {
    cat <<'EOF'
Usage: ~/check-log-errors.sh [options] [LOGFILE]

Groups the ERROR and FATAL lines in a pgcopydb migration log into categories.
Prints a count, the first and last time, and the top messages for each category.

LOGFILE defaults to $MIGRATION_DIR/migration.log, then the newest ~/migration_*/migration.log.

Options:
  --since "YYYY-MM-DD HH:MM"  Read only lines at or after this time
  --warnings                  Also include WARN lines
  --top <n>                   Messages to show per category (default 3)
  --show <text>               Print every log line for the categories that contain <text>
  -h, --help                  Show this help

Exit codes: 0 = no errors, 1 = errors found, 3 = log not readable.
EOF
}

SINCE=""
WARNINGS=0
TOP=3
SHOW=""
LOGFILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="${2:?--since needs a value}"; shift 2 ;;
        --warnings) WARNINGS=1; shift ;;
        --top) TOP="${2:?--top needs a value}"; shift 2 ;;
        --show) SHOW="${2:?--show needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "ERROR: unknown option $1" >&2; usage >&2; exit 3 ;;
        *) LOGFILE="$1"; shift ;;
    esac
done

if ! [[ "$TOP" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --top must be a number" >&2
    exit 3
fi

if [ -z "$LOGFILE" ]; then
    if [ -n "${MIGRATION_DIR:-}" ]; then
        LOGFILE="$MIGRATION_DIR/migration.log"
    else
        LATEST_DIR=$(ls -dt ~/migration_*/ 2>/dev/null | head -1 || true)
        LOGFILE="${LATEST_DIR%/}/migration.log"
    fi
fi

if [ ! -r "$LOGFILE" ]; then
    echo "ERROR: cannot read log file \"$LOGFILE\"" >&2
    echo "  Pass the path, or set MIGRATION_DIR=~/migration_YYYYMMDD-HHMMSS" >&2
    exit 3
fi

awk -v since="$SINCE" -v warnings="$WARNINGS" -v top="$TOP" -v show="$SHOW" -v logfile="$LOGFILE" '
function sig(s) {
    gsub(/"[^"]*"/, "\"...\"", s)
    gsub(/[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]+/, "<hex>", s)
    gsub(/[0-9A-Fa-f]+\/[0-9A-Fa-f]+/, "X/X", s)
    gsub(/[0-9]+/, "N", s)
    gsub(/[ \t]+/, " ", s)
    sub(/^ /, "", s)
    sub(/ $/, "", s)
    if (s == "") s = "(empty message)"
    if (length(s) > 110) s = substr(s, 1, 107) "..."
    return s
}

function classify(msg, file, state,    m) {
    m = tolower(msg)
    if (m ~ /replication slot .* does not exist/) return "slot: missing"
    if (m ~ /cannot read from logical replication slot|can no longer get changes from replication slot|has been invalidated|requested wal segment .* has already been removed|max_slot_wal_keep_size/) return "slot: invalidated / WAL removed"
    if (m ~ /replication slot .* is active for pid/) return "slot: in use"
    if (m ~ /all replication slots are in use|exceeds max_wal_senders|max_replication_slots/) return "slot: limit reached"
    if (m ~ /replication slot/) return "slot: other"
    if (m ~ /replication origin/) return "replication origin"
    if (m ~ /replication stream|replication command|could not receive data from wal stream|terminating walsender|replication timeout|failed to consume from the stream/) return "cdc: stream"
    if (m ~ /see above for details/) return "pgcopydb summary"
    if (m ~ /canceling statement due to (statement|lock) timeout|deadlock detected|could not obtain lock|lock timeout/ || state ~ /^(57014|55P03|40P01)$/) return "timeout / lock"
    if (m ~ /no space left|could not extend file|out of memory|too many connections|remaining connection slots/ || state ~ /^53/) return "resources"
    if (m ~ /server closed the connection|could not connect|connection refused|connection lost|connection to server|ssl syscall|ssl error|terminating connection|could not translate host|timeout expired|no connection to the server|failed to connect|connection exception/ || state ~ /^(08|57P0)/) return "connection"
    if (m ~ /permission denied|must be owner|must be superuser|must be member|privilege/ || state == "42501") return "permission"
    if (m ~ /extension|control file/) return "extension"
    if (m ~ /duplicate key|violates|invalid input syntax|out of range|value too long|null value in column/ || state ~ /^(22|23)/) return "data / constraint"
    if (m ~ /already exists/ || state ~ /^(42P07|42710|42723)$/) return "already exists"
    if (m ~ /does not exist/ || state ~ /^(42704|42P01|42883|3F000)$/) return "missing object"
    if (m ~ /exit code|exited with|has exited|has terminated|terminating all processes|sub-process|signal/) return "process exit"
    if (file ~ /^(ld_|follow)/) return "cdc: apply / transform"
    return "other"
}

function record(cat, state, reason, raw,    s, k) {
    if (!(cat in count)) { ncat++; cats[ncat] = cat; first[cat] = ts }
    count[cat]++
    last[cat] = ts
    s = (state != "") ? state " " sig(reason) : sig(reason)
    k = cat SUBSEP s
    if (!(k in sigcount)) { nsig[cat]++; sigs[cat, nsig[cat]] = s }
    sigcount[k]++
    showing = (show != "" && index(tolower(cat), tolower(show)) > 0)
    shown_pid = pid
    if (showing) print raw
}

function show_continuation() {
    if (showing && pid == shown_pid) print $0
}

function first_index(s, a, b, c, d, f,    i, best) {
    best = 0
    i = index(s, a); if (i > 0 && (best == 0 || i < best)) best = i
    i = index(s, b); if (i > 0 && (best == 0 || i < best)) best = i
    i = index(s, c); if (i > 0 && (best == 0 || i < best)) best = i
    i = index(s, d); if (i > 0 && (best == 0 || i < best)) best = i
    i = index(s, f); if (i > 0 && (best == 0 || i < best)) best = i
    return best
}

function last_toc_type(s,    i, k) {
    k = 0
    while ((i = index(substr(s, k + 1), "from TOC entry ")) > 0) k += i
    return (k > 0) ? toc_object_type(substr(s, k)) : ""
}

function toc_object_type(s,    i, n, w, t) {
    sub(/^from TOC entry [0-9]+; [0-9]+ [0-9]+ /, "", s)
    n = split(s, w, " ")
    t = ""
    for (i = 1; i <= n; i++) {
        if (w[i] !~ /^[A-Z]+$/) break
        t = (t == "") ? w[i] : t " " w[i]
    }
    return (t == "") ? "unknown" : t
}

function command_type(s,    i, n, w, t, k) {
    sub(/^[ \t]+/, "", s)
    if (s ~ /^CREATE POLICY/) return "POLICY"
    if (s ~ /FOREIGN KEY/) return "FK CONSTRAINT"
    if (s ~ /ADD CONSTRAINT/) return "CONSTRAINT"
    if (s ~ /ROW LEVEL SECURITY/) return "ROW SECURITY"
    if (s ~ /OWNER TO/) return "OWNER"
    if (s ~ /^ALTER DEFAULT PRIVILEGES/) return "DEFAULT ACL"
    if (s ~ /^(GRANT|REVOKE)/) return "ACL"
    if (s ~ /^COMMENT ON/) return "COMMENT"
    if (s ~ /^SELECT pg_catalog\.setval/) return "SEQUENCE SET"
    sub(/^(CREATE|ALTER|DROP) +/, "", s)
    sub(/^OR REPLACE +/, "", s)
    sub(/^(UNIQUE|CONSTRAINT|TRUSTED|PROCEDURAL) +/, "", s)
    n = split(s, w, " ")
    t = ""
    k = 0
    for (i = 1; i <= n && k < 2; i++) {
        if (w[i] !~ /^[A-Z]+$/) break
        if (w[i] ~ /^(ONLY|IF|NOT|EXISTS|ON)$/) break
        t = (t == "") ? w[i] : t " " w[i]
        k++
    }
    return (t == "") ? "other" : t
}

function block_raw(p, s, e,    i, out) {
    out = ""
    while (bptr < bn[p] && boff[bptr] + length(bl[p, bptr]) <= s) bptr++
    for (i = bptr; i <= bn[p] && boff[i] < e; i++) {
        out = (out == "") ? braw[p, i] : out "\n" braw[p, i]
        if (bts_first == "") bts_first = bts[p, i]
    }
    return out
}

function flush_block(p,    n, i, j, J, parts, np, start, T, s, e, c, reason, cut, type, raw, toc, toc_s, saved_ts, copy, anchor) {
    n = bn[p]
    if (n == 0) return
    J = ""
    for (i = 1; i <= n; i++) {
        boff[i] = length(J) + 1
        J = J bl[p, i]
    }
    copy = J
    ncommand += gsub(/Command was:/, "&", copy)

    if (index(J, "could not execute query:") > 0) {
        anchor = "could not execute query:"
    } else {
        anchor = "pg_restore: "
    }
    np = split(J, parts, anchor)
    start = length(parts[1]) + 1
    toc = (anchor == "pg_restore: ") ? "" : last_toc_type(parts[1])
    toc_s = 1
    saved_ts = ts
    bptr = 1
    for (j = 2; j <= np; j++) {
        T = parts[j]
        s = start
        e = start + length(anchor) + length(T)
        start = e
        if (anchor == "pg_restore: ") {
            if (T ~ /^from TOC entry /) {
                toc = toc_object_type(T)
                toc_s = s
                continue
            }
            if (T !~ /^error:/ && !(warnings && T ~ /^warning:/ && T !~ /errors ignored on restore/)) continue
        }

        c = index(T, "Command was:")
        reason = (c > 0) ? substr(T, 1, c - 1) : T
        cut = first_index(reason, "DETAIL:", "HINT:", "LINE ", "CONTEXT:", "pg_restore:")
        if (cut > 0) reason = substr(reason, 1, cut - 1)
        sub(/^(error|warning): */, "", reason)
        sub(/^ *(ERROR|FATAL|WARNING): */, "", reason)

        if (T ~ /^warning:/) type = "warning"
        else if (c > 0) type = command_type(substr(T, c + 12))
        else if (toc != "") type = toc
        else type = "other"

        bts_first = ""
        raw = block_raw(p, (toc != "" && anchor == "pg_restore: ") ? toc_s : s, e)
        ts = (bts_first != "") ? bts_first : saved_ts
        pid = p
        record("restore: " type, "", reason, raw)
        toc = (anchor == "pg_restore: ") ? "" : last_toc_type(T)
    }
    ts = saved_ts
    for (i = 1; i <= n; i++) {
        delete bl[p, i]
        delete braw[p, i]
        delete bts[p, i]
    }
    delete bn[p]
}

function message_after_file(rest, file,    after, pad) {
    after = substr(rest, length(file) + 1)
    if (length(file) < 25) {
        pad = 25 - length(file) + 1
        if (substr(after, 1, pad) ~ /^ +$/) return substr(after, pad + 1)
    }
    return substr(after, 2)
}

BEGIN { ncat = 0; lines = 0; nerr = 0; nfatal = 0; nwarn = 0; ignored = ""; runs = 0; showing = 0; ncommand = 0 }

/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / {
    if (since != "" && substr($1 " " $2, 1, length(since)) < since) next
    lines++
    ts = substr($1 " " $2, 1, 19)
    pid = $3
    level = $4

    if (index($0, "Running pgcopydb version") > 0) runs++

    if (level == "ERROR") nerr++
    else if (level == "FATAL") nfatal++
    else if (level == "WARN") nwarn++

    if (index($0, "errors ignored on restore:") > 0) {
        ignored = $0
        sub(/.*errors ignored on restore: */, "", ignored)
    }

    file = ""
    rest = $0
    sub(/^[^ ]+ [^ ]+ [^ ]+ [^ ]+ +/, "", rest)
    msg = rest
    if (rest ~ /^[A-Za-z0-9_.-]+\.c:[0-9]+ /) {
        file = rest
        sub(/ .*/, "", file)
        msg = message_after_file(rest, file)
    }

    if (file ~ /^string_utils\.c/ && (level == "ERROR" || level == "FATAL" || level == "WARN") && msg !~ /^(pg_dump|vacuumdb|psql):/) {
        bn[pid]++
        bl[pid, bn[pid]] = msg
        braw[pid, bn[pid]] = $0
        bts[pid, bn[pid]] = ts
        next
    }

    if (pid in bn) flush_block(pid)

    if (level != "ERROR" && level != "FATAL" && !(warnings && level == "WARN")) next

    state = ""
    if (match(msg, /^\[(SOURCE|TARGET) [0-9]+\] /)) {
        msg = substr(msg, RLENGTH + 1)
        if (match(msg, /^\[[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]\] /)) {
            state = substr(msg, 2, 5)
            msg = substr(msg, RLENGTH + 1)
        }
    }
    if (msg ~ /^(DETAIL|HINT|CONTEXT|Context|QUERY|STATEMENT|SQL query|SQL params|LINE [0-9]+):/ || msg ~ /^[ \t]/ || msg ~ /:[ \t]*$/ || msg == "") {
        show_continuation()
        next
    }

    sub(/^(ERROR|FATAL): +/, "", msg)
    record(classify(msg, file, state), state, msg, $0)
}

END {
    for (p in bn) flush_block(p)
    if (show != "") exit (ncat > 0) ? 1 : 0

    printf "Log:            %s\n", logfile
    if (since != "") printf "Since:          %s\n", since
    printf "Lines scanned:  %d (pgcopydb runs: %d)\n", lines, runs
    printf "Log levels:     ERROR %d, FATAL %d, WARN %d\n", nerr, nfatal, nwarn
    if (ignored != "") printf "pg_restore:     %s errors ignored on restore (last report)\n", ignored
    if (ncommand > 0) printf "                %d failed statements in the log (pg_restore --jobs counts a failed item two times)\n", ncommand
    print ""

    if (ncat == 0) { print "No errors found."; exit 0 }

    for (i = 2; i <= ncat; i++) {
        c = cats[i]
        for (j = i - 1; j >= 1 && count[cats[j]] < count[c]; j--) cats[j + 1] = cats[j]
        cats[j + 1] = c
    }

    print "SUMMARY"
    for (i = 1; i <= ncat; i++) printf "  %7d  %s\n", count[cats[i]], cats[i]

    for (i = 1; i <= ncat; i++) {
        c = cats[i]
        print ""
        printf "%s: %d %s, %s to %s\n", c, count[c], (count[c] == 1) ? "event" : "events", first[c], last[c]
        n = nsig[c]
        for (a = 2; a <= n; a++) {
            s = sigs[c, a]
            for (b = a - 1; b >= 1 && sigcount[c, sigs[c, b]] < sigcount[c, s]; b--) sigs[c, b + 1] = sigs[c, b]
            sigs[c, b + 1] = s
        }
        for (a = 1; a <= n && a <= top; a++) printf "  %7d  %s\n", sigcount[c, sigs[c, a]], sigs[c, a]
        if (n > top) printf "           (%d more message types, use --top or --show)\n", n - top
    }
    print ""
    print "Run with --show <category> to print the log lines for a category."
    exit 1
}
' "$LOGFILE"
