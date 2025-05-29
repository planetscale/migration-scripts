#!/bin/bash
# cleanup.sh - Removes AWS resources created by prepare.sh for PostgreSQL to MySQL migration
set -e

usage() {
    printf "Usage: sh %s --identifier \e[4midentifier\e[0m [--task-only] [--skip-rds] [--debug]\n" "$(basename "$0")" >&2
    printf "  --identifier \e[4midentifier\e[0m  unique identifier for AWS resources\n" >&2
    printf "  --task-only              only cleanup the replication task, leaving the replication instance and endpoints for reuse\n" >&2
    printf "  --skip-rds               skip deletion of RDS resources\n" >&2
    printf "  --debug                  enable verbose debugging output\n" >&2
    exit "$1"
}

# Parse command line arguments
IDENTIFIER=""
TASK_ONLY=""
SKIP_RDS=""
DEBUG=""

# Initialize all other variables
i=1
while [ $i -le $# ]; do
    eval "current=\${$i}"

    case "$current" in
        "-i"|"--identifier")
            i=$((i + 1))
            eval "IDENTIFIER=\${$i}"
            ;;
        "-t"|"--task-only")
            TASK_ONLY="yes"
            ;;
        "--skip-rds")
            SKIP_RDS="yes"
            ;;
        "--debug")
            DEBUG="yes"
            ;;
        "-h"|"--help")
            usage 0
            ;;
        *)
            usage 1
            ;;
    esac
    i=$((i + 1))
done
# Validate required arguments
if [ -z "$IDENTIFIER" ]
then usage 1
fi

# Enable command tracing for debugging if requested
export PS4='+${BASH_SOURCE}:${LINENO}: '
if [ "$DEBUG" = "yes" ]; then
    echo "Debug mode enabled - showing all commands"
    set -ex
fi

echo "Starting cleanup for resources with identifier: $IDENTIFIER"

# 1. Delete DMS Replication Task
echo "Checking for DMS replication task..."
REPLICATION_TASK_ARN="$(
    aws dms describe-replication-tasks \
        --filters Name="replication-task-id",Values="$IDENTIFIER" \
        --output "text" \
        --query 'ReplicationTasks[].ReplicationTaskArn' || :
)"
if [ "$REPLICATION_TASK_ARN" ]
then
    echo "Stopping and deleting replication task: $REPLICATION_TASK_ARN"
    aws dms stop-replication-task --replication-task-arn "$REPLICATION_TASK_ARN" > /tmp/aws_output.json 2>&1
    if jq -e '.' /tmp/aws_output.json > /dev/null 2>&1; then
        cat /tmp/aws_output.json | jq '.'
    else
        echo "Failed to stop replication task or task was already stopped"
        [ "$DEBUG" = "yes" ] && cat /tmp/aws_output.json
    fi

    aws dms wait replication-task-stopped \
        --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN" || echo "Failed to wait for task to stop"

    aws dms delete-replication-task --replication-task-arn "$REPLICATION_TASK_ARN" > /tmp/aws_output.json 2>&1
    if jq -e '.' /tmp/aws_output.json > /dev/null 2>&1; then
        cat /tmp/aws_output.json | jq '.'
    else
        echo "Failed to delete replication task"
        [ "$DEBUG" = "yes" ] && cat /tmp/aws_output.json
    fi

    aws dms wait replication-task-deleted \
        --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN" || echo "Failed to wait for task deletion"

    echo "Replication task deleted successfully"
fi

# Exit if only cleaning up tasks
if [ "$TASK_ONLY" ]
then
    echo "Task-only cleanup completed"
    exit
fi

