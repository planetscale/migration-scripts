#!/bin/bash
# start.sh - Initiates PostgreSQL to MySQL migration process for PlanetScale
set -e
set -x

# Create temp directory and ensure cleanup on exit
TMP="$(mktemp -d)"
trap "rm -f -r \"$TMP\"" EXIT INT QUIT TERM

# Display usage information
usage() {
    printf "Usage: sh %s --identifier \e[4midentifier\e[0m --source \e[4musername\e[0m:\e[4mpassword\e[0m@\e[4mhostname\e[0m/\e[4mdatabase\e[0m/\e[4mschema\e[0m [--debug]\n" "$(basename "$0")" >&2
    printf "  --identifier \e[4midentifier\e[0m  unique identifier for AWS resources\n" >&2
    printf "  --source \e[4mconnection\e[0m      source database connection string\n" >&2
    printf "  --debug                  enable verbose debugging output\n" >&2
    exit "$1"
}

# Parse command line arguments
IDENTIFIER=""
SOURCE=""
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
        "-s"|"--source")
            i=$((i + 1))
            eval "SOURCE=\${$i}"
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
if [ -z "$IDENTIFIER" -o -z "$SOURCE" ]
then usage 1
fi
if ! echo "$SOURCE" | grep -E -q '^[^:@/]+:[^:@]+@[^:@/]+/[^:@/]+/[^:@/]+$'
then usage 1
fi

# Parse source connection details
SOURCE_USERNAME="$(echo "$SOURCE" | cut -d":" -f"1")"
SOURCE_PASSWORD="$(echo "$SOURCE" | cut -d":" -f"2" | cut -d"@" -f"1")"
SOURCE_HOSTNAME="$(echo "$SOURCE" | cut -d"@" -f"2" | cut -d"/" -f"1")"
SOURCE_DATABASE="$(echo "$SOURCE" | cut -d"/" -f"2")"
SOURCE_SCHEMA="$(echo "$SOURCE" | cut -d"/" -f"3")"

# Load replication task ARN from file created by prepare.sh
TASK_ARN_FILE="$IDENTIFIER-task-arn.txt"
if [ -f "$TASK_ARN_FILE" ]; then
    REPLICATION_TASK_ARN=$(cat "$TASK_ARN_FILE")
    echo "Found Replication Task ARN: $REPLICATION_TASK_ARN"
else
    echo "Error: Could not find task ARN file $TASK_ARN_FILE"
    echo "Make sure you've run prepare.sh first and that you're using the same identifier."
    exit 1
fi

# Get target RDS MySQL instance information
TARGET_HOSTNAME=$(aws rds describe-db-instances \
    --db-instance-identifier "$IDENTIFIER-mysql" \
    --query "DBInstances[0].Endpoint.Address" \
    --output text)

if [ -z "$TARGET_HOSTNAME" ]; then
    echo "Error: Could not find MySQL instance. Make sure you've run prepare.sh first."
    exit 1
fi

echo "Found MySQL instance at: $TARGET_HOSTNAME"
echo "Enter the MySQL admin password:"
read -s TARGET_PASSWORD
echo

# Set MySQL connection parameters
TARGET_DATABASE="$SOURCE_SCHEMA"
TARGET_USERNAME="admin"

# Create MySQL client configuration file
cat > "$TMP/my.cnf" << EOF
[client]
user=$TARGET_USERNAME
password=$TARGET_PASSWORD
host=$TARGET_HOSTNAME
connect_timeout=30
EOF
chmod 600 "$TMP/my.cnf"

# Enable command tracing for debugging if requested
export PS4='+${BASH_SOURCE}:${LINENO}: '
if [ "$DEBUG" = "yes" ]; then
    echo "Debug mode enabled - showing all commands"
    set -ex
fi

# Start AWS DMS replication task if not already running
echo "Starting the replication task..."
aws dms describe-replication-tasks \
    --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN" \
    --output "text" \
    --query 'ReplicationTasks[].Status' |
grep "running" ||
aws dms start-replication-task \
    --output "text" \
    --query 'ReplicationTask.ReplicationTaskArn' \
    --replication-task-arn "$REPLICATION_TASK_ARN" \
    --start-replication-task-type "start-replication"

# Wait for replication task to reach running state
aws dms wait replication-task-running \
    --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN"

# Display detailed replication task information
aws dms describe-replication-tasks \
    --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN" |
cat

# Add primary key to DMS exceptions table for better performance
mysql --defaults-extra-file="$TMP/my.cnf" -e "ALTER TABLE $TARGET_DATABASE.awsdms_apply_exceptions ADD COLUMN surrogate_id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY FIRST;"

# Turn off tracing for summary output if debug was enabled
if [ "$DEBUG" = "yes" ]; then
    set +x
fi

# Update tracking table in PostgreSQL with 'copying' status
TS_COPYING="$(date +"%s")"
psql -a -d"$SOURCE_DATABASE" -h"$SOURCE_HOSTNAME" -U"$SOURCE_USERNAME" <<EOF
INSERT INTO _planetscale_import VALUES ($TS_COPYING, 'copying');
EOF

# Prompt user to redirect write traffic and wait for confirmation
echo >&2
echo "It's time to swing all your write traffic from the source database to the target database." >&2
read -p "Press <enter> once no more writes are being sent to the source database. " _

# Update tracking table with 'replicating' status after write traffic redirection
TS_REPLICATING="$(date +"%s")"
psql -a -d"$SOURCE_DATABASE" -h"$SOURCE_HOSTNAME" -U"$SOURCE_USERNAME" <<EOF
INSERT INTO _planetscale_import VALUES ($TS_REPLICATING, 'replicating');
EOF

# Query migration status table and display all timestamps/statuses
echo >&2
echo "Attempting to show timestamps and statuses from this migration:" >&2
if mysql --defaults-extra-file="$TMP/my.cnf" "$TARGET_DATABASE" 2>/dev/null <<EOF
SELECT * FROM _planetscale_import;
EOF
then
    echo "Successfully queried the database!"
else
    echo "Could not query the database directly. This is likely because:"
    echo "1. The migration is still in progress"
    echo "2. The security group rules haven't fully propagated yet"
    echo "3. Network connectivity issues between your location and the RDS instance"
    echo ""
    echo "Try manually connecting to the database after a few minutes:"
    echo "mysql -h $TARGET_HOSTNAME -u $TARGET_USERNAME -p $TARGET_DATABASE"
    echo "When prompted, enter password: $TARGET_PASSWORD"
fi

echo >&2
echo "======================================================================================"
echo "MIGRATION IN PROGRESS"
echo "======================================================================================"
echo "MySQL RDS instance information for PlanetScale import:" >&2
echo "Hostname: $TARGET_HOSTNAME" >&2
echo "Database: $TARGET_DATABASE" >&2
echo >&2
echo "You may now begin the migration on the PlanetScale side."
echo >&2
echo "======================================================================================"
echo "CLEANUP INSTRUCTIONS"
echo "======================================================================================"
echo "When you're satisfied with the migration, stop the replication task:" >&2
echo >&2
echo "    aws dms stop-replication-task --replication-task-arn \"$REPLICATION_TASK_ARN\""
echo >&2
echo "Then delete the AWS DMS infrastructure:" >&2
echo >&2
echo "    sh cleanup.sh --identifier \"$IDENTIFIER\""
echo >&2
echo "And finally, delete the RDS MySQL instance (once imported to PlanetScale):" >&2
echo >&2
echo "    aws rds delete-db-instance --db-instance-identifier \"$IDENTIFIER-mysql\" --skip-final-snapshot"
echo >&2
