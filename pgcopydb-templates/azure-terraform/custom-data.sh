#!/bin/bash
# Custom-data script for pgcopydb migration instance
# This script runs on first boot to install and configure pgcopydb

set -e

# Logging
exec > >(tee -a /var/log/pgcopydb-setup.log)
exec 2>&1

echo "=========================================="
echo "pgcopydb Migration Instance Setup"
echo "Started at: $(date)"
echo "=========================================="

export DEBIAN_FRONTEND=noninteractive

# VM extensions (AADSSHLoginForLinux, AzureMonitorLinuxAgent) install their own
# packages in parallel with this script, and whichever loses the dpkg lock
# normally fails outright. Setting the timeout globally makes every apt caller
# on the box — ours, the Azure CLI installer's, and the extensions' — wait
# instead. Written first so it is in place before the first install.
cat > /etc/apt/apt.conf.d/99-dpkg-lock-timeout << 'APT_EOF'
DPkg::Lock::Timeout "-1";
APT_EOF

# =============================================================================
# Install Prerequisites
# =============================================================================
echo "Updating system packages..."
apt-get update -y
apt-get install -y wget gnupg2 lsb-release curl unzip ca-certificates netcat-openbsd sqlite3 rsync xfsprogs

# =============================================================================
# Mount Migration Data Disk
# =============================================================================
# The Premium SSD v2 data disk is attached after the VM boots, so wait for the
# device instead of assuming it is present. by-lun is the NVMe symlink path
# (azure-vm-utils udev rules); scsi1 is probed as a fallback in case the VM is
# ever moved back to the SCSI controller.
#
# /home/ubuntu is relocated onto the disk because the helper scripts create
# their working directories as ~/migration_YYYYMMDD-HHMMSS — see
# run-migration.sh in pgcopydb-helpers.
echo "Waiting for migration data disk..."
DATA_DISK=""
for _ in $(seq 1 60); do
    for candidate in /dev/disk/azure/data/by-lun/0 /dev/disk/azure/scsi1/lun0; do
        if [ -b "$candidate" ]; then
            DATA_DISK="$candidate"
            break 2
        fi
    done
    sleep 10
done

if [ -n "$DATA_DISK" ]; then
    echo "Preparing data disk $DATA_DISK..."
    blkid "$DATA_DISK" >/dev/null 2>&1 || mkfs.xfs -f "$DATA_DISK"
    DATA_UUID=$(blkid -s UUID -o value "$DATA_DISK")
    mkdir -p /mnt/migration-data
    mount "$DATA_DISK" /mnt/migration-data
    # Carries over .ssh, so Entra ID and key-based SSH keep working post-mount.
    rsync -aXS /home/ubuntu/ /mnt/migration-data/
    umount /mnt/migration-data
    rmdir /mnt/migration-data
    echo "UUID=$DATA_UUID /home/ubuntu xfs defaults,nofail,discard 0 2" >> /etc/fstab
    mount /home/ubuntu
    chown ubuntu:ubuntu /home/ubuntu
    echo "Data disk mounted at /home/ubuntu"
else
    echo "WARN: no data disk appeared; migration data will live on the OS disk" >&2
fi

# =============================================================================
# Install PostgreSQL 18
# =============================================================================
echo "Installing PostgreSQL 18..."
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
apt-get update
apt-get install -y postgresql-client-18 postgresql-18 postgresql-server-dev-18

# =============================================================================
# Install Build Tools
# =============================================================================
echo "Installing build dependencies..."
apt-get install -y \
    build-essential \
    git \
    libssl-dev \
    libpq-dev \
    libgc-dev \
    liblz4-dev \
    libpam0g-dev \
    libxml2-dev \
    libxslt1-dev \
    libreadline-dev \
    zlib1g-dev \
    libncurses5-dev \
    libkrb5-dev \
    libselinux1-dev \
    libzstd-dev \
    libnuma-dev

