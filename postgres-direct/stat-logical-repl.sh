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

set -x

# Inspect the schema on the primary and replica.
psql "$PRIMARY" -c '\d'
psql "$REPLICA" -c '\d'

# Inspect all Postgres' internal replication status information.
psql "$PRIMARY" -c "SELECT * FROM pg_stat_replication;" -x
psql "$PRIMARY" -c "SELECT * FROM pg_replication_slots;" -x
psql "$PRIMARY" -c "SELECT slot_name, slot_type, active, pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) FROM pg_replication_slots;"
psql "$REPLICA" -c "SELECT * FROM pg_stat_wal_receiver;" -x || : # not supported in Aurora 13
psql "$REPLICA" -c "SELECT * FROM pg_catalog.pg_stat_subscription;" -x

# Do a sloppy distributed transaction to figure out how far behind we are.
psql "$PRIMARY" -c "SELECT pg_current_wal_lsn();"
psql "$REPLICA" -c "SELECT received_lsn FROM pg_stat_subscription WHERE subname = '_planetscale_import';"
PRIMARY_LSN="$(psql "$PRIMARY" -A -c "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0');" -t)"
REPLICA_LSN="$(psql "$REPLICA" -A -c "SELECT pg_wal_lsn_diff(received_lsn, '0/0') FROM pg_stat_subscription WHERE subname = '_planetscale_import';" -t)"
LAG="$((PRIMARY_LSN - REPLICA_LSN))" # bytes behind
set +x
if [ "$LAG" -lt "1024" ]
then printf "replication is caught up"
else printf "replication is behind"
fi
echo "; lag: $LAG, primary LSN: $PRIMARY_LSN, replica LSN: $REPLICA_LSN"
set -x

# Send a sentinel write through the logical replication stream.
TS="$(date +"%s")"
psql "$PRIMARY" -c "INSERT INTO _planetscale_import VALUES ($TS, 'testing');"
sleep 1
psql "$REPLICA" -c "SELECT * FROM _planetscale_import WHERE ts >= $TS;"

#psql "$PRIMARY"
#psql "$REPLICA"
