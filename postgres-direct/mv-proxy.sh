set -e

usage() {
    printf "Usage: sh %s --proxy \e[4mconninfo\e[0m --server \e[4mconninfo\e[0m [--skip \e[4mseconds\e[0m]\n" "$(basename "$0")" >&2
    printf "  --proxy \e[4mconninfo\e[0m   connection information for the PlanetScale Postgres database serving as the proxy\n" >&2
    printf "  --server \e[4mconninfo\e[0m  connection information for the underlying Postgres database server\n" >&2
    printf "  --skip \e[4mseconds\e[0m     skip approximately \e[4mseconds\e[0m ahead in all sequences (default 60)\n" >&2
    exit "$1"
}

PROXY="" SERVER="" SKIP="60"
while [ "$#" -gt 0 ]
do
    case "$1" in

        "-p"|"--proxy") PROXY="$2" shift 2;;
        "-p"*) PROXY="$(echo "$1" | cut -c"3-")" shift;;
        "--proxy="*) PROXY="$(echo "$1" | cut -d"=" -f"2-")" shift;;

        "-s"|"--server") SERVER="$2" shift 2;;
        "-s"*) SERVER="$(echo "$1" | cut -c"3-")" shift;;
        "--server="*) SERVER="$(echo "$1" | cut -d"=" -f"2-")" shift;;

        "--skip") SKIP="$2" shift 2;;
        "--skip="*) SKIP="$(echo "$1" | cut -d"=" -f"2-")" shift;;

        "-h"|"--help") usage 0;;
        *) usage 1;;
    esac
done
if [ -z "$PROXY" -o -z "$SERVER" -o -z "$SKIP" ]
then usage 1
fi

export PSQL_PAGER=""

set -x

PROXY_USERNAME="$(psql "$PROXY" -c '\conninfo' | head -n "1" | cut -d '"' -f "4")"
SERVER_DATABASE="$(psql "$SERVER" -c '\conninfo' | head -n "1" | cut -d '"' -f "2")"
SERVER_HOSTNAME="$(psql "$SERVER" -c '\conninfo' | head -n "1" | cut -d '"' -f "6")"
SERVER_PASSWORD="$(
    if echo "$SERVER" | grep -q "^postgresql://"
    then echo "$SERVER" | cut -d ":" -f "3" | cut -d "@" -f "1"
    else echo "$SERVER" | grep -E -o "password=[^ ]+" | cut -d "=" -f "2"
    fi
)"
SERVER_PORT="$(psql "$SERVER" -c '\conninfo' | head -n "1" | cut -d '"' -f "10")"
SERVER_USERNAME="$(psql "$SERVER" -c '\conninfo' | head -n "1" | cut -d '"' -f "4")"

# Fast-forward all the sequences on the new server to positions ahead of the
# old server via the views on the proxy.
sh "$(dirname "$0")/ff-seq.sh" --primary "$PROXY" --replica "$SERVER" --skip "$SKIP" --views

# Reconfigure the FDW. This causes it to disconnect.
PG_USERNAME="$(echo "$PROXY_USERNAME" | cut -d "." -f "1")" # first half of the proxy username is the true Postgres username
psql "$PROXY" -c "
    BEGIN;
    ALTER SERVER _planetscale_import OPTIONS (SET host '$SERVER_HOSTNAME', SET port '$SERVER_PORT', SET dbname '$SERVER_DATABASE');
    ALTER USER MAPPING FOR $PG_USERNAME SERVER _planetscale_import OPTIONS (SET user '$SERVER_USERNAME', SET password '$SERVER_PASSWORD');
    COMMIT;
"

#psql "$PROXY"
#psql "$SERVER"
