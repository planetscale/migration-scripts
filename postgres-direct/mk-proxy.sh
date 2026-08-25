set -e

usage() {
    printf "Usage: sh %s --proxy \e[4mconninfo\e[0m --server \e[4mconninfo\e[0m\n" "$(basename "$0")" >&2
    printf "  --proxy \e[4mconninfo\e[0m   connection information for the PlanetScale Postgres database serving as the proxy\n" >&2
    printf "  --server \e[4mconninfo\e[0m  connection information for the underlying Postgres database server\n" >&2
    exit "$1"
}

PROXY="" SERVER=""
while [ "$#" -gt 0 ]
do
    case "$1" in

        "-p"|"--proxy") PROXY="$2" shift 2;;
        "-p"*) PROXY="$(echo "$1" | cut -c"3-")" shift;;
        "--proxy="*) PROXY="$(echo "$1" | cut -d"=" -f"2-")" shift;;

        "-s"|"--server") SERVER="$2" shift 2;;
        "-s"*) SERVER="$(echo "$1" | cut -c"3-")" shift;;
        "--server="*) SERVER="$(echo "$1" | cut -d"=" -f"2-")" shift;;

        "-h"|"--help") usage 0;;
        *) usage 1;;
    esac
done
if [ -z "$PROXY" -o -z "$SERVER" ]
then usage 1
fi

export PSQL_PAGER=""

set -x

# Create a view of every sequence which we'll use below to wire the foreign
# tables into their real serial primary key sequences. We do this before
# importing the foreign schema so that these views get imported, too.
# <https://paquier.xyz/postgresql-2/global-sequences-with-postgres_fdw-and-postgres-core/>
psql "$SERVER" -A -c '\ds' -t |
cut -d "|" -f "2" |
while read SEQ
do psql "$SERVER" -c "CREATE OR REPLACE VIEW ${SEQ}_view AS SELECT nextval('$SEQ') as val;"
done

# Setup the Postgres Foreign Data Wrapper to turn the Horizon instance into a
# fancy proxy to the underlying Postgres database server.
psql "$SERVER" -c "CREATE TABLE IF NOT EXISTS _planetscale_import (ts bigint PRIMARY KEY, status varchar(255));"
if ! psql "$PROXY" -c '\d _planetscale_import'
then
    PROXY_USERNAME="$(psql "$PROXY" -c '\conninfo' | head -n "1" | cut -d '"' -f "4")"
    PROXY_HOSTNAME="$(psql "$PROXY" -c '\conninfo' | head -n "1" | cut -d '"' -f "6")"
    SERVER_DATABASE="$(psql "$SERVER" -c '\conninfo' | head -n "1" | cut -d '"' -f "2")"
    SERVER_USERNAME="$(psql "$SERVER" -c '\conninfo' | head -n "1" | cut -d '"' -f "4")"
    SERVER_HOSTNAME="$(psql "$SERVER" -c '\conninfo' | head -n "1" | cut -d '"' -f "6")"
    SERVER_PORT="$(psql "$SERVER" -c '\conninfo' | head -n "1" | cut -d '"' -f "10")"
    SERVER_PASSWORD="$(
        if echo "$SERVER" | grep -q "^postgresql://"
        then echo "$SERVER" | cut -d ":" -f "3" | cut -d "@" -f "1"
        else echo "$SERVER" | grep -E -o "password=[^ ]+" | cut -d "=" -f "2"
        fi
    )"

    # Enable and setup a foreign server and user mapping. This is idempotent.
    PG_USERNAME="$(echo "$PROXY_USERNAME" | cut -d "." -f "1")" # first half of the target username is the true Postgres username
    psql "$PROXY" -c "CREATE EXTENSION IF NOT EXISTS postgres_fdw;" # also "GRANT USAGE ON FOREIGN DATA WRAPPER postgres_fdw TO $PG_USERNAME;" implicitly
    psql "$PROXY" -c "CREATE SERVER IF NOT EXISTS _planetscale_import FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host '$SERVER_HOSTNAME', port '$SERVER_PORT', dbname '$SERVER_DATABASE');"
    psql "$PROXY" -c "CREATE USER MAPPING IF NOT EXISTS FOR $PG_USERNAME SERVER _planetscale_import OPTIONS (user '$SERVER_USERNAME', password '$SERVER_PASSWORD');"

    # IMPORT FOREIGN SCHEMA in a loop as there may be errors with e.g. missing
    # types that need the DBA to CREATE TYPE on the target before proceeding.
    # There are lots of caveats for IMPORT FOREIGN SCHEMA to beware of, too.
    # <https://www.postgresql.org/docs/current/postgres-fdw.html#POSTGRES-FDW-OPTIONS-IMPORTING>
    until psql "$PROXY" -c "IMPORT FOREIGN SCHEMA public FROM SERVER _planetscale_import INTO public;"
    do
        set +x
        echo >&2
        read -p "IMPORT FOREIGN SCHEMA failed. Press <enter> to drop into a psql shell on the target to fix the errors or ^C to exit. IMPORT FOREIGN SCHEMA will retry when you exit. " _
        set -x
        psql "$PROXY"
    done

fi

# Wire the sequence views created above into the default values for serial
# primary key columns in the foreign tables via a local function.
# <https://paquier.xyz/postgresql-2/global-sequences-with-postgres_fdw-and-postgres-core/>
psql "$SERVER" -A -c '\ds' -t |
cut -d "|" -f "2" |
while read SEQ
do
    TYPE="$(psql "$SERVER" -A -c "\\d $SEQ" -t | cut -d "|" -f "1")"
    psql "$PROXY" -c "CREATE OR REPLACE FUNCTION ${SEQ}_view_nextval() RETURNS $TYPE AS 'SELECT val FROM ${SEQ}_view;' LANGUAGE SQL;"
done
psql "$SERVER" -A -c '\dt' -t |
cut -d "|" -f "2" |
while read TABLE
do
    psql "$SERVER" -A -c "\\d $TABLE" -t |
    awk -F "['|]" "/nextval\\('([^']+)'::regclass\\)/ {print \"$TABLE\", \$1, \$6}" |
    while read T C S
    do psql "$PROXY" -c "ALTER FOREIGN TABLE $T ALTER COLUMN $C SET DEFAULT ${S}_view_nextval();"
    done
done

# Output evidence that the source schema and target foreign schema match.
psql "$PROXY" -c '\d'
psql "$PROXY" -c '\det'
psql "$SERVER" -c '\d'

#psql "$PROXY"
#psql "$SERVER"
