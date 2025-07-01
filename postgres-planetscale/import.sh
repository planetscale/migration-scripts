set -e

TMP="$(mktemp -d)"
trap "rm -f -r \"$TMP\"" EXIT INT QUIT TERM

usage() {
    printf "Usage: sh %s [--debug] --identifier \e[4midentifier\e[0m [--init-only] --source \e[4musername\e[0m:\e[4mpassword\e[0m@\e[4mhostname\e[0m/\e[4mdatabase\e[0m/\e[4mschema\e[0m [--source-type \e[4mtype\e[0m] [--table-mappings \e[4mfilename\e[0m] --target \e[4musername\e[0m:\e[4mpassword\e[0m@\e[4mhostname\e[0m/\e[4mdatabase\e[0m[/\e[4mschema\e[0m] [--target-type \e[4mtype\e[0m] [--tls]\n" "$(basename "$0")" >&2
    printf "  --debug                                                enable debug mode with verbose command output\n" >&2
    printf "  --identifier \e[4midentifier\e[0m                                unique identifier for AWS DMS resources\n" >&2
    printf "  --init-only                                            exit after initializing the endpoints and replication instance, before creating the replication task\n" >&2
    printf "  --source \e[4musername\e[0m:\e[4mpassword\e[0m@\e[4mhostname\e[0m/\e[4mdatabase\e[0m/\e[4mschema\e[0m    connection parameters for the source Postgres database\n" >&2
    printf "  --source-type \e[4mtype\e[0m                                     \"mysql\" (not yet supported) or \"postgres\" (default)\n" >&2
    printf "  --target \e[4musername\e[0m:\e[4mpassword\e[0m@\e[4mhostname\e[0m/\e[4mdatabase\e[0m[/\e[4mschema\e[0m]  connection parameters for the target MySQL or Postgres database\n" >&2
    printf "  --target-type \e[4mtype\e[0m                                     \"mysql\" or \"postgres\" (default)\n" >&2
    printf "  --table-mappings \e[4mfilename\e[0m                              JSON file containing custom table mappings; see <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.CustomizingTasks.TableMapping.html>\n" >&2
    printf "  --tls                                                  use TLS to connect to the source Postgres database (the PlanetScale target always uses TLS)\n" >&2
    exit "$1"
}

DEBUG="" IDENTIFIER="" INIT_ONLY="" SOURCE="" SOURCE_TYPE="postgres" SSL_MODE="none" TABLE_MAPPINGS="" TARGET="" TARGET_TYPE="postgres"
while [ "$#" -gt 0 ]
do
    case "$1" in

        "-i"|"--identifier") IDENTIFIER="$2" shift 2;;
        "-i"*) IDENTIFIER="$(echo "$1" | cut -c"3-")" shift;;
        "--identifier="*) IDENTIFIER="$(echo "$1" | cut -d"=" -f"2-")" shift;;

        "--init-only") INIT_ONLY="$1" shift;;

        "-s"|"--source") SOURCE="$2" shift 2;;
        "-s"*) SOURCE="$(echo "$1" | cut -c"3-")" shift;;
        "--source="*) SOURCE="$(echo "$1" | cut -d"=" -f"2-")" shift;;

        "--source-type") SOURCE_TYPE="$2" shift 2;;
        "--source-type="*) SOURCE_TYPE="$(echo "$1" | cut -d"=" -f"2-")" shift;;

        "--table-mappings") TABLE_MAPPINGS="$2" shift 2;;
        "--table-mappings="*) TABLE_MAPPINGS="$(echo "$1" | cut -d"=" -f"2-")" shift;;

        "-t"|"--target") TARGET="$2" shift 2;;
        "-t"*) TARGET="$(echo "$1" | cut -c"3-")" shift;;
        "--target="*) TARGET="$(echo "$1" | cut -d"=" -f"2-")" shift;;

        "--target-type") TARGET_TYPE="$2" shift 2;;
        "--target-type="*) TARGET_TYPE="$(echo "$1" | cut -d"=" -f"2-")" shift;;

        "--tls") SSL_MODE="require" shift;;

        "-h"|"--help") usage 0;;
        *) usage 1;;
    esac
