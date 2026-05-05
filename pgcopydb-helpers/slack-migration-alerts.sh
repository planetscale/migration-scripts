#!/bin/bash
#
# slack-migration-alerts.sh — Slack alerts for pgcopydb migration failures and errors
#
# Runs from cron. State is stored inside the migration directory so it resets
# automatically when a new migration starts. Each unique event fires once only.
#
# SETUP
#   0. Add SLACK_WEBHOOK_URL to ~/.env:
#        export SLACK_WEBHOOK_URL='https://hooks.slack.com/services/...'
#
#   1. Test the webhook:
#        ~/slack-migration-alerts.sh --test
#
#   2. Install the cron job (default 2 min interval):
#        ~/slack-migration-alerts.sh --setup
#        ~/slack-migration-alerts.sh --setup --interval 5
#
#   3. Remove the cron job when done:
#        ~/slack-migration-alerts.sh --uninstall
#
# ALERTS FIRED
#   - pgcopydb process stopped unexpectedly (fires once per transition)
#   - New ERROR lines in migration.log (fires once per new batch)
#   - Initial copy completed (data + indexes + constraints + post-data; fires once)
#   - Migration completed successfully (fires once)
#   - Migration failed with non-zero exit code (fires once)
#
# State file: $MIGRATION_DIR/.notify-state  (inside the migration directory)
# Cron output is discarded; run manually to see output
#

set -uo pipefail

# ── Flag parsing ───────────────────────────────────────────────────
INTERVAL=2
ACTION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --interval)
            INTERVAL="${2:?--interval requires a value (1-59)}"
            shift 2
            ;;
        --setup|--uninstall|--test)
            ACTION="${1#--}"
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 [--setup [--interval N]] | [--uninstall] | [--test]" >&2
            exit 1
            ;;
    esac
done

# ── Load environment ───────────────────────────────────────────────
 set +u
 set -a
 source ~/.env
 set +a
 set -u

# ── Parse PlanetScale branch ID ────────────────────────────────────
# Username format in connection string: pscale_api_xxx.BRANCH_ID
_u="${PGCOPYDB_TARGET_PGURI:-}"; _u="${_u#*://}"; _u="${_u%%@*}"; _u="${_u%%:*}"
PS_BRANCH_ID="${_u##*.}"; unset _u

# ── Slack helper ───────────────────────────────────────────────────
slack_send() {
    local text="$1"
    local safe
    safe="${text//\\/\\\\}"
    safe="${safe//\"/\\\"}"
    safe="${safe//$'\n'/\\n}"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H 'Content-type: application/json' \
        --data "{\"text\":\"${safe}\"}" \
        "$SLACK_WEBHOOK_URL" 2>/dev/null) || http_code="000"

    if [ "$http_code" = "200" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') SENT: $text"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Slack returned HTTP $http_code" >&2
        return 1
    fi
}

# ── SQLite helper ──────────────────────────────────────────────────
db_query() {
    sqlite3 "$DB" "$1" 2>/dev/null || echo "${2:-0}"
}

# ── --test ─────────────────────────────────────────────────────────
if [ "$ACTION" = "test" ]; then
    if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
        echo "ERROR: SLACK_WEBHOOK_URL is not set in ~/.env"
        exit 1
    fi
    HOST=$(hostname -s 2>/dev/null || hostname)
    slack_send ":white_check_mark: Migration Monitor test from *${HOST}* — webhook working!" || exit 1
    exit 0
fi

# ── --setup ────────────────────────────────────────────────────────
if [ "$ACTION" = "setup" ]; then
    if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
        echo "ERROR: SLACK_WEBHOOK_URL is not set in ~/.env"
        exit 1
    fi
    if ! [[ "$INTERVAL" =~ ^[1-9][0-9]?$ ]] || [ "$INTERVAL" -gt 59 ]; then
        echo "ERROR: --interval must be 1-59 (got: $INTERVAL)"
        exit 1
    fi
    echo "Verifying webhook..."
    slack_send ":rocket: Migration monitor started for branch *${PS_BRANCH_ID:-unknown}* — Slack notifications active" || {
        echo "ERROR: Webhook verification failed — cron job not installed" >&2
        exit 1
    }
    SCRIPT="$HOME/slack-migration-alerts.sh"
    CRON_LINE="*/${INTERVAL} * * * * ${SCRIPT} > /dev/null 2>&1"
    ( crontab -l 2>/dev/null | grep -v "notify-migration.sh" | grep -v "slack-migration-alerts.sh" || true
      echo "$CRON_LINE"
    ) | crontab -
    echo "Cron job installed (every ${INTERVAL} min):"
    echo "  $CRON_LINE"
    exit 0
