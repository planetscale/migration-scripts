set -e

usage() {
    printf "Usage: sh %s [--drop] --primary \e[4mconninfo\e[0m --replica \e[4mconninfo\e[0m\n" "$(basename "$0")" >&2
    printf "  --drop             DROP all the objects from the primary on the replica (dangerous and destructive!)\n" >&2
    printf "  --primary \e[4mconninfo\e[0m  connection information for the primary Postgres database\n" >&2
    printf "  --replica \e[4mconninfo\e[0m  connection information for the replica Postgres database\n" >&2
    exit "$1"
}

DROP="" PRIMARY="" REPLICA=""
while [ "$#" -gt 0 ]
do
    case "$1" in

        "--drop") DROP="$1" shift;;

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

psql "$REPLICA" -c "ALTER SUBSCRIPTION _planetscale_import DISABLE;" || :
psql "$REPLICA" -c "ALTER SUBSCRIPTION _planetscale_import SET (slot_name = NONE);" || :
psql "$REPLICA" -c "DROP SUBSCRIPTION IF EXISTS _planetscale_import;" || :
psql "$PRIMARY" -c "DROP PUBLICATION IF EXISTS _planetscale_import;" || :
psql "$PRIMARY" -c "SELECT pg_drop_replication_slot('_planetscale_import');" || :

if [ "$DROP" ]
then
    pg_dump --clean --no-owner --no-privileges --no-publications --no-subscriptions --schema-only "$PRIMARY" |
    grep -E "^(ALTER.*)?DROP" |
    sed -E "s/^(ALTER|DROP) [A-Z]+/& IF EXISTS/" |
    psql "$REPLICA" -a
fi
