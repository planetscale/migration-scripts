set -e

usage() {
    printf "Usage: sh %s --primary \e[4mconninfo\e[0m --replica \e[4mconninfo\e[0m\n" "$(basename "$0")" >&2
    printf "  --primary \e[4mconninfo\e[0m  connection information for the primary (Heroku) Postgres database\n" >&2
    printf "  --replica \e[4mconninfo\e[0m  connection information for the replica (PlanetScale) Postgres database\n" >&2
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

set -x

# Copy the schema from the primary to the (soon to be) replica.
pg_dump --no-owner --no-privileges --no-publications --no-subscriptions --schema-only "$PRIMARY" |
psql "$REPLICA" -a

# Add the primary (Heroku) database to Bucardo. Parse the subset of connection
# information Bucardo needs from Heroku's URL-formatted connection information.
sudo -H -u "bucardo" bucardo add database "heroku" \
    host="$(echo "$PRIMARY" | cut -d "@" -f 2 | cut -d ":" -f 1)" \
    user="$(echo "$PRIMARY" | cut -d "/" -f 3 | cut -d ":" -f 1)" \
    password="$(echo "$PRIMARY" | cut -d ":" -f 3 | cut -d "@" -f 1)" \
    dbname="$(echo "$PRIMARY" | cut -d "/" -f 4 | cut -d "?" -f 1)"

# Add the (soon to be) replica (PlanetScale) database to Bucardo. With the
# exception of the ssl* parameters, PlanetScale's space-delimited connection
# information is exactly what Bucardo needs.
sudo -H -u "bucardo" bucardo add database "planetscale" ${REPLICA%%" ssl"*}

# Add all the sequences and tables to Bucardo.
sudo -H -u "bucardo" bucardo add all sequences --relgroup "planetscale_import"
sudo -H -u "bucardo" bucardo add all tables --relgroup "planetscale_import"

# Add the sync configuration to Bucardo, including a one-time copy phase.
sudo -H -u "bucardo" bucardo add sync "planetscale_import" dbs="heroku,planetscale" onetimecopy=1 relgroup="planetscale_import"

# Reload Bucardo, which starts the sync we just added.
sudo -H -u "bucardo" bucardo reload

sh "$(dirname "$0")/stat-bucardo-repl.sh" --primary "$PRIMARY" --replica "$REPLICA"