done
if [ -z "$IDENTIFIER" -o -z "$SOURCE" -o -z "$SOURCE_TYPE" -o -z "$TARGET" -o -z "$TARGET_TYPE" ]
then usage 1
fi
if ! echo "$SOURCE" | grep -E -q '^[^:@/]+:[^:@]+@[^:@/]+/[^:@/]+/[^:@/]+$'
then usage 1
fi
SOURCE_USERNAME="$(echo "$SOURCE" | cut -d":" -f"1")"
SOURCE_PASSWORD="$(echo "$SOURCE" | cut -d":" -f"2" | cut -d"@" -f"1")"
SOURCE_HOSTNAME="$(echo "$SOURCE" | cut -d"@" -f"2" | cut -d"/" -f"1")"
SOURCE_DATABASE="$(echo "$SOURCE" | cut -d"/" -f"2")"
SOURCE_SCHEMA="$(echo "$SOURCE" | cut -d"/" -f"3")"
case "$SOURCE_TYPE" in
    "postgres")
        SOURCE_PORT="5432"
        touch "$HOME/.pgpass"
        chmod 600 "$HOME/.pgpass"
        grep -q "$SOURCE_HOSTNAME:$SOURCE_PORT:$SOURCE_DATABASE:$SOURCE_USERNAME:$SOURCE_PASSWORD" "$HOME/.pgpass" ||
        echo "$SOURCE_HOSTNAME:$SOURCE_PORT:$SOURCE_DATABASE:$SOURCE_USERNAME:$SOURCE_PASSWORD" >>"$HOME/.pgpass";;
    *)
        echo "--source-type \"$SOURCE_TYPE\" not supported" >&2
        exit 1;;
esac
if [ "$TABLE_MAPPINGS" -a ! -f "$TABLE_MAPPINGS" ]
then
    echo "$TABLE_MAPPINGS: file not found" >&2
    exit 1
fi
if ! echo "$TARGET" | grep -E -q '^[^:@/]+:[^:@]+@[^:@/]+/[^:@/]+(/[^:@/]+)?$'
then usage 1
fi
TARGET_USERNAME="$(echo "$TARGET" | cut -d":" -f"1")"
TARGET_PASSWORD="$(echo "$TARGET" | cut -d":" -f"2" | cut -d"@" -f"1")"
TARGET_HOSTNAME="$(echo "$TARGET" | cut -d"@" -f"2" | cut -d"/" -f"1")"
TARGET_DATABASE="$(echo "$TARGET" | cut -d"/" -f"2")"
TARGET_SCHEMA="$(echo "$TARGET" | cut -d"/" -f"3")"
case "$TARGET_TYPE" in
    "mysql")
        TARGET_PORT="3306" TARGET_SCHEMA="$TARGET_DATABASE"
        touch "$TMP/my.cnf"
        chmod 600 "$TMP/my.cnf"
        printf "[client]\npassword=$TARGET_PASSWORD\n" >"$TMP/my.cnf";;
    "postgres")
        TARGET_PORT="5432"
        touch "$HOME/.pgpass"
        chmod 600 "$HOME/.pgpass"
        grep -q "$TARGET_HOSTNAME:$TARGET_PORT:$TARGET_DATABASE:$TARGET_USERNAME:$TARGET_PASSWORD" "$HOME/.pgpass" ||
        echo "$TARGET_HOSTNAME:$TARGET_PORT:$TARGET_DATABASE:$TARGET_USERNAME:$TARGET_PASSWORD" >>"$HOME/.pgpass";;
    *)
        echo "--target-type \"$TARGET_TYPE\" not supported" >&2
        exit 1;;
esac

ENGINE_VERSION="3.5.4" # <https://repost.aws/questions/QU0yHDr_2aRrOZ3dm2dPxYqA/dms-support-for-postgres-17>
INSTANCE_TYPE="dms.c6i.large"
SECURITY_GROUP_ID="sg-060268212560188ba" # rcrowley in us-east-1 playground

if [ "$DEBUG" ]
then set -x
fi

echo "Creating tracking table in source database..."
TS_INITIALIZING="$(date +"%s")"
psql -a -d"$SOURCE_DATABASE" -h"$SOURCE_HOSTNAME" -U"$SOURCE_USERNAME" <<EOF
CREATE TABLE IF NOT EXISTS _planetscale_import (ts BIGINT PRIMARY KEY, status VARCHAR(255));
INSERT INTO _planetscale_import VALUES ($TS_INITIALIZING, 'initializing');
EOF

