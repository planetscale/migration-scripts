# Import scripts

Use these scripts to help import a Postgres database to Vitess/MySQL on PlanetScale.

## [postgres-planetscale](./postgres-planetscale)

Scripts to go directly from a Postgres database to PlanetScale leveraging Amazon DMS.
This scrips has some speed limitations and is only recommended for databases 100GB or less.

## [postgres-mysql-planetscale](./postgres-mysql-planetscale)

Scripts for migrating from Postgres to PlanetScale with Amazon DMS and an intermediate Amazon MySQL database.
This runs faster than the above, but has the downside of requiring an additional MySQL instance running during the migration, which adds cost and complexity to the import.
Recommended for larger imports > 100GB.
