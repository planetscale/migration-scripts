#!/bin/bash
# prepare.sh - Sets up AWS resources for PostgreSQL to MySQL migration for PlanetScale
set -e

# Create temp directory and ensure cleanup on exit
TMP="$(mktemp -d)"
trap "rm -f -r \"$TMP\"" EXIT INT QUIT TERM

# Add PlanetScale migration IPs for different AWS regions
source ./planetscale_region_ips.sh

# Display usage information
usage() {
    printf "Usage: sh %s --identifier \e[4midentifier\e[0m --source \e[4musername\e[0m:\e[4mpassword\e[0m@\e[4mhostname\e[0m/\e[4mdatabase\e[0m/\e[4mschema\e[0m --ips \e[4mregion_or_manual\e[0m [--debug]\n" "$(basename "$0")" >&2
    printf "  --identifier \e[4midentifier\e[0m  unique identifier for AWS resources\n" >&2
    printf "  --source \e[4mconnection\e[0m      source database connection string\n" >&2
    printf "  --ips \e[4mregion_or_manual\e[0m   AWS region (e.g., us-east-1) or 'manual' for custom IPs\n" >&2
    printf "  --debug                  enable verbose debugging output\n" >&2
    exit "$1"
}

# Parse command line arguments
IDENTIFIER=""
SOURCE=""
IPS_OPTION=""
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
        "-i"|"--ips")
            i=$((i + 1))
            eval "IPS_OPTION=\${$i}"
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
if [ -z "$IDENTIFIER" -o -z "$SOURCE" -o -z "$IPS_OPTION" ]
then usage 1
fi
if ! echo "$SOURCE" | grep -E -q '^[^:@/]+:[^:@]+@[^:@/]+/[^:@/]+/[^:@/]+$'
then usage 1
fi

# Handle IPs option - either region or manual
if [ "$IPS_OPTION" = "manual" ]; then
    echo "Manual IP mode selected. Please enter a comma-separated list of IP addresses:"
    read -r USER_IPS
    if [ -z "$USER_IPS" ]; then
        echo "Error: No IP addresses provided."
        exit 1
    fi
    # Convert comma-separated list to space-separated for consistency
    PLANETSCALE_IPS=$(echo "$USER_IPS" | tr ',' ' ')
    REGION_FOR_DISPLAY="manual"
else
    # Check if the specified region is valid
    if [[ -z "${PLANETSCALE_REGION_IPS[$IPS_OPTION]}" ]]; then
        echo "Error: Invalid AWS region specified or 'manual' not used. Valid options are:"
        echo "AWS: us-east-1, us-east-2, us-west-2, eu-west-1, eu-west-2, eu-central-1, ap-south-1, ap-southeast-1, ap-southeast-2, ap-northeast-1, sa-east-1"
        echo "GCP: us-central1, us-east4, northamerica-northeast1, asia-northeast3"
        echo "Or use 'manual' to specify custom IP addresses"
        exit 1
    fi
    # Get the IPs for the specified region
    PLANETSCALE_IPS=${PLANETSCALE_REGION_IPS[$IPS_OPTION]}
    REGION_FOR_DISPLAY="$IPS_OPTION"
fi

# Get the current instance's public and private IPs using multiple fallback methods
CURRENT_INSTANCE_PUBLIC_IP=""
CURRENT_INSTANCE_PRIVATE_IP=""

# Method 1: EC2 metadata service with curl (IMDSv1)
if command -v curl &> /dev/null && [ -z "$CURRENT_INSTANCE_PUBLIC_IP" ]; then
    TEMP_PUBLIC_IP=$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")
    TEMP_PRIVATE_IP=$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || echo "")
    # Validate IP format before using
    if echo "$TEMP_PUBLIC_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        CURRENT_INSTANCE_PUBLIC_IP="$TEMP_PUBLIC_IP"
    fi
    if echo "$TEMP_PRIVATE_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        CURRENT_INSTANCE_PRIVATE_IP="$TEMP_PRIVATE_IP"
    fi
fi

