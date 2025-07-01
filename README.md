# Migration scripts for moving into PlanetScale

Use these scripts to migrate a Postgres database to PlanetScale for Postgres or Vitess/MySQL.

## [Postgres directly to PlanetScale for Postgres](./postgres-direct)

This direct migration uses logical replication and, optionally, a proxy which can manage connections and sequences for a zero-downtime migration.

## [Postgres to PlanetScale for Postgres or Vitess/MySQL via AWS DMS](./postgres-planetscale)

This has some speed limitations and is only recommended for databases 100GB or less.

## [Postgres to PlanetScale for Vitess/MySQL via AWS DMS and an intermediate MySQL](./postgres-mysql-planetscale)

Thanks to the intermediate MySQL database, this runs faster than the variant above, but has the downside of requiring an additional MySQL instance running during the migration, which adds cost and complexity to the import.
Recommended for larger imports > 100GB.
