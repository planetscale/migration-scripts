set -e

DEBUG=""

usage() {
    printf "Usage: sh %s --identifier \e[4midentifier\e[0m [--task-only] [--debug]\n" "$(basename "$0")" >&2
    printf "  --identifier \e[4midentifier\e[0m  unique identifier for AWS DMS resources\n" >&2
    printf "  --task-only              only cleanup the replication task, leaving the replication instance and endpoints for reuse\n" >&2
    printf "  --debug                  enable debug mode with verbose command output\n" >&2
    exit "$1"
}

IDENTIFIER="" TASK_ONLY="" DEBUG=""
while [ "$#" -gt 0 ]
do
    case "$1" in

        "-i"|"--id"|"--identifier") IDENTIFIER="$2" shift 2;;
        "-i"*) IDENTIFIER="$(echo "$1" | cut -c"3-")" shift;;
        "--id="*|"--identifier="*) IDENTIFIER="$(echo "$1" | cut -d"=" -f"2-")" shift;;

        "-t"|"--task-only") TASK_ONLY="$1" shift;;

        "--debug") DEBUG="$1" shift;;

        "-h"|"--help") usage 0;;
        *) usage 1;;
    esac
done
if [ -z "$IDENTIFIER" ]
then usage 1
fi

if [ "$DEBUG" ]; then
    set -x
fi

echo "Starting cleanup process..."

echo "Checking for replication task..."
REPLICATION_TASK_ARN="$(
    aws dms describe-replication-tasks \
        --filters Name="replication-task-id",Values="$IDENTIFIER" \
        --output "text" \
        --query 'ReplicationTasks[].ReplicationTaskArn' || :
)"
if [ "$REPLICATION_TASK_ARN" ]
then
    echo "Stopping and deleting replication task..."
    aws dms stop-replication-task --replication-task-arn "$REPLICATION_TASK_ARN" |
    jq -e '.' &&
    aws dms wait replication-task-stopped \
        --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN" || :
    aws dms delete-replication-task --replication-task-arn "$REPLICATION_TASK_ARN" |
    jq -e '.'
    aws dms wait replication-task-deleted \
        --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN"
fi

if [ "$TASK_ONLY" ]
then exit
fi

echo "Checking for replication instance..."
REPLICATION_INSTANCE_ARN="$(
    aws dms describe-replication-instances \
        --filters Name="replication-instance-id",Values="$IDENTIFIER" \
        --output "text" \
        --query 'ReplicationInstances[].ReplicationInstanceArn' || :
)"
if [ "$REPLICATION_INSTANCE_ARN" ]
then
    echo "Deleting replication instance..."
    aws dms delete-replication-instance \
        --replication-instance-arn "$REPLICATION_INSTANCE_ARN" |
    jq -e '.'
    aws dms wait replication-instance-deleted \
        --filters Name="replication-instance-arn",Values="$REPLICATION_INSTANCE_ARN"
fi

echo "Deleting replication subnet group..."
aws dms delete-replication-subnet-group \
    --replication-subnet-group-identifier "$IDENTIFIER" |
jq -e '.' || :

echo "Checking for source endpoint..."
SOURCE_ENDPOINT_ARN="$(
    aws dms describe-endpoints \
        --filters Name="endpoint-id",Values="$IDENTIFIER-source" \
        --output "text" \
        --query 'Endpoints[].EndpointArn' || :
)"
if [ "$SOURCE_ENDPOINT_ARN" ]
then
    echo "Deleting source endpoint..."
    aws dms delete-endpoint --endpoint-arn "$SOURCE_ENDPOINT_ARN" |
    jq -e '.'
    aws dms wait endpoint-deleted \
        --filters Name="endpoint-arn",Values="$SOURCE_ENDPOINT_ARN"
fi
echo "Checking for target endpoint..."
TARGET_ENDPOINT_ARN="$(
    aws dms describe-endpoints \
        --filters Name="endpoint-id",Values="$IDENTIFIER-target" \
        --output "text" \
        --query 'Endpoints[].EndpointArn' || :
)"
if [ "$TARGET_ENDPOINT_ARN" ]
then
    echo "Deleting target endpoint..."
    aws dms delete-endpoint --endpoint-arn "$TARGET_ENDPOINT_ARN" |
    jq -e '.'
    aws dms wait endpoint-deleted \
        --filters Name="endpoint-arn",Values="$TARGET_ENDPOINT_ARN"
fi

echo "Cleanup complete."