fi

# ── --uninstall ────────────────────────────────────────────────────
if [ "$ACTION" = "uninstall" ]; then
    ( crontab -l 2>/dev/null | grep -v "notify-migration.sh" | grep -v "slack-migration-alerts.sh" || true ) | crontab -
    echo "Cron job removed."
    exit 0
fi

# ── Guard ──────────────────────────────────────────────────────────
if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') SKIP: SLACK_WEBHOOK_URL not set in ~/.env"
    exit 0
fi

# ── Find migration directory ───────────────────────────────────────
MIGRATION_DIR=$(ls -dt "$HOME"/migration_* 2>/dev/null | head -1 || true)
if [ -z "$MIGRATION_DIR" ]; then
    exit 0
fi

LOG="$MIGRATION_DIR/migration.log"
DB="$MIGRATION_DIR/schema/source.db"
STATE="$MIGRATION_DIR/.notify-state"

if [ ! -f "$LOG" ]; then
    exit 0
fi

# ── Load state from previous run ──────────────────────────────────
# Stored inside the migration directory — resets automatically when
# a new migration starts (new directory = no state file).
LAST_ERROR_COUNT=0
LAST_STATUS="unknown"
LAST_INITIAL_COPY_NOTIFIED="false"
LAST_COMPLETION_NOTIFIED="false"

if [ -f "$STATE" ]; then
    # shellcheck source=/dev/null
    source "$STATE" 2>/dev/null || true
fi

# ── Current state from log ─────────────────────────────────────────
PROC_RUNNING=false
if ps aux | grep -q "[p]gcopydb.*clone"; then
    PROC_RUNNING=true
fi

MIGRATION_SUCCEEDED=false
MIGRATION_FAILED=false

INITIAL_COPY_DONE=false
if grep -q "All step are now done" "$LOG" 2>/dev/null; then
    INITIAL_COPY_DONE=true
fi

if grep -q "Migration SUCCEEDED" "$LOG" 2>/dev/null; then
    MIGRATION_SUCCEEDED=true
fi

EXIT_LINE=$(grep "Exit code:" "$LOG" 2>/dev/null | tail -1 || true)
if [ -n "$EXIT_LINE" ] && ! echo "$EXIT_LINE" | grep -q "Exit code: 0"; then
    MIGRATION_FAILED=true
fi

if [ "$MIGRATION_SUCCEEDED" = true ]; then
    CURRENT_STATUS="succeeded"
elif [ "$MIGRATION_FAILED" = true ]; then
    CURRENT_STATUS="failed"
elif [ "$PROC_RUNNING" = true ]; then
    CURRENT_STATUS="running"
else
    CURRENT_STATUS="stopped"
fi

CURRENT_ERROR_COUNT=$(grep -c " ERROR " "$LOG" 2>/dev/null || true)
CURRENT_ERROR_COUNT=$(( ${CURRENT_ERROR_COUNT:-0} + 0 ))

