# Postgres to PlanetScale for Vitess

This script leverages [AWS DMS](https://aws.amazon.com/dms/) to migrate an existing Postgres source database to PlanetScale for Vitess.
This script has some speed limitations and is only recommended for databases 100GB or less.

Refer to the [PlanetScale docs](https://planetscale.com/docs/imports/postgres-planetscale-migration-guide) for a guide on how to use these scripts.
