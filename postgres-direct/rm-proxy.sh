set -e

usage() {
    printf "Usage: sh %s \e[4mconninfo\e[0m\n" "$(basename "$0")" >&2
    printf "  \e[4mconninfo\e[0m  connection information for the proxy PlanetScale Postgres database serving as the proxy\n" >&2
    exit "$1"
}

PROXY=""
while [ "$#" -gt 0 ]
do
    case "$1" in
        "-h"|"--help") usage 0;;
        *) break;
    esac
done
PROXY="$1" shift
if [ -z "$PROXY" -o "$1" ]
then usage 1
fi

export PSQL_PAGER=""

set -x

psql "$PROXY" -c "DROP SERVER IF EXISTS _planetscale_import CASCADE;"