echo "Setting up AWS DMS endpoints..."
SOURCE_ENDPOINT_ARN="$(
    aws dms create-endpoint \
        --database-name "$SOURCE_DATABASE" \
        --endpoint-identifier "$IDENTIFIER-source" \
        --endpoint-type "source" \
        --engine-name "postgres" \
        --output "text" \
        --password "$(
            if echo "$SOURCE_HOSTNAME" | grep -q '.neon.tech$' # <https://neon.tech/docs/import/migrate-aws-dms>
            then echo "endpoint=$(echo "$SOURCE_HOSTNAME" | cut -d"." -f"1")\$"
            fi
        )$SOURCE_PASSWORD" \
        --port "$SOURCE_PORT" \
        --postgre-sql-settings '{"CaptureDdls":false,"PluginName":"test_decoding"}' \
        --query 'Endpoint.EndpointArn' \
        --server-name "$SOURCE_HOSTNAME" \
        --ssl-mode "$SSL_MODE" \
        --username "$SOURCE_USERNAME" ||
    aws dms describe-endpoints \
        --filters Name="endpoint-id",Values="$IDENTIFIER-source" \
        --output "text" \
        --query 'Endpoints[].EndpointArn'
)"
[ "$SOURCE_ENDPOINT_ARN" ]
aws dms modify-endpoint \
    --database-name "$SOURCE_DATABASE" \
    --endpoint-arn "$SOURCE_ENDPOINT_ARN" \
    --endpoint-identifier "$IDENTIFIER-source" \
    --endpoint-type "source" \
    --engine-name "postgres" \
    --output "text" \
    --password "$(
        if echo "$SOURCE_HOSTNAME" | grep -q '.neon.tech$' # <https://neon.tech/docs/import/migrate-aws-dms>
        then echo "endpoint=$(echo "$SOURCE_HOSTNAME" | cut -d"." -f"1")\$"
        fi
    )$SOURCE_PASSWORD" \
    --port "$SOURCE_PORT" \
    --postgre-sql-settings '{"CaptureDdls":false,"PluginName":"test_decoding"}' \
    --query 'Endpoint.EndpointArn' \
    --server-name "$SOURCE_HOSTNAME" \
    --ssl-mode "$SSL_MODE" \
    --username "$SOURCE_USERNAME"
TARGET_ENDPOINT_ARN="$(
    aws dms create-endpoint \
        $([ "$TARGET_TYPE" = "postgres" ] && echo "--database-name" "$TARGET_DATABASE") \
        --endpoint-identifier "$IDENTIFIER-target" \
        --endpoint-type "target" \
        --engine-name "$TARGET_TYPE" \
        --extra-connection-attributes "$([ "$TARGET_TYPE" = "mysql" ] && echo "Initstmt=SET FOREIGN_KEY_CHECKS=0;")loadUsingCSV=false;parallelLoadThreads=16;" \
        --output "text" \
        --password "$TARGET_PASSWORD" \
        --port "$TARGET_PORT" \
        --postgre-sql-settings "{$([ "$TARGET_TYPE" = "postgres" ] && echo '"AfterConnectScript":"SET session_replication_role=replica;"')}" \
        --query 'Endpoint.EndpointArn' \
        --server-name "$TARGET_HOSTNAME" \
        --ssl-mode "$([ "$TARGET_TYPE" = "mysql" ] && echo "none" || echo "$SSL_MODE")" \
        --username "$TARGET_USERNAME" ||
    aws dms describe-endpoints \
        --filters Name="endpoint-id",Values="$IDENTIFIER-target" \
        --output "text" \
        --query 'Endpoints[].EndpointArn'
)"
[ "$TARGET_ENDPOINT_ARN" ]
aws dms modify-endpoint \
    $([ "$TARGET_TYPE" = "postgres" ] && echo "--database-name" "$TARGET_DATABASE") \
    --endpoint-arn "$TARGET_ENDPOINT_ARN" \
    --endpoint-identifier "$IDENTIFIER-target" \
    --endpoint-type "target" \
    --engine-name "$TARGET_TYPE" \
    --extra-connection-attributes "$([ "$TARGET_TYPE" = "mysql" ] && echo "Initstmt=SET FOREIGN_KEY_CHECKS=0;")loadUsingCSV=false;parallelLoadThreads=16;" \
    --output "text" \
    --password "$TARGET_PASSWORD" \
    --port "$TARGET_PORT" \
    --postgre-sql-settings "{$([ "$TARGET_TYPE" = "postgres" ] && echo '"AfterConnectScript":"SET session_replication_role=replica;"')}" \
    --query 'Endpoint.EndpointArn' \
    --server-name "$TARGET_HOSTNAME" \
    --ssl-mode "$([ "$TARGET_TYPE" = "mysql" ] && echo "none" || echo "$SSL_MODE")" \
    --username "$TARGET_USERNAME"

