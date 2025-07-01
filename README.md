# Import scripts

Use these scripts to help import a Postgres database to Vitess/MySQL on PlanetScale.

## [postgres-planetscale](./postgres-planetscale)

Scripts to go from a Postgres database to PlanetScale leveraging Amazon DMS.
This script has some speed limitations and is only recommended for databases 100GB or less.

## [postgres-mysql-planetscale](./postgres-mysql-planetscale)

Scripts for migrating from Postgres to PlanetScale with Amazon DMS and an intermediate Amazon MySQL database.
This runs faster than the above, but has the downside of requiring an additional MySQL instance running during the migration, which adds cost and complexity to the import.
Recommended for larger imports > 100GB.

## [postgres-direct](./postgres-direct)

Scripts for going directly from any Postgres database to a PlanetScale for Postgres database using logical replication and, optionally, a proxy which can manage connections and sequences for a zero-downtime migration.
