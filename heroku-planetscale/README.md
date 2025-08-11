Heroku Postgres to PlanetScale for Postgres via Bucardo asynchronous replication
================================================================================

Heroku notably does not support logical replication, which has left many of its customers on outdated Postgres and without a convenient migration path to another provider. PlanetScale have tested a wide variety of plausible strategies and [Bucardo](https://bucardo.org/Bucardo/)'s trigger-based asynchronous replication has proven to be the most reliable option with the least downtime.

There may be a variation of this strategy that uses the [`ff-seq.sh`](../postgres-direct/ff-seq.sh) tool from our logical replication strategy that can provide a true zero-downtime exit strategy from Heroku. Get in touch if this is a requirement for you.

Setup
-----

1. Launch an EC2 instance where you'll run Bucardo. It must run Linux and have network connectivity to both Heroku and PlanetScale.

2. Install and configure Bucardo there:

    ```sh
    sh install.sh
    ```

3. Export two environment variables there:
    * `HEROKU`: URL-formatted Heroku Postgres connection information for the source database.
    * `PLANETSCALE`: Space-delimited PlanetScale for Postgres connection information for the `postgres` role (as shown on the Connect page for your database) for the target database.

Bulk copy and replication
-------------------------

1. Sync table definitions outside of Bucardo (just like we'd do for logical replication and _before adding the databases to Bucardo_):

    ```sh
    pg_dump --no-owner --no-privileges --no-publications --no-subscriptions --schema-only "$HEROKU" | psql "$PLANETSCALE" -a
    ```

2. Connect the source Heroku Postgres database:

    ```sh
    sudo -H -u "bucardo" bucardo add database "heroku" host="$(echo "$HEROKU" | cut -d "@" -f 2 | cut -d ":" -f 1)" user="$(echo "$HEROKU" | cut -d "/" -f 3 | cut -d ":" -f 1)" password="$(echo "$HEROKU" | cut -d ":" -f 3 | cut -d "@" -f 1)" dbname="$(echo "$HEROKU" | cut -d "/" -f 4 | cut -d "?" -f 1)"
    ```

3. Connect the target PlanetScale for Postgres database:

    ```sh
    sudo -H -u "bucardo" bucardo add database "planetscale" ${PLANETSCALE%%" ssl"*}
    ```

4. Add all sequences:

    ```sh
    sudo -H -u "bucardo" bucardo add all sequences --relgroup "planetscale_import"
    ```

5. Add all tables:

    ```sh
    sudo -H -u "bucardo" bucardo add all tables --relgroup "planetscale_import"
    ```

6. Create a sync:

    ```sh
    sudo -H -u "bucardo" bucardo add sync "planetscale_import" dbs="heroku,planetscale" onetimecopy=1 relgroup="planetscale_import"
    ```

7. Start Bucardo replicating:

    ```sh
    sudo -H -u "bucardo" bucardo reload
    ```

Monitor progress
----------------

Bucardo status:

```sh
sudo -H -u "bucardo" bucardo status
```

Bucardo's state will bounce between several descriptive values. It's not possible to confirm that your replication is caught up and keeping up based on these state values alone. Instead, you need to confirm that the complete data is present (e.g. by using the `count(*)` aggregation) before moving on.

Count rows to gauge how caught-up the asynchronous replication is (where `example` is one of your table names):

```sh
psql "$HEROKU" -c "SELECT count(*) FROM example;"; psql "$PLANETSCALE" -c "SELECT count(*) FROM example;"
```

Run ad-hoc queries against the Bucardo metadata:

```sh
sudo -H -u "bucardo" psql
```

Tail the Bucardo logs:

```sh
tail -F "/var/log/bucardo/log.bucardo"
```

Switch traffic
--------------

Because Bucardo is replicating both table and sequence data, it's critical to stop write traffic at the source completely. Most likely, this can best be accomplished at the application level. However, it is possible to enforce at the database level, too:

```sh
psql "$HEROKU" -c "REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM $(echo "$HEROKU" | cut -d "/" -f 3 | cut -d ":" -f 1);"
```

Once writes have stopped reaching Heroku, it's safe to begin writes to PlanetScale via an application deploy or reconfiguration.

If you issued the `REVOKE` statement above and need to abort before switching traffic and return to service on Heroku, revert as follows:

```sh
psql "$HEROKU" -c "GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO $(echo "$HEROKU" | cut -d "/" -f 3 | cut -d ":" -f 1);"
```

Cleanup
-------

1. Stop and remove the Bucardo sync:

    ```sh
    sudo -H -u "bucardo" bucardo remove sync "planetscale_import"
    ```

2. Remove every table from Bucardo's management:

    ```sh
    sudo -H -u "bucardo" bucardo list tables | cut -d " " -f 3 | xargs sudo -H -u "bucardo" bucardo remove table
    ```

3. Remove every sequence from Bucardo's management:

    ```sh
    sudo -H -u "bucardo" bucardo list sequences | cut -d " " -f 2 | xargs sudo -H -u "bucardo" bucardo remove sequence
    ```

4. Remove intermediate Bucardo grouping objects:

    ```sh
    sudo -H -u "bucardo" bucardo remove relgroup "planetscale_import" && sudo -H -u "bucardo" bucardo remove dbgroup "planetscale_import"
    ```

5. Remove the PlanetScale database from Bucardo's management:

    ```sh
    sudo -H -u "bucardo" bucardo remove database "planetscale"
    ```

6. Remove the Heroku database from Bucardo's management:

    ```sh
    sudo -H -u "bucardo" bucardo remove database "heroku"
    ```

7. Stop Bucardo:

    ```sh
    sudo -H -i -u "bucardo" bucardo stop
    ```

8. Remove Bucardo metadata from the Heroku database:

    ```sh
    psql "$HEROKU" -c "DROP SCHEMA bucardo CASCADE;"
    ```

8. Optionally, terminate the EC2 instance that was hosting Bucardo.

9. When the migration is complete and validated, delete the source Heroku Postgres database.

See also
--------

* <https://bucardo.org/Bucardo/pgbench_example>
* <https://gist.github.com/Leen15/da42bd23b363867e14a378d824f2064e>
* <https://smartcar.com/blog/zero-downtime-migration>
* <https://medium.com/@logeshmohan/postgresql-replication-using-bucardo-5-4-1-6e78541ceb5e>
* <https://justatheory.com/2013/02/bootstrap-bucardo-mulitmaster/>
* <https://www.porter.run/blog/migrating-postgres-from-heroku-to-rds>
* <https://medium.com/hellogetsafe/pulling-off-zero-downtime-postgresql-migrations-with-bucardo-and-terraform-1527cca5f989>
* <https://github.com/nxt-insurance/bucardo-terraform-archive>
* <https://bucardo-general.bucardo.narkive.com/hznUofas/replication-of-tables-without-primary-keys>
