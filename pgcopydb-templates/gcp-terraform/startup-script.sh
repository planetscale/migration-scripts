#!/bin/bash
# Startup script for pgcopydb migration instance
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

# =============================================================================
# Install Prerequisites
# =============================================================================
echo "Updating system packages..."
apt-get update -y
apt-get install -y wget gnupg2 lsb-release curl unzip ca-certificates netcat-openbsd sqlite3

# =============================================================================
# Install PostgreSQL 17
# =============================================================================
echo "Installing PostgreSQL 17..."
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
apt-get update
apt-get install -y postgresql-client-17 postgresql-17 postgresql-server-dev-17

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
    libzstd-dev

# =============================================================================
# Build pgcopydb from Source
# =============================================================================
echo "Building pgcopydb from source..."
cd /tmp
git clone --branch v0.18.0 https://github.com/planetscale/pgcopydb.git
cd pgcopydb
export PATH=/usr/lib/postgresql/17/bin:$PATH
make clean || true
make
make install
ldconfig

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
export PATH=/usr/lib/postgresql/17/bin:$PATH
alias pgcopydb-version='pgcopydb --version'
alias psql-version='psql --version'
alias check-planetscale='nc -zv app.connect.psdb.cloud 443 2>&1 | grep succeeded'
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
chown ubuntu:ubuntu /home/ubuntu/*.sh /home/ubuntu/*.md
chmod +x /home/ubuntu/*.sh

echo ""
echo "=========================================="
echo "Setup completed successfully!"
echo "Finished at: $(date)"
echo "=========================================="
echo ""
echo "Migration helper scripts installed at: /home/ubuntu/"
echo ""
