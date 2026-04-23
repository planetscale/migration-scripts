# Migration scripts for moving into PlanetScale

Use these scripts to migrate a Postgres database to PlanetScale for Postgres or Vitess/MySQL.

## [Postgres to PlanetScale via pgcopydb](./pgcopydb-helpers)

The primary and most actively developed migration path. Uses [pgcopydb](https://github.com/planetscale/pgcopydb) (PlanetScale fork) for fast, reliable PostgreSQL-to-PlanetScale migrations with CDC-based replication. Includes a set of helper scripts that run on a dedicated migration instance.

Pair with the [pgcopydb instance templates](./pgcopydb-templates) to provision a pre-configured EC2 or GCP Compute Engine instance via Terraform or CloudFormation.

## [Postgres directly to PlanetScale for Postgres](./postgres-direct)

This direct migration uses logical replication and, optionally, a proxy which can manage connections and sequences for a zero-downtime migration.

## [Heroku Postgres to PlanetScale for Postgres](./heroku-planetscale)

Heroku notably does not support logical replication. This strategy uses Bucardo to manage trigger-based asynchronous replication from Heroku into PlanetScale for Postgres.

## [Postgres to PlanetScale for Postgres or Vitess via AWS DMS](./postgres-planetscale)

This has some speed limitations and is only recommended for databases 100GB or less.

## [Postgres to PlanetScale for Vitess via AWS DMS and an intermediate MySQL](./postgres-mysql-planetscale)

Thanks to the intermediate MySQL database, this runs faster than the variant above, but has the downside of requiring an additional MySQL instance running during the migration, which adds cost and complexity to the import.
Recommended for larger imports > 100GB.