# Method 2: EC2 metadata service with curl (IMDSv2)
if command -v curl &> /dev/null && [ -z "$CURRENT_INSTANCE_PUBLIC_IP" ]; then
    TOKEN=$(curl -s --connect-timeout 2 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || echo "")
    if [ -n "$TOKEN" ] && echo "$TOKEN" | grep -qvE '^<'; then
        TEMP_PUBLIC_IP=$(curl -s --connect-timeout 2 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")
        TEMP_PRIVATE_IP=$(curl -s --connect-timeout 2 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || echo "")
        # Validate IP format before using
        if echo "$TEMP_PUBLIC_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
            CURRENT_INSTANCE_PUBLIC_IP="$TEMP_PUBLIC_IP"
        fi
        if echo "$TEMP_PRIVATE_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
            CURRENT_INSTANCE_PRIVATE_IP="$TEMP_PRIVATE_IP"
        fi
    fi
fi

# Method 3: EC2 metadata service with wget
if command -v wget &> /dev/null && [ -z "$CURRENT_INSTANCE_PUBLIC_IP" ]; then
    TEMP_PUBLIC_IP=$(wget -q -O - http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")
    TEMP_PRIVATE_IP=$(wget -q -O - http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || echo "")
    # Validate IP format before using
    if echo "$TEMP_PUBLIC_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        CURRENT_INSTANCE_PUBLIC_IP="$TEMP_PUBLIC_IP"
    fi
    if echo "$TEMP_PRIVATE_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        CURRENT_INSTANCE_PRIVATE_IP="$TEMP_PRIVATE_IP"
    fi
fi

# Display security information
echo "=========================================================================="
echo "SECURITY INFORMATION"
echo "=========================================================================="
echo
echo "This script prepares for a migration between your postgres source and a new"
echo "MySQL database. The MySQL database will be accessible from:"
echo "  - PlanetScale migration IPs for region/mode $REGION_FOR_DISPLAY"
if [ -n "$CURRENT_INSTANCE_PUBLIC_IP" ]; then
    echo "  - Current EC2 instance public IP ($CURRENT_INSTANCE_PUBLIC_IP)"
else
    echo "  - Warning: Could not detect current EC2 instance public IP. Make sure you're running this on an EC2 instance."
fi
if [ -n "$CURRENT_INSTANCE_PRIVATE_IP" ]; then
    echo "  - Current EC2 instance private IP ($CURRENT_INSTANCE_PRIVATE_IP)"
fi
echo "  - DMS migration instance public and private IPs (added automatically during setup)"
echo
echo "If you would like to continue, type yes"
echo

read -r CONFIRMATION

if [ "$CONFIRMATION" != "yes" ]; then
    echo "Exiting script as requested."
    exit 1
fi

echo "Proceeding with script execution..."
echo

# Parse source connection details
SOURCE_USERNAME="$(echo "$SOURCE" | cut -d":" -f"1")"
SOURCE_PASSWORD="$(echo "$SOURCE" | cut -d":" -f"2" | cut -d"@" -f"1")"
SOURCE_HOSTNAME="$(echo "$SOURCE" | cut -d"@" -f"2" | cut -d"/" -f"1")"
SOURCE_DATABASE="$(echo "$SOURCE" | cut -d"/" -f"2")"
SOURCE_SCHEMA="$(echo "$SOURCE" | cut -d"/" -f"3")"

# Add PostgreSQL credentials to ~/.pgpass for passwordless connections
grep -q "$SOURCE_HOSTNAME:5432:$SOURCE_DATABASE:$SOURCE_USERNAME:$SOURCE_PASSWORD" "$HOME/.pgpass" ||
echo "$SOURCE_HOSTNAME:5432:$SOURCE_DATABASE:$SOURCE_USERNAME:$SOURCE_PASSWORD" >>"$HOME/.pgpass"
chmod 600 "$HOME/.pgpass"

# Set AWS DMS replication instance parameters
echo "Setting up AWS DMS replication parameters..."
ENGINE_VERSION="3.5.4" # <https://repost.aws/questions/QU0yHDr_2aRrOZ3dm2dPxYqA/dms-support-for-postgres-17>
INSTANCE_TYPE="dms.r6i.xlarge"

# Enable command tracing for debugging if requested
export PS4='+${BASH_SOURCE}:${LINENO}: '
if [ "$DEBUG" = "yes" ]; then
    echo "Debug mode enabled - showing all commands"
    set -ex
fi

# Create tracking table in source PostgreSQL database
TS_INITIALIZING="$(date +"%s")"
psql -a -d"$SOURCE_DATABASE" -h"$SOURCE_HOSTNAME" -U"$SOURCE_USERNAME" <<EOF
CREATE TABLE IF NOT EXISTS _planetscale_import (ts BIGINT PRIMARY KEY, status VARCHAR(255));
INSERT INTO _planetscale_import VALUES ($TS_INITIALIZING, 'initializing');
EOF

# Generate credentials for target MySQL database
TARGET_PASSWORD="$(cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | fold -w 20 | head -n 1)"
TARGET_USERNAME="admin"
TARGET_DATABASE="$SOURCE_SCHEMA"

# Create security group for database access
echo "Creating security group for database access..."
DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)

SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name "$IDENTIFIER-db-access" \
    --description "Security group for $IDENTIFIER database access" \
    --vpc-id "$DEFAULT_VPC_ID" \
    --output text \
    --query "GroupId")

