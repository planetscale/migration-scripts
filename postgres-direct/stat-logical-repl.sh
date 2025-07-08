set -e

usage() {
    printf "Usage: sh %s --primary \e[4mconninfo\e[0m --replica \e[4mconninfo\e[0m\n" "$(basename "$0")" >&2
    printf "  --primary \e[4mconninfo\e[0m  connection information for the primary Postgres database\n" >&2
    printf "  --replica \e[4mconninfo\e[0m  connection information for the replica Postgres database\n" >&2
    exit "$1"
}

PRIMARY="" REPLICA=""
while [ "$#" -gt 0 ]
do
    case "$1" in

        "-p"|"--primary") PRIMARY="$2" shift 2;;
        "-p"*) PRIMARY="$(echo "$1" | cut -c"3-")" shift;;
        "--primary="*) PRIMARY="$(echo "$1" | cut -d"=" -f"2-")" shift;;

        "-r"|"--replica") REPLICA="$2" shift 2;;
        "-r"*) REPLICA="$(echo "$1" | cut -c"3-")" shift;;
        "--replica="*) REPLICA="$(echo "$1" | cut -d"=" -f"2-")" shift;;

        "-h"|"--help") usage 0;;
        *) usage 1;;
    esac
done
if [ -z "$PRIMARY" -o -z "$REPLICA" ]
then usage 1
fi

export PSQL_PAGER=""

# Inspect the schema on the primary and replica.
echo >&2
echo "##############################" >&2
echo "# PRIMARY AND REPLICA SCHEMA #" >&2
echo "##############################" >&2
echo >&2
(
    set -x
    psql "$PRIMARY" -c '\d'
    psql "$REPLICA" -c '\d'
)
echo >&2

# Inspect Postgres' internal logical replication status information.
echo >&2
echo "######################" >&2
echo "# REPLICATION STATUS #" >&2
echo "######################" >&2
echo >&2
(
    set -x
    psql "$PRIMARY" -a -x <<EOF
SELECT * FROM pg_stat_replication WHERE application_name = '_planetscale_import';
SELECT
    active, inactive_since, invalidation_reason, wal_status,
    confirmed_flush_lsn, pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)
    FROM pg_replication_slots WHERE slot_name = '_planetscale_import';
EOF
    psql "$REPLICA" -a -x <<EOF
SELECT * FROM pg_catalog.pg_stat_subscription WHERE subname = '_planetscale_import';
\x
SELECT
    n.nspname,
    c.relname,
    sr.srsubstate,
    CASE
        WHEN sr.srsubstate = 'i' THEN 'initializing'
        WHEN sr.srsubstate = 'd' THEN 'data is being copied'
        WHEN sr.srsubstate = 'f' THEN 'finished table copy'
        WHEN sr.srsubstate = 's' THEN 'synchronized'
        WHEN sr.srsubstate = 'r' THEN 'ready (normal replication)'
        ELSE ''
    END AS srsubstate_explain,
    sr.srsublsn
    FROM pg_subscription s
    JOIN pg_subscription_rel sr ON s.oid = sr.srsubid
    JOIN pg_class c ON c.oid = sr.srrelid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE s.subname = '_planetscale_import';
EOF
)
echo >&2

# Send a sentinel write through the logical replication stream.
echo >&2
echo "###############" >&2
echo "# TEST RECORD #" >&2
echo "###############" >&2
echo >&2
(
    set -x
    TS="$(date +"%s")"
    psql "$PRIMARY" -c "INSERT INTO _planetscale_import VALUES ($TS, 'testing');"
    sleep 1
    psql "$REPLICA" -c "SELECT * FROM _planetscale_import WHERE ts >= $TS;"
)
echo >&2

# Uncomment for ad-hoc psql shells.
echo >&2
#psql "$PRIMARY"
#psql "$REPLICA"