# =============================================================================
# Build pgcopydb from Source
# =============================================================================
echo "Building pgcopydb from source..."
cd /tmp
git clone --branch v0.19.0 https://github.com/planetscale/pgcopydb.git
cd pgcopydb
export PATH=/usr/lib/postgresql/18/bin:$PATH
make clean || true
make
make install
ldconfig

# =============================================================================
# Install Azure CLI
# =============================================================================
echo "Installing Azure CLI..."
curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# =============================================================================
# System Configuration
# =============================================================================

# File descriptor limits
cat > /etc/security/limits.d/99-pgcopydb.conf << 'LIMITS_EOF'
*  soft  nofile  65536
*  hard  nofile  65536
LIMITS_EOF

# Sysctl tuning for high-throughput migrations
cat > /etc/sysctl.d/99-pgcopydb.conf << 'SYSCTL_EOF'
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
SYSCTL_EOF
sysctl -p /etc/sysctl.d/99-pgcopydb.conf

# PATH configuration
cat > /etc/profile.d/pgcopydb.sh << 'PROFILE_EOF'
export PATH=/usr/lib/postgresql/18/bin:$PATH
alias pgcopydb-version='pgcopydb --version'
alias psql-version='psql --version'
alias check-planetscale='nc -zv app.connect.psdb.cloud 443 2>&1 | grep succeeded'

# Entra ID SSH logs in as your own account, which cannot read /home/ubuntu.
# Only print for interactive shells so scp and remote commands stay clean.
case $- in
    *i*)
        if [ "$(id -un)" != "ubuntu" ]; then
            printf '\nMigration tooling is installed under /home/ubuntu.\nSwitch to that account first:  sudo su - ubuntu\n\n'
        fi
        ;;
esac
PROFILE_EOF

# .env file
cat > /home/ubuntu/.env << 'ENV_EOF'
# PlanetScale Migration Environment Variables
# Edit these values before running the migration

# Source Database
PGCOPYDB_SOURCE_PGURI="postgresql://user:password@source-host:5432/dbname?sslmode=require"

# Target Database (PlanetScale)
PGCOPYDB_TARGET_PGURI="postgresql://user:password@target-host.connect.psdb.cloud:5432/dbname?sslmode=require"
ENV_EOF
chmod 600 /home/ubuntu/.env
chown ubuntu:ubuntu /home/ubuntu/.env

# Pull PlanetScale migration helper scripts
echo "Cloning PlanetScale migration helper scripts..."
git clone --depth 1 https://github.com/planetscale/migration-scripts.git /tmp/migration-scripts
cp -r /tmp/migration-scripts/pgcopydb-helpers/* /home/ubuntu/
rm -rf /tmp/migration-scripts
chown -R ubuntu:ubuntu /home/ubuntu/
chmod +x /home/ubuntu/*.sh

# =============================================================================
# Verify Installation
# =============================================================================
echo "=== Installation verification ===" >> /var/log/pgcopydb-setup-verification.log
export PATH=/usr/lib/postgresql/18/bin:$PATH
pgcopydb --version >> /var/log/pgcopydb-setup-verification.log 2>&1 || echo "pgcopydb installation failed" >> /var/log/pgcopydb-setup-verification.log
psql --version >> /var/log/pgcopydb-setup-verification.log 2>&1 || echo "PostgreSQL client installation failed" >> /var/log/pgcopydb-setup-verification.log
az --version >> /var/log/pgcopydb-setup-verification.log 2>&1 || echo "Azure CLI installation failed" >> /var/log/pgcopydb-setup-verification.log
df -h /home/ubuntu >> /var/log/pgcopydb-setup-verification.log 2>&1

echo ""
echo "=========================================="
echo "Setup completed successfully!"
echo "Finished at: $(date)"
echo "=========================================="
echo ""
echo "Migration helper scripts installed at: /home/ubuntu/"
echo ""
