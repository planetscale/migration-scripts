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

# Create a table for import metadata _before_ creating the logical replication
# publication and subscription since DDL won't flow.
psql "$PRIMARY" -c "CREATE TABLE IF NOT EXISTS _planetscale_import (ts BIGINT PRIMARY KEY, status VARCHAR(255));"

# Publish the primary's logical replication stream to a replication slot.
if ! psql "$PRIMARY" -c "SELECT setting FROM pg_settings WHERE name = 'wal_level';" | grep -q "logical"
then
    echo "primary wal_level != logical" >&2
    exit 1
fi
psql "$PRIMARY" -c "CREATE PUBLICATION _planetscale_import;" || :
psql "$PRIMARY" -A -c '\dt' -t |
cut -d "|" -f "2" |
while read TABLE
do psql "$PRIMARY" -c "ALTER PUBLICATION _planetscale_import ADD TABLE $TABLE;"
done

# Import the primary's schema.
pg_dump --no-owner --no-privileges --no-publications --no-subscriptions --schema-only "$PRIMARY" |
psql "$REPLICA" -a
psql "$PRIMARY" -c '\d'
psql "$REPLICA" -c '\d'

# Subscribe the replica to the primary's logical replication stream.
psql "$REPLICA" -c "CREATE SUBSCRIPTION _planetscale_import CONNECTION '$PRIMARY' PUBLICATION _planetscale_import;" ||
psql "$REPLICA" -c "ALTER SUBSCRIPTION _planetscale_import CONNECTION '$PRIMARY';"

sh "$(dirname "$0")/stat-logical-repl.sh" --primary "$PRIMARY" --replica "$REPLICA"