# ── Context from SQLite for richer alert messages ──────────────────
TABLES_DONE=$(db_query "SELECT COUNT(*) FROM summary WHERE tableoid IS NOT NULL AND done_time_epoch IS NOT NULL;")
NONSPLIT=$(db_query "SELECT COUNT(*) FROM s_table t WHERE NOT EXISTS (SELECT 1 FROM s_table_part p WHERE p.oid = t.oid);")
SPLIT_PARTS=$(db_query "SELECT COUNT(*) FROM s_table_part;")
TABLES_TOTAL=$(( NONSPLIT + SPLIT_PARTS ))
BYTES=$(db_query "SELECT COALESCE(SUM(bytes),0) FROM summary WHERE tableoid IS NOT NULL;")
GB=$(echo "scale=1; $BYTES / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
INDEXES_DONE=$(db_query "SELECT COUNT(DISTINCT indexoid) FROM summary WHERE indexoid IS NOT NULL AND done_time_epoch IS NOT NULL;")
INDEXES_TOTAL=$(db_query "SELECT COUNT(*) FROM s_index;")
CONSTRAINTS_DONE=$(db_query "SELECT COUNT(DISTINCT conoid) FROM summary WHERE conoid IS NOT NULL AND done_time_epoch IS NOT NULL;")
CONSTRAINTS_TOTAL=$(db_query "SELECT COUNT(*) FROM s_constraint;")

# ── Evaluate and notify ────────────────────────────────────────────
NOTIFIED_INITIAL_COPY="$LAST_INITIAL_COPY_NOTIFIED"
NOTIFIED_COMPLETION="$LAST_COMPLETION_NOTIFIED"

if [ "$INITIAL_COPY_DONE" = true ] && [ "$LAST_INITIAL_COPY_NOTIFIED" = "false" ]; then
    DIR_EPOCH=$(stat -c %Y "$MIGRATION_DIR" 2>/dev/null || date +%s)
    SECS=$(( $(date +%s) - DIR_EPOCH ))
    RUNTIME=$(printf "%dh %02dm" $(( SECS/3600 )) $(( (SECS%3600)/60 )))
    msg=":large_blue_circle: *Initial copy completed — CDC phase starting*"
    msg+=$'\n'"Branch: *${PS_BRANCH_ID}* | Runtime: ${RUNTIME} | Data: ${GB} GB"
    msg+=$'\n'"Tables: ${TABLES_DONE}/${TABLES_TOTAL} | Indexes: ${INDEXES_DONE}/${INDEXES_TOTAL} | Constraints: ${CONSTRAINTS_DONE}/${CONSTRAINTS_TOTAL}"
    if slack_send "$msg"; then
        NOTIFIED_INITIAL_COPY="true"
    fi

elif [ "$CURRENT_STATUS" = "succeeded" ] && [ "$LAST_COMPLETION_NOTIFIED" = "false" ]; then
    DIR_EPOCH=$(stat -c %Y "$MIGRATION_DIR" 2>/dev/null || date +%s)
    SECS=$(( $(date +%s) - DIR_EPOCH ))
    RUNTIME=$(printf "%dh %02dm" $(( SECS/3600 )) $(( (SECS%3600)/60 )))
    msg=":white_check_mark: *Migration completed successfully*"
    msg+=$'\n'"Branch: *${PS_BRANCH_ID}* | Runtime: ${RUNTIME} | Data: ${GB} GB"
    msg+=$'\n'"Tables: ${TABLES_DONE}/${TABLES_TOTAL} | Dir: ${MIGRATION_DIR}"
    if slack_send "$msg"; then
        NOTIFIED_COMPLETION="true"
    fi

elif [ "$CURRENT_STATUS" = "failed" ] && [ "$LAST_COMPLETION_NOTIFIED" = "false" ]; then
    msg=":red_circle: *Migration FAILED*"
    msg+=$'\n'"Branch: *${PS_BRANCH_ID}* | Tables: ${TABLES_DONE}/${TABLES_TOTAL} | Data: ${GB} GB"
    msg+=$'\n'"Check migration.log for error details"
    msg+=$'\n'"Dir: ${MIGRATION_DIR}"
    if slack_send "$msg"; then
        NOTIFIED_COMPLETION="true"
    fi

elif [ "$CURRENT_STATUS" = "stopped" ] && [ "$LAST_STATUS" = "running" ]; then
    msg=":warning: *Migration process stopped unexpectedly*"
    msg+=$'\n'"Branch: *${PS_BRANCH_ID}* | Tables: ${TABLES_DONE}/${TABLES_TOTAL} | Data: ${GB} GB"
    msg+=$'\n'"Run: tail -50 ${LOG}"
    slack_send "$msg" || true

elif [ "$CURRENT_ERROR_COUNT" -gt "$LAST_ERROR_COUNT" ]; then
    NEW_COUNT=$(( CURRENT_ERROR_COUNT - LAST_ERROR_COUNT ))
    msg=":warning: *${NEW_COUNT} new error(s) in migration log*"
    msg+=$'\n'"Branch: *${PS_BRANCH_ID}* | Total errors: ${CURRENT_ERROR_COUNT} | Tables: ${TABLES_DONE}/${TABLES_TOTAL}"
    slack_send "$msg" || true
fi

# ── Save state ─────────────────────────────────────────────────────
cat > "$STATE" <<EOF
LAST_ERROR_COUNT=${CURRENT_ERROR_COUNT}
LAST_STATUS=${CURRENT_STATUS}
LAST_INITIAL_COPY_NOTIFIED=${NOTIFIED_INITIAL_COPY}
LAST_COMPLETION_NOTIFIED=${NOTIFIED_COMPLETION}
EOF