# PLANETSCALE_IPS is already set above based on the IPs option

# Create the security group rules - one for each PlanetScale IP
for IP in $PLANETSCALE_IPS; do
    aws ec2 authorize-security-group-ingress \
        --group-id "$SECURITY_GROUP_ID" \
        --protocol tcp \
        --port 3306 \
        --cidr "$IP/32"
done

# Add current EC2 instance IPs if available
if [ -n "$CURRENT_INSTANCE_PUBLIC_IP" ]; then
    aws ec2 authorize-security-group-ingress \
        --group-id "$SECURITY_GROUP_ID" \
        --protocol tcp \
        --port 3306 \
        --cidr "$CURRENT_INSTANCE_PUBLIC_IP/32"
fi

if [ -n "$CURRENT_INSTANCE_PRIVATE_IP" ]; then
    aws ec2 authorize-security-group-ingress \
        --group-id "$SECURITY_GROUP_ID" \
        --protocol tcp \
        --port 3306 \
        --cidr "$CURRENT_INSTANCE_PRIVATE_IP/32"
fi

echo "Created security group $SECURITY_GROUP_ID with rules for MySQL access from PlanetScale IPs in $REGION_FOR_DISPLAY"

# Create Aurora MySQL parameter groups
echo "Creating parameter groups with appropriate settings..."
CLUSTER_PARAM_GROUP_NAME="$IDENTIFIER-aurora-cluster-params"
DB_PARAM_GROUP_NAME="$IDENTIFIER-aurora-db-params"

# Create cluster parameter group with required settings for replication
aws rds create-db-cluster-parameter-group \
    --db-cluster-parameter-group-name "$CLUSTER_PARAM_GROUP_NAME" \
    --db-parameter-group-family "aurora-mysql8.0" \
    --description "Cluster parameter group for $IDENTIFIER" \
    --output json

# Configure cluster parameters for binlog and character sets
aws rds modify-db-cluster-parameter-group \
    --db-cluster-parameter-group-name "$CLUSTER_PARAM_GROUP_NAME" \
    --parameters \
        "ParameterName=binlog_format,ParameterValue=ROW,ApplyMethod=pending-reboot" \
        "ParameterName=character_set_server,ParameterValue=utf8mb4,ApplyMethod=pending-reboot" \
        "ParameterName=collation_server,ParameterValue=utf8mb4_unicode_ci,ApplyMethod=pending-reboot" \
        "ParameterName=enforce_gtid_consistency,ParameterValue=ON,ApplyMethod=pending-reboot" \
        "ParameterName=gtid-mode,ParameterValue=ON,ApplyMethod=pending-reboot" \
        "ParameterName=sql_mode,ParameterValue=\"NO_ZERO_IN_DATE,NO_ZERO_DATE,ONLY_FULL_GROUP_BY\",ApplyMethod=immediate"

# Create instance parameter group
aws rds create-db-parameter-group \
    --db-parameter-group-name "$DB_PARAM_GROUP_NAME" \
    --db-parameter-group-family "aurora-mysql8.0" \
    --description "DB parameter group for $IDENTIFIER" \
    --output json

