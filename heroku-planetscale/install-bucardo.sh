set -e -x

BUCARDO_VERSION="5.6.0"

echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -c -s)-pgdg main" |
sudo tee "/etc/apt/sources.list.d/pgdg.list"
curl -L -S -f -s "https://www.postgresql.org/media/keys/ACCC4CF8.asc" |
sudo gpg --dearmor -o "/etc/apt/trusted.gpg.d/postgresql.gpg" --yes
sudo apt-get update

sudo apt-get -y install "libdbd-pg-perl" "libdbix-safe-perl" "libpod-parser-perl" "postgresql-17" "postgresql-plperl-17"

if ! which "bucardo"
then
    if [ ! -f "$TMP/bucardo-$BUCARDO_VERSION.tar.gz" ]
    then curl -L -o "$TMP/bucardo-$BUCARDO_VERSION.tar.gz" "https://github.com/bucardo/bucardo/archive/$BUCARDO_VERSION.tar.gz"
    fi
    if [ ! -d "$TMP/bucardo-$BUCARDO_VERSION" ]
    then tar -C "$TMP" -f "$TMP/bucardo-$BUCARDO_VERSION.tar.gz" -x
    fi
    (
        cd "$TMP/bucardo-$BUCARDO_VERSION"
        perl "Makefile.PL"
        make
        sudo make install
    )
fi

sudo tee "/etc/bucardorc" >"/dev/null" <<EOF
log_level = verbose
verbose = 1
EOF

sudo useradd -M -U -d "/var/run/bucardo" -s "/bin/sh" "bucardo" ||
sudo usermod -d "/var/run/bucardo" -s "/bin/sh" "bucardo"
sudo mkdir -p "/var/log/bucardo" "/var/run/bucardo"
sudo chown "bucardo:bucardo" "/var/log/bucardo" "/var/run/bucardo"

sudo -H -u "postgres" psql -c "CREATE ROLE bucardo WITH CREATEDB LOGIN SUPERUSER;" ||
sudo -H -u "postgres" psql -c "ALTER ROLE bucardo WITH CREATEDB LOGIN SUPERUSER;"
sudo -H -u "postgres" psql -c "CREATE DATABASE bucardo WITH OWNER bucardo;" ||
sudo -H -u "bucardo" psql -c '\d'

if ! sudo -H -u "bucardo" bucardo status 2>"/dev/null"
then
    echo "p" | sudo -H -u "bucardo" bucardo install \
        --db-name "bucardo" \
        --db-user "bucardo" \
        --db-host "/var/run/postgresql" \
        --db-port 5432 \
        --verbose
    sudo -H -i -u "bucardo" bucardo start
else
    sudo -H -u "bucardo" bucardo upgrade --verbose || :
    sudo -H -i -u "bucardo" bucardo restart
fi
sudo -H -u "bucardo" bucardo status