# 2. Delete DMS Replication Instance
echo "Checking for DMS replication instance..."
REPLICATION_INSTANCE_ARN="$(
    aws dms describe-replication-instances \
        --filters Name="replication-instance-id",Values="$IDENTIFIER" \
        --output "text" \
        --query 'ReplicationInstances[].ReplicationInstanceArn' || :
)"
if [ "$REPLICATION_INSTANCE_ARN" ]
then
    echo "Deleting replication instance: $REPLICATION_INSTANCE_ARN"
    aws dms delete-replication-instance \
        --replication-instance-arn "$REPLICATION_INSTANCE_ARN" > /tmp/aws_output.json 2>&1
    if jq -e '.' /tmp/aws_output.json > /dev/null 2>&1; then
        cat /tmp/aws_output.json | jq '.'
    else
        echo "Failed to delete replication instance"
        [ "$DEBUG" = "yes" ] && cat /tmp/aws_output.json
    fi

    aws dms wait replication-instance-deleted \
        --filters Name="replication-instance-arn",Values="$REPLICATION_INSTANCE_ARN" || echo "Failed to wait for instance deletion"

    echo "Replication instance deleted successfully"
fi

# 3. Delete DMS Subnet Group
echo "Deleting replication subnet group..."
aws dms delete-replication-subnet-group \
    --replication-subnet-group-identifier "$IDENTIFIER" > /tmp/aws_output.json 2>&1
if jq -e '.' /tmp/aws_output.json > /dev/null 2>&1; then
    cat /tmp/aws_output.json | jq '.'
else
    echo "Failed to delete replication subnet group or it did not exist"
    [ "$DEBUG" = "yes" ] && cat /tmp/aws_output.json
fi

# 4. Delete DMS Endpoints (Source PostgreSQL)
echo "Checking for DMS source endpoint..."
SOURCE_ENDPOINT_ARN="$(
    aws dms describe-endpoints \
        --filters Name="endpoint-id",Values="$IDENTIFIER-source" \
        --output "text" \
        --query 'Endpoints[].EndpointArn' || :
)"
if [ "$SOURCE_ENDPOINT_ARN" ]
then
    echo "Deleting source endpoint: $SOURCE_ENDPOINT_ARN"
    aws dms delete-endpoint --endpoint-arn "$SOURCE_ENDPOINT_ARN" > /tmp/aws_output.json 2>&1
    if jq -e '.' /tmp/aws_output.json > /dev/null 2>&1; then
        cat /tmp/aws_output.json | jq '.'
    else
        echo "Failed to delete source endpoint"
        [ "$DEBUG" = "yes" ] && cat /tmp/aws_output.json
    fi

    aws dms wait endpoint-deleted \
        --filters Name="endpoint-arn",Values="$SOURCE_ENDPOINT_ARN" || echo "Failed to wait for source endpoint deletion"

    echo "Source endpoint deleted successfully"
fi

# 5. Delete DMS Endpoints (Target MySQL)
echo "Checking for DMS target endpoint..."
TARGET_ENDPOINT_ARN="$(
    aws dms describe-endpoints \
        --filters Name="endpoint-id",Values="$IDENTIFIER-target" \
        --output "text" \
        --query 'Endpoints[].EndpointArn' || :
)"
if [ "$TARGET_ENDPOINT_ARN" ]
then
    echo "Deleting target endpoint: $TARGET_ENDPOINT_ARN"
    aws dms delete-endpoint --endpoint-arn "$TARGET_ENDPOINT_ARN" > /tmp/aws_output.json 2>&1
    if jq -e '.' /tmp/aws_output.json > /dev/null 2>&1; then
        cat /tmp/aws_output.json | jq '.'
    else
        echo "Failed to delete target endpoint"
        [ "$DEBUG" = "yes" ] && cat /tmp/aws_output.json
    fi

    aws dms wait endpoint-deleted \
        --filters Name="endpoint-arn",Values="$TARGET_ENDPOINT_ARN" || echo "Failed to wait for target endpoint deletion"

    echo "Target endpoint deleted successfully"
fi

# Skip RDS cleanup if requested
if [ "$SKIP_RDS" ]
then
    echo "Skipping RDS resource cleanup as requested"
    exit
fi