# Create Aurora MySQL cluster
CLUSTER_IDENTIFIER="$IDENTIFIER-aurora"
aws rds create-db-cluster \
    --db-cluster-identifier "$CLUSTER_IDENTIFIER" \
    --engine "aurora-mysql" \
    --engine-version "8.0.mysql_aurora.3.04.1" \
    --master-username "$TARGET_USERNAME" \
    --master-user-password "$TARGET_PASSWORD" \
    --vpc-security-group-ids "$SECURITY_GROUP_ID" \
    --db-subnet-group-name "default" \
    --database-name "$TARGET_DATABASE" \
    --port 3306 \
    --backup-retention-period 1 \
    --db-cluster-parameter-group-name "$CLUSTER_PARAM_GROUP_NAME" \
    --output json

echo "Waiting for Aurora cluster to be created..."
aws rds wait db-cluster-available --db-cluster-identifier "$CLUSTER_IDENTIFIER"

# Create Aurora instance within the cluster
RDS_INSTANCE=$(aws rds create-db-instance \
    --db-instance-identifier "$IDENTIFIER-mysql" \
    --db-cluster-identifier "$CLUSTER_IDENTIFIER" \
    --db-instance-class "db.r6g.large" \
    --engine "aurora-mysql" \
    --db-parameter-group-name "$DB_PARAM_GROUP_NAME" \
    --publicly-accessible \
    --output json)

echo "Waiting for RDS instance to become available..."
aws rds wait db-instance-available --db-instance-identifier "$IDENTIFIER-mysql"

# Get endpoint for MySQL instance
TARGET_HOSTNAME=$(aws rds describe-db-instances \
    --db-instance-identifier "$IDENTIFIER-mysql" \
    --query "DBInstances[0].Endpoint.Address" \
    --output text)

# Create MySQL client config file
cat > "$TMP/my.cnf" << EOF
[client]
user=$TARGET_USERNAME
password=$TARGET_PASSWORD
host=$TARGET_HOSTNAME
connect_timeout=30
EOF
chmod 600 "$TMP/my.cnf"

# Configure binlog retention for replication
echo "Setting binlog retention period to 48 hours..."
counter=0
max_attempts=10
while [ $counter -lt $max_attempts ]; do
    if mysql --defaults-extra-file="$TMP/my.cnf" -e "CALL mysql.rds_set_configuration('binlog retention hours', 48);" 2>/dev/null; then
        echo "Successfully set binlog retention to 48 hours"
        break
    else
        echo "Retrying binlog retention configuration in 15 seconds... (Attempt $((counter+1))/$max_attempts)"
        sleep 15
        counter=$((counter + 1))
    fi
done

# Set character set for MySQL database
echo "Setting character set and collation for database..."
mysql --defaults-extra-file="$TMP/my.cnf" -e "ALTER DATABASE $TARGET_DATABASE CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci;"

