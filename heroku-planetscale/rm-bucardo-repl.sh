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

while true
do
    read -p "Are you sure you want to turn off Bucardo asynchronous replication? (yes/no) " YESNO
    case "$YESNO" in
        "YES"|"Yes"|"yes") break;;
        "NO"|"No"|"no") exit;;
        *) echo "Please reply exactly \"yes\" or \"no\"";;
    esac
done

set -x

sudo -H -u "bucardo" bucardo remove sync "planetscale_import"
sudo -H -u "bucardo" bucardo list tables | tr -s " " | cut -d " " -f 3 | xargs sudo -H -u "bucardo" bucardo remove table
sudo -H -u "bucardo" bucardo list sequences | tr -s " " | cut -d " " -f 2 | xargs sudo -H -u "bucardo" bucardo remove sequence
sudo -H -u "bucardo" bucardo remove relgroup "planetscale_import"
sudo -H -u "bucardo" bucardo remove dbgroup "planetscale_import"
sudo -H -u "bucardo" bucardo remove database "planetscale"
sudo -H -u "bucardo" bucardo remove database "heroku"
sudo -H -i -u "bucardo" bucardo stop
psql "$PRIMARY" -A -c "SELECT format('DROP TRIGGER %I ON %I;', tgname, tgrelid::regclass) from pg_trigger where tgname like 'bucardo_%';" -t |
psql "$PRIMARY" -a
psql "$PRIMARY" -c "DROP SCHEMA bucardo CASCADE;"
