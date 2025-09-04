set -e

usage() {
    printf "Usage: sh %s --primary \e[4mconninfo\e[0m --replica \e[4mconninfo\e[0m [--skip \e[4mseconds\e[0m] [--views]\n" "$(basename "$0")" >&2
    printf "  --primary \e[4mconninfo\e[0m  connection information for the primary Postgres database whose sequences (or views) will be read\n" >&2
    printf "  --replica \e[4mconninfo\e[0m  connection information for the replica Postgres database whose sequences will be fast-forwarded\n" >&2
    printf "  --skip \e[4mseconds\e[0m      skip approximately \e[4mseconds\e[0m ahead in all sequences (default 3600)\n" >&2
    printf "  --views             read views of sequences instead of the sequences themselves\n" >&2
    exit "$1"
}

SKIP="3600" PRIMARY="" REPLICA="" VIEWS=""
while [ "$#" -gt 0 ]
do
    case "$1" in

        "-p"|"--primary") PRIMARY="$2" shift 2;;
        "-p"*) PRIMARY="$(echo "$1" | cut -c"3-")" shift;;
        "--primary="*) PRIMARY="$(echo "$1" | cut -d"=" -f"2-")" shift;;

        "-r"|"--replica") REPLICA="$2" shift 2;;
        "-r"*) REPLICA="$(echo "$1" | cut -c"3-")" shift;;
        "--replica="*) REPLICA="$(echo "$1" | cut -d"=" -f"2-")" shift;;

        "--skip") SKIP="$2" shift 2;;
        "--skip="*) SKIP="$(echo "$1" | cut -d"=" -f"2-")" shift;;

        "--views") VIEWS="--views" shift;;

        "-h"|"--help") usage 0;;
        *) usage 1;;
    esac
done
if [ -z "$PRIMARY" -o -z "$REPLICA" -o -z "$SKIP" ]
then usage 1
fi

export PSQL_PAGER=""

set -x

# Fast-forward all the sequences on the replica well past their values on the
# primary. The gap here is precarious - if we don't fast-forward far enough we
# will generate duplicate values before completing the move. We sample 10
# seconds worth of sequence usage and then skip the anticipated number of
# values generated since the sampling plus the requested additional time to
# give the traffic-swinging deploy or transaction or whatever plenty of time.
SLEEP=10
psql "$REPLICA" -A -c '\ds' -t |
cut -d "|" -f "2" |
while read SEQ
do
    if [ "$VIEWS" ]
    then
        SEQ_T0="$(psql "$PRIMARY" -A -c "SELECT ${SEQ}_view_nextval();" -t)"
        sleep "$SLEEP"
        SEQ_T1="$(psql "$PRIMARY" -A -c "SELECT ${SEQ}_view_nextval();" -t)"
    else
        SEQ_T0="$(psql "$PRIMARY" -A -c "SELECT nextval('$SEQ');" -t)"
        sleep "$SLEEP"
        SEQ_T1="$(psql "$PRIMARY" -A -c "SELECT nextval('$SEQ');" -t)"
    fi
    echo "$SEQ $(date +"%s") $SLEEP $SEQ_T0 $SEQ_T1"
done |
while read SEQ TS SLEEP SEQ_T0 SEQ_T1
do
    psql "$REPLICA" -c "SELECT setval('$SEQ', $SEQ_T1 + (($(date +"%s") - $TS) / $SLEEP +  $SKIP / $SLEEP ) * ($SEQ_T1 - $SEQ_T0 ));"
    #                       (recent high-water mark) + ((    sleeps since measured   ) + (sleeps to skip)) * (nextval/sleep rate)
done

#psql "$PRIMARY"
#psql "$REPLICA"