echo "Creating replication subnet group..."
aws ec2 describe-subnets \
    --filters \
        Name="map-public-ip-on-launch",Values="true" \
        Name="default-for-az",Values="true" \
        Name="vpc-id",Values="$(aws ec2 describe-vpcs \
            --filters Name="is-default",Values="true" \
            --output "text" \
            --query 'Vpcs[].VpcId')" \
    --output "text" \
    --query 'Subnets[?AvailabilityZoneId != `use1-az3`].SubnetId' >"$TMP/subnet-ids.txt"
xargs aws dms create-replication-subnet-group \
    --output "text" \
    --query 'ReplicationSubnetGroup.ReplicationSubnetGroupIdentifier' \
    --replication-subnet-group-description "$IDENTIFIER" \
    --replication-subnet-group-identifier "$IDENTIFIER" \
    --subnet-ids <"$TMP/subnet-ids.txt" ||
xargs aws dms modify-replication-subnet-group \
    --output "text" \
    --query 'ReplicationSubnetGroup.ReplicationSubnetGroupIdentifier' \
    --replication-subnet-group-description "$IDENTIFIER" \
    --replication-subnet-group-identifier "$IDENTIFIER" \
    --subnet-ids <"$TMP/subnet-ids.txt"

echo "Creating replication instance..."
REPLICATION_INSTANCE_ARN="$(
    aws dms create-replication-instance \
        --engine-version "$ENGINE_VERSION" \
        --output "text" \
        --query 'ReplicationInstance.ReplicationInstanceArn' \
        --replication-instance-class "$INSTANCE_TYPE" \
        --replication-instance-identifier "$IDENTIFIER" \
        --replication-subnet-group-identifier "$IDENTIFIER" \
        --vpc-security-group-ids "$SECURITY_GROUP_ID" ||
    aws dms describe-replication-instances \
        --filters Name="replication-instance-id",Values="$IDENTIFIER" \
        --output "text" \
        --query 'ReplicationInstances[].ReplicationInstanceArn'
)"
[ "$REPLICATION_INSTANCE_ARN" ]
aws dms wait replication-instance-available \
    --filters Name="replication-instance-arn",Values="$REPLICATION_INSTANCE_ARN"
aws dms modify-replication-instance \
    --allow-major-version-upgrade \
    --engine-version "$ENGINE_VERSION" \
    --output "text" \
    --query 'ReplicationInstance.ReplicationInstanceArn' \
    --replication-instance-arn "$REPLICATION_INSTANCE_ARN" \
    --replication-instance-class "$INSTANCE_TYPE" \
    --replication-instance-identifier "$IDENTIFIER" \
    --vpc-security-group-ids "$SECURITY_GROUP_ID"
aws dms wait replication-instance-available \
    --filters Name="replication-instance-arn",Values="$REPLICATION_INSTANCE_ARN"

echo "Testing source endpoint connection..."
aws dms describe-connections \
    --filters \
        Name="endpoint-arn",Values="$SOURCE_ENDPOINT_ARN" \
        Name="replication-instance-arn",Values="$REPLICATION_INSTANCE_ARN" \
    --output "text" \
    --query 'Connections[].Status' |
grep "testing" ||
aws dms test-connection \
    --endpoint-arn "$SOURCE_ENDPOINT_ARN" \
    --output "text" \
    --query 'Connection.Status' \
    --replication-instance-arn "$REPLICATION_INSTANCE_ARN"
aws dms wait test-connection-succeeds --filters \
    Name="endpoint-arn",Values="$SOURCE_ENDPOINT_ARN" \
    Name="replication-instance-arn",Values="$REPLICATION_INSTANCE_ARN" || {
    aws dms describe-connections --filters \
        Name="endpoint-arn",Values="$SOURCE_ENDPOINT_ARN" \
        Name="replication-instance-arn",Values="$REPLICATION_INSTANCE_ARN" |
    jq -e '.'
    exit 1
}
echo "Testing target endpoint connection..."
aws dms describe-connections \
    --filters \
        Name="endpoint-arn",Values="$TARGET_ENDPOINT_ARN" \
        Name="replication-instance-arn",Values="$REPLICATION_INSTANCE_ARN" \
    --output "text" \
    --query 'Connections[].Status' |
grep "testing" ||
aws dms test-connection \
    --endpoint-arn "$TARGET_ENDPOINT_ARN" \
    --output "text" \
    --query 'Connection.Status' \
    --replication-instance-arn "$REPLICATION_INSTANCE_ARN"
