# Postgres to PlanetScale for Vitess

This script leverages [AWS DMS](https://aws.amazon.com/dms/) to migrate an existing Postgres source database to PlanetScale for Vitess.

When importing into a PlanetScale Vitess database, this script's performance is limited and so it is only recommended for databases 100GB or less.

Usage
-----

### Import a Postgres database into Vitess

    sh import.sh --identifier "MY_PLANETSCALE_IMPORT_IDENTIFIER" --source "SOURCE_POSTGRES_CONNINFO" --target "VITESS_USER:VITESS_PASSWORD@VITESS_HOSTNAME" --target-type "mysql"

Some sources, notably Neon, require adding the `--tls` option to `import.sh`.

## Import a Postgres database into PlanetScale for Postgres

    sh import.sh --identifier "MY_PLANETSCALE_IMPORT_IDENTIFIER" --source "SOURCE_POSTGRES_CONNINFO" --target "TARGET_POSTGRES_CONNINFO" --target-type "postgres"

### Cleanup

    sh cleanup.sh --identifier "MY_PLANETSCALE_IMPORT_IDENTIFIER"