# 6. Delete Aurora MySQL Instance
echo "Checking for Aurora MySQL instance..."
RDS_INSTANCE_EXISTS=$(aws rds describe-db-instances \
    --filters "Name=db-instance-identifier,Values=$IDENTIFIER-mysql" \
    --query "DBInstances[*].DBInstanceIdentifier" \
    --output text || echo "")

if [ -n "$RDS_INSTANCE_EXISTS" ]; then
    echo "Deleting Aurora MySQL instance: $IDENTIFIER-mysql"
    aws rds delete-db-instance \
        --db-instance-identifier "$IDENTIFIER-mysql" \
        --skip-final-snapshot \
        --output json || echo "Failed to delete MySQL instance"

    echo "Waiting for MySQL instance to be deleted..."
    aws rds wait db-instance-deleted \
        --db-instance-identifier "$IDENTIFIER-mysql" || echo "Failed to wait for instance deletion"

    echo "MySQL instance deleted successfully"
fi

# 7. Delete Aurora Cluster
echo "Checking for Aurora cluster..."
CLUSTER_IDENTIFIER="$IDENTIFIER-aurora"
CLUSTER_EXISTS=$(aws rds describe-db-clusters \
    --filters "Name=db-cluster-identifier,Values=$CLUSTER_IDENTIFIER" \
    --query "DBClusters[*].DBClusterIdentifier" \
    --output text || echo "")

if [ -n "$CLUSTER_EXISTS" ]; then
    echo "Deleting Aurora cluster: $CLUSTER_IDENTIFIER"
    aws rds delete-db-cluster \
        --db-cluster-identifier "$CLUSTER_IDENTIFIER" \
        --skip-final-snapshot \
        --output json || echo "Failed to delete Aurora cluster"

    echo "Waiting for Aurora cluster to be deleted..."
    aws rds wait db-cluster-deleted \
        --db-cluster-identifier "$CLUSTER_IDENTIFIER" || echo "Failed to wait for cluster deletion"

    echo "Aurora cluster deleted successfully"
fi

# 8. Delete DB Parameter Groups
echo "Checking for DB Parameter Groups..."
CLUSTER_PARAM_GROUP_NAME="$IDENTIFIER-aurora-cluster-params"
DB_PARAM_GROUP_NAME="$IDENTIFIER-aurora-db-params"

echo "Deleting DB parameter group: $DB_PARAM_GROUP_NAME"
aws rds delete-db-parameter-group \
    --db-parameter-group-name "$DB_PARAM_GROUP_NAME" \
    --output json || echo "Failed to delete DB parameter group or it did not exist"

echo "Deleting cluster parameter group: $CLUSTER_PARAM_GROUP_NAME"
aws rds delete-db-cluster-parameter-group \
    --db-cluster-parameter-group-name "$CLUSTER_PARAM_GROUP_NAME" \
    --output json || echo "Failed to delete cluster parameter group or it did not exist"

# 9. Delete Security Group
echo "Checking for security group..."
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$IDENTIFIER-db-access" \
    --query "SecurityGroups[*].GroupId" \
    --output text || echo "")

if [ -n "$SECURITY_GROUP_ID" ]; then
    echo "Deleting security group: $SECURITY_GROUP_ID ($IDENTIFIER-db-access)"
    aws ec2 delete-security-group \
        --group-id "$SECURITY_GROUP_ID" \
        --output json || echo "Failed to delete security group"

    echo "Security group deleted successfully"
fi

# 10. Remove the task ARN file if it exists
if [ -f "$IDENTIFIER-task-arn.txt" ]; then
    echo "Removing task ARN file: $IDENTIFIER-task-arn.txt"
    rm -f "$IDENTIFIER-task-arn.txt"
fi

echo "Cleanup completed for resources with identifier: $IDENTIFIER"
# Turn off tracing for summary output if debug was enabled
if [ "$DEBUG" = "yes" ]; then
    set +x
fi