aws dms wait test-connection-succeeds --filters \
    Name="endpoint-arn",Values="$TARGET_ENDPOINT_ARN" \
    Name="replication-instance-arn",Values="$REPLICATION_INSTANCE_ARN" || {
    aws dms describe-connections --filters \
        Name="endpoint-arn",Values="$TARGET_ENDPOINT_ARN" \
        Name="replication-instance-arn",Values="$REPLICATION_INSTANCE_ARN" |
    jq -e '.'
    exit 1
}

if [ "$INIT_ONLY" ]
then exit
fi

echo "Updating status to 'copying'..."
TS_COPYING="$(date +"%s")"
psql -a -d"$SOURCE_DATABASE" -h"$SOURCE_HOSTNAME" -U"$SOURCE_USERNAME" <<EOF
INSERT INTO _planetscale_import VALUES ($TS_COPYING, 'copying');
EOF

echo "Configuring replication task settings..."
# <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.CustomizingTasks.TaskSettings.html>
tee "$TMP/replication-task-settings.json" <<EOF
{
    "ChangeProcessingDdlHandlingPolicy": {
        "HandleSourceTableAltered": true,
        "HandleSourceTableDropped": true,
        "HandleSourceTableTruncated": true
    },
    "FullLoadSettings": {
        "MaxFullLoadSubTasks": 16,
        "TargetTablePrepMode": "DROP_AND_CREATE"
    },
    "Logging": {
        "EnableLogging": true,
        "LogComponents": [
            {"Id": "FILE_FACTORY", "Severity": "LOGGER_SEVERITY_DEFAULT"},
            {"Id": "METADATA_MANAGER", "Severity": "LOGGER_SEVERITY_DEFAULT"},
            {"Id": "SORTER", "Severity": "LOGGER_SEVERITY_DEFAULT"},
            {"Id": "SOURCE_CAPTURE", "Severity": "LOGGER_SEVERITY_DEFAULT"},
            {"Id": "SOURCE_UNLOAD", "Severity": "LOGGER_SEVERITY_DEFAULT"},
            {"Id": "TABLES_MANAGER", "Severity": "LOGGER_SEVERITY_DEFAULT"},
            {"Id": "TARGET_APPLY", "Severity": "LOGGER_SEVERITY_DEFAULT"},
            {"Id": "TARGET_LOAD", "Severity": "LOGGER_SEVERITY_DEFAULT"},
            {"Id": "TASK_MANAGER", "Severity": "LOGGER_SEVERITY_DEFAULT"},
            {"Id": "TRANSFORMATION", "Severity": "LOGGER_SEVERITY_DEFAULT"},
            {"Id": "VALIDATOR_EXT", "Severity": "LOGGER_SEVERITY_DEFAULT"}
        ]
    },
    "TargetMetadata": {
        "FullLobMode": true,
        "InlineLobMaxSize": 0,
        "LimitedSizeLobMode": false,
        "LobChunkSize": 64,
        "SupportLobs": true
    }
}
EOF
# <https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.CustomizingTasks.TableMapping.SelectionTransformation.html>
tee "$TMP/table-mappings.json" <<EOF
{
    "rules": [
        {
            "object-locator": {
                "schema-name": "$SOURCE_SCHEMA",
                "table-name": "%"
            },
            "rule-action": "include",
            "rule-id": "1",
            "rule-name": "include-all",
            "rule-type": "selection"
EOF
if [ "$SOURCE_SCHEMA" != "$TARGET_SCHEMA" -a "$TARGET_SCHEMA" ]
then tee -a "$TMP/table-mappings.json" <<EOF
        },
        {
            "object-locator": {
                "schema-name": "$SOURCE_SCHEMA",
                "table-name": "%"
            },
            "rule-action": "rename",
            "rule-id": "2",
            "rule-name": "rename-schema",
            "rule-target": "schema",
            "rule-type": "transformation",
            "value": "$TARGET_SCHEMA"
EOF
fi
tee -a "$TMP/table-mappings.json" <<EOF
        }
    ]
}
EOF
if [ "$TABLE_MAPPINGS" ]
then
    mv "$TMP/table-mappings.json" "$TMP/base-table-mappings.json"
    jq -s '{"rules": (.[0].rules + .[1].rules)}' \
        "$TMP/base-table-mappings.json" "$TABLE_MAPPINGS" |
    tee "$TMP/table-mappings.json"