# Create PlanetScale migration user with required permissions
echo "Creating migration user for PlanetScale..."
MIGRATION_PASSWORD="${TARGET_PASSWORD}_migration"
mysql --defaults-extra-file="$TMP/my.cnf" <<EOF
CREATE USER 'migration_user'@'%' IDENTIFIED BY '${MIGRATION_PASSWORD}';
GRANT PROCESS, REPLICATION SLAVE, REPLICATION CLIENT, RELOAD ON *.* TO 'migration_user'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE, SHOW VIEW, LOCK TABLES ON \`${TARGET_DATABASE}\`.* TO 'migration_user'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER ON \`ps\\_import\\_%\`.* TO 'migration_user'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER ON \`_vt\`.* TO 'migration_user'@'%';
GRANT SELECT ON \`mysql\`.\`func\` TO 'migration_user'@'%';
GRANT EXECUTE ON PROCEDURE mysql.rds_show_configuration TO 'migration_user'@'%';
FLUSH PRIVILEGES;
EOF
echo "Migration user created with password: ${MIGRATION_PASSWORD}"

# Apply security group to the Aurora cluster
aws rds modify-db-cluster \
    --db-cluster-identifier "$CLUSTER_IDENTIFIER" \
    --vpc-security-group-ids "$SECURITY_GROUP_ID" \
    --apply-immediately

echo "Updated Aurora cluster to use security group allowing connections from PlanetScale migration IPs"

# Wait for changes to propagate
echo "Waiting for security group changes to apply..."
aws rds wait db-instance-available --db-instance-identifier "$IDENTIFIER-mysql"

# Add delay for network changes
echo "Waiting an additional 60 seconds for network changes to stabilize..."
sleep 60

# Test MySQL connectivity
echo "Testing MySQL connection to RDS instance..."
mysql --connect-timeout=10 -h"$TARGET_HOSTNAME" -u"$TARGET_USERNAME" -p"$TARGET_PASSWORD" -e "SELECT 1;" 2>/dev/null
if [ $? -eq 0 ]; then
    echo "MySQL connection successful!"
else
    echo "Warning: Could not connect to MySQL. This is often due to network propagation delays."
    echo "The script will continue, but commands requiring MySQL access might fail."
    echo "You can manually verify connectivity later with:"
    echo "mysql -h $TARGET_HOSTNAME -u $TARGET_USERNAME -p $TARGET_DATABASE"
fi

# Display MySQL instance info
echo "RDS MySQL instance created successfully!"
echo "Hostname: $TARGET_HOSTNAME"
echo "Username: $TARGET_USERNAME"
echo "Password: $TARGET_PASSWORD"
echo "Database: $TARGET_DATABASE"

# Create AWS DMS source endpoint (PostgreSQL)
SOURCE_ENDPOINT_ARN="$(
    aws dms create-endpoint \
        --database-name "$SOURCE_DATABASE" \
        --endpoint-identifier "$IDENTIFIER-source" \
        --endpoint-type "source" \
        --engine-name "postgres" \
        --output "text" \
        --password "$SOURCE_PASSWORD" \
        --port "5432" \
        --query 'Endpoint.EndpointArn' \
        --server-name "$SOURCE_HOSTNAME" \
        --username "$SOURCE_USERNAME" ||
    aws dms describe-endpoints \
        --filters Name="endpoint-id",Values="$IDENTIFIER-source" \
        --output "text" \
        --query 'Endpoints[].EndpointArn'
)"
[ "$SOURCE_ENDPOINT_ARN" ]

# Modify source endpoint to ensure it's correctly configured
aws dms modify-endpoint \
    --database-name "$SOURCE_DATABASE" \
    --endpoint-arn "$SOURCE_ENDPOINT_ARN" \
    --endpoint-identifier "$IDENTIFIER-source" \
    --endpoint-type "source" \
    --engine-name "postgres" \
    --output "text" \
    --password "$SOURCE_PASSWORD" \
    --port "5432" \
    --query 'Endpoint.EndpointArn' \
    --server-name "$SOURCE_HOSTNAME" \
    --username "$SOURCE_USERNAME"

# Create AWS DMS target endpoint (MySQL)
TARGET_ENDPOINT_ARN="$(
    aws dms create-endpoint \
        --endpoint-identifier "$IDENTIFIER-target" \
        --endpoint-type "target" \
        --engine-name "mysql" \
        --extra-connection-attributes "Initstmt=SET FOREIGN_KEY_CHECKS=0;loadUsingCSV=false;parallelLoadThreads=16" \
    --my-sql-settings "{\"AfterConnectScript\": \"SET character_set_connection='utf8mb4';\"}" \
        --output "text" \
        --password "$TARGET_PASSWORD" \
        --port "3306" \
        --query 'Endpoint.EndpointArn' \
        --server-name "$TARGET_HOSTNAME" \
        --username "$TARGET_USERNAME" \
        --database-name "$TARGET_DATABASE" ||
    aws dms describe-endpoints \
        --filters Name="endpoint-id",Values="$IDENTIFIER-target" \
        --output "text" \
        --query 'Endpoints[].EndpointArn'
)"
[ "$TARGET_ENDPOINT_ARN" ]

# Modify target endpoint to ensure it's correctly configured
aws dms modify-endpoint \
    --endpoint-arn "$TARGET_ENDPOINT_ARN" \
    --endpoint-identifier "$IDENTIFIER-target" \
    --endpoint-type "target" \
    --engine-name "mysql" \
    --extra-connection-attributes "Initstmt=SET FOREIGN_KEY_CHECKS=0;loadUsingCSV=false;parallelLoadThreads=16" \
    --my-sql-settings "{\"AfterConnectScript\": \"SET character_set_connection='utf8mb4';\"}" \
    --output "text" \
    --password "$TARGET_PASSWORD" \
    --port "3306" \
    --query 'Endpoint.EndpointArn' \
    --server-name "$TARGET_HOSTNAME" \
    --username "$TARGET_USERNAME" \
    --database-name "$TARGET_DATABASE"

# Create DMS replication subnet group using public subnets
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

# Create or modify the replication subnet group
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

# Create AWS DMS replication instance
REPLICATION_INSTANCE_ARN="$(
    aws dms create-replication-instance \
        --engine-version "$ENGINE_VERSION" \
        --output "text" \
        --query 'ReplicationInstance.ReplicationInstanceArn' \
        --replication-instance-class "$INSTANCE_TYPE" \
        --replication-instance-identifier "$IDENTIFIER" \
        --replication-subnet-group-identifier "$IDENTIFIER" \
        --vpc-security-group-ids "$SECURITY_GROUP_ID" \
        --publicly-accessible ||
    aws dms describe-replication-instances \
        --filters Name="replication-instance-id",Values="$IDENTIFIER" \
        --output "text" \
        --query 'ReplicationInstances[].ReplicationInstanceArn'
)"
[ "$REPLICATION_INSTANCE_ARN" ]

# Wait for replication instance to be available
aws dms wait replication-instance-available \
    --filters Name="replication-instance-arn",Values="$REPLICATION_INSTANCE_ARN"

# Modify replication instance if needed
aws dms modify-replication-instance \
    --allow-major-version-upgrade \
    --engine-version "$ENGINE_VERSION" \
    --output "text" \
    --query 'ReplicationInstance.ReplicationInstanceArn' \
    --replication-instance-arn "$REPLICATION_INSTANCE_ARN" \
    --replication-instance-class "$INSTANCE_TYPE" \
    --replication-instance-identifier "$IDENTIFIER" \
    --vpc-security-group-ids "$SECURITY_GROUP_ID"

# Wait for replication instance to be available after modifications
aws dms wait replication-instance-available \
    --filters Name="replication-instance-arn",Values="$REPLICATION_INSTANCE_ARN"

# Get DMS replication instance private and public IPs
DMS_INSTANCE_PUBLIC_IP=""
DMS_INSTANCE_PRIVATE_IP=""
DMS_INSTANCE_INFO=$(aws dms describe-replication-instances \
    --filters Name="replication-instance-arn",Values="$REPLICATION_INSTANCE_ARN" \
    --output json)

if [ -n "$DMS_INSTANCE_INFO" ]; then
    DMS_INSTANCE_PUBLIC_IP=$(echo "$DMS_INSTANCE_INFO" | grep -oP '"PublicIpAddress":\s*"\K[^"]+' || echo "")
    DMS_INSTANCE_PRIVATE_IP=$(echo "$DMS_INSTANCE_INFO" | grep -oP '"ReplicationInstancePrivateIpAddress":\s*"\K[^"]+' || echo "")
    
    # Add DMS instance IPs to security group
    if [ -n "$DMS_INSTANCE_PUBLIC_IP" ]; then
        aws ec2 authorize-security-group-ingress \
            --group-id "$SECURITY_GROUP_ID" \
            --protocol tcp \
            --port 3306 \
            --cidr "$DMS_INSTANCE_PUBLIC_IP/32"
    fi
    
    if [ -n "$DMS_INSTANCE_PRIVATE_IP" ]; then
        aws ec2 authorize-security-group-ingress \
            --group-id "$SECURITY_GROUP_ID" \
            --protocol tcp \
            --port 3306 \
            --cidr "$DMS_INSTANCE_PRIVATE_IP/32"
    fi
    
    echo "Added DMS instance public and private IPs to security group"
fi

# Test connection to source endpoint
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

# Wait for source connection test to succeed
aws dms wait test-connection-succeeds --filters \
    Name="endpoint-arn",Values="$SOURCE_ENDPOINT_ARN" \
    Name="replication-instance-arn",Values="$REPLICATION_INSTANCE_ARN"

# Test connection to target endpoint
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

# Wait for target connection test to succeed
aws dms wait test-connection-succeeds --filters \
    Name="endpoint-arn",Values="$TARGET_ENDPOINT_ARN" \
    Name="replication-instance-arn",Values="$REPLICATION_INSTANCE_ARN"

# Create DMS replication task settings file
tee "$TMP/replication-task-settings.json" <<EOF
{
    "ChangeProcessingDdlHandlingPolicy": {
        "HandleSourceTableAltered": false,
        "HandleSourceTableDropped": false,
        "HandleSourceTableTruncated": false
    },
    "FullLoadSettings": {
        "MaxFullLoadSubTasks": 16,
        "TargetTablePrepMode": "DO_NOTHING"
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
      "BatchApplyEnabled": true,
      "FullLobMode": false,
      "LimitedSizeLobMode": true,
      "LobMaxSize": 128,
      "LobChunkSize": 64,
      "SupportLobs": true
    },
    "CharacterSetSettings": {
      "CharacterSetSupport": {
        "CharacterSet": "UTF-8",
        "ReplaceWithCharacterCodePoint": 0
      },
      "CharacterSetMetadata": {
        "CharacterSetSource": "UTF-8",
        "CharacterSetTarget": "UTF-8"
      }
    }
}
EOF

# Create table mapping rules for DMS task
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

# Add schema renaming rule if source and target schemas differ
if [ "$SOURCE_SCHEMA" != "$TARGET_DATABASE" ]
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
            "value": "$TARGET_DATABASE"
EOF
fi

# Complete the table mappings file
tee -a "$TMP/table-mappings.json" <<EOF
        }
    ]
}
EOF

# Create DMS replication task
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

# Check if task is running or wait for it to be ready
aws dms describe-replication-tasks \
    --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN" \
    --output "text" \
    --query 'ReplicationTasks[].Status' |
grep "running" ||
aws dms wait replication-task-ready \
    --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN"

# Modify the replication task with the latest settings
aws dms modify-replication-task \
    --migration-type "full-load-and-cdc" \
    --output "text" \
    --query 'ReplicationTask.ReplicationTaskArn' \
    --replication-task-arn "$REPLICATION_TASK_ARN" \
    --replication-task-identifier "$IDENTIFIER" \
    --replication-task-settings "file://$TMP/replication-task-settings.json" \
    --table-mappings "file://$TMP/table-mappings.json"

# Wait for task modification to complete
while aws dms describe-replication-tasks \
    --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN" \
    --output "text" \
    --query 'ReplicationTasks[].Status' |
grep -q "modifying"
do sleep 10
done

# Check task status or wait for it to be ready
aws dms describe-replication-tasks \
    --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN" \
    --output "text" \
    --query 'ReplicationTasks[].Status' |
grep "running" ||
aws dms wait replication-task-ready \
    --filters Name="replication-task-arn",Values="$REPLICATION_TASK_ARN"

# Turn off tracing for summary output if debug was enabled
if [ "$DEBUG" = "yes" ]; then
    set +x
fi

echo "Saved Replication Task ARN to $IDENTIFIER-task-arn.txt for use with start.sh"

echo "======================================================================================"
echo "SETUP COMPLETED SUCCESSFULLY"
echo "======================================================================================"
echo
echo "MySQL RDS instance information:"
echo "Hostname: $TARGET_HOSTNAME"
echo "Database: $TARGET_DATABASE"
echo
echo "Admin user:"
echo "Username: $TARGET_USERNAME"
echo "Password: $TARGET_PASSWORD"
echo
echo "Migration user (for PlanetScale):"
echo "Username: migration_user"
echo "Password: $MIGRATION_PASSWORD"
echo
echo "======================================================================================"
echo "NEXT STEPS:"
echo "======================================================================================"
echo "1. Log into your new MySQL instance using the credentials above"
echo "2. Set up your schema manually"
echo "3. Once your schema is ready, run the start.sh script with the same identifier:"
echo "   sh start.sh --identifier \"$IDENTIFIER\" --ips \"$IPS_OPTION\""
echo
echo "IMPORTANT: The migration will not start automatically. You need to run start.sh"
echo "once you have set up your schema in the MySQL database."
echo
echo "REPLICATION TASK ARN (needed for start.sh): $REPLICATION_TASK_ARN"
echo

echo "$REPLICATION_TASK_ARN" > "$IDENTIFIER-task-arn.txt"
echo "Saved Replication Task ARN to $IDENTIFIER-task-arn.txt for use with start.sh"