fi
echo "Creating replication task..."
REPLICATION_TASK_ARN="$(
    aws dms create-replication-task \
        --migration-type "full-load-and-cdc" \
        --output "text" \
        --query 'ReplicationTask.ReplicationTaskArn' \
        --replication-instance-arn "$REPLICATION_INSTANCE_ARN" \
        --replication-task-identifier "$IDENTIFIER" \
        --replication-task-settings "file://$TMP/replication-task-settings.json" \
        --source-endpoint-arn "$SOURCE_ENDPOINT_ARN" \
        --table-mappings "file://$TMP/table-mappings.json" \
        --target-endpoint-arn "$TARGET_ENDPOINT_ARN" ||
    aws dms describe-replication-tasks \
        --filters Name="replication-task-id",Values="$IDENTIFIER" \
        --output "text" \
        --query 'ReplicationTasks[].ReplicationTaskArn'
)"
[ "$REPLICATION_TASK_ARN" ]
aws dms describe-replication-tasks \
    --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN" \
    --output "text" \
    --query 'ReplicationTasks[].Status' |
grep "running" ||
aws dms wait replication-task-ready \
    --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN"
aws dms modify-replication-task \
    --migration-type "full-load-and-cdc" \
    --output "text" \
    --query 'ReplicationTask.ReplicationTaskArn' \
    --replication-task-arn "$REPLICATION_TASK_ARN" \
    --replication-task-identifier "$IDENTIFIER" \
    --replication-task-settings "file://$TMP/replication-task-settings.json" \
    --table-mappings "file://$TMP/table-mappings.json"
while aws dms describe-replication-tasks \
    --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN" \
    --output "text" \
    --query 'ReplicationTasks[].Status' |
grep -q "modifying"
do sleep 10
done
aws dms describe-replication-tasks \
    --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN" \
    --output "text" \
    --query 'ReplicationTasks[].Status' |
grep "running" ||
aws dms wait replication-task-ready \
    --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN"

aws dms describe-replication-tasks \
    --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN" \
    --output "text" \
    --query 'ReplicationTasks[].Status' |
grep "running" ||
echo "Starting replication task..."
aws dms start-replication-task \
    --output "text" \
    --query 'ReplicationTask.ReplicationTaskArn' \
    --replication-task-arn "$REPLICATION_TASK_ARN" \
    --start-replication-task-type "start-replication"
aws dms wait replication-task-running \
    --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN"

aws dms describe-replication-tasks \
    --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN" |
jq -e '.'

set +x

echo >&2
echo "It's time to swing all your write traffic from the source database to the target database." >&2
read -p "Press <enter> once no more writes are being sent to the source database. " _

echo "Setting replication marker..."
TS_REPLICATING="$(date +"%s")"
psql -a -d"$SOURCE_DATABASE" -h"$SOURCE_HOSTNAME" -U"$SOURCE_USERNAME" <<EOF
INSERT INTO _planetscale_import VALUES ($TS_REPLICATING, 'replicating');
EOF
echo "Waiting for replication marker to appear in target database..."
while sleep 1
do
    if echo "SELECT * FROM _planetscale_import WHERE ts = $TS_REPLICATING AND status = 'replicating';" |
    case "$TARGET_TYPE" in
        "mysql") mysql --defaults-extra-file="$TMP/my.cnf" -h"$TARGET_HOSTNAME" -u"$TARGET_USERNAME" "$TARGET_DATABASE";;
        "postgres") psql -d"$TARGET_DATABASE" -h"$TARGET_HOSTNAME" -U"$TARGET_USERNAME";;
    esac |
    grep -q "replicating"
    then break
    fi
done

echo >&2
echo "Timestamps and statuses from this migration:" >&2
case "$TARGET_TYPE" in
    "mysql") mysql --defaults-extra-file="$TMP/my.cnf" -h"$TARGET_HOSTNAME" -u"$TARGET_USERNAME" "$TARGET_DATABASE";;
    "postgres") psql -a -d"$TARGET_DATABASE" -h"$TARGET_HOSTNAME" -U"$TARGET_USERNAME";;
esac <<EOF
SELECT * FROM _planetscale_import WHERE ts >= $TS_INITIALIZING;
EOF

echo >&2
echo "When you're satisfied with the migration, stop and delete the replication task:" >&2
echo >&2
echo "    sh cleanup.sh --identifier \"$IDENTIFIER\" --task-only"
echo >&2
echo "Then delete the AWS DMS infrastructure (or skip straight here to do both in one step):" >&2
echo >&2
echo "    sh cleanup.sh --identifier \"$IDENTIFIER\""
echo >&2
