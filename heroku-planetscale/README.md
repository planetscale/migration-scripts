Heroku Postgres to PlanetScale for Postgres via Bucardo asynchronous replication
================================================================================

Heroku notably does not support logical replication, which has left many of its customers on outdated Postgres and without a convenient migration path to another provider. PlanetScale have tested a wide variety of plausible strategies and [Bucardo](https://bucardo.org/Bucardo/)'s trigger-based asynchronous replication has proven to be the most reliable option with the least downtime.

There may be a variation of this strategy that uses the [`ff-seq.sh`](../postgres-direct/ff-seq.sh) tool from our logical replication strategy that can provide a true zero-downtime exit strategy from Heroku. [Get in touch](mailto:support@planetscale.com) if this is a requirement for you.

Setup, bulk copy, and replication
---------------------------------

1. Launch an EC2 instance where you'll run Bucardo. It must run Linux and have network connectivity to both Heroku and PlanetScale.

2. Install and configure Bucardo there:

    ```sh
    sh install-bucardo.sh
    ```

3. Export two environment variables there:
    * `HEROKU`: URL-formatted Heroku Postgres connection information for the source database.
    * `PLANETSCALE`: Space-delimited PlanetScale for Postgres connection information for the `postgres` role (as shown on the Connect page for your database) for the target database.

4. Configure and start Bucardo:

    ```sh
    sh mk-bucardo-repl.sh --primary "$HEROKU" --replica "$PLANETSCALE"
    ```

Monitor progress
----------------

Use the `stat-bucardo-repl.sh` tool to monitor the overall state of your migration:

```sh
sh stat-bucardo-repl.sh --primary "$HEROKU" --replica "$PLANETSCALE"
```

It is also wise to directly confirm that the complete data is present (e.g. by using the `count(*)` aggregation or by specifically `SELECT`ing data you know to have just written) before moving on.

Count rows to gauge how caught-up the asynchronous replication is (where `example` is one of your table names):

```sh
psql "$HEROKU" -c "SELECT count(*) FROM example;"; psql "$PLANETSCALE" -c "SELECT count(*) FROM example;"
```

Finally, in the event of trouble, the Bucardo logs may be illuminating:

```sh
tail -F "/var/log/bucardo/log.bucardo"
```

Switch traffic
--------------

Because Bucardo is replicating both table and sequence data, it's critical to stop write traffic at the source completely. `heroku maintenance:on` can stop all traffic but if you want to continue to allow read traffic, you can either arrange for that at the application level or enforce it at the database level thus:

```sh
psql "$HEROKU" -c "REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM $(echo "$HEROKU" | cut -d "/" -f 3 | cut -d ":" -f 1);"
```

Once writes have stopped reaching Heroku and replicated to PlanetScale, it's safe to begin writes to PlanetScale via an application deploy or reconfiguration.

If you issued the `REVOKE` statement above and need to abort before switching traffic and return to service on Heroku, revert as follows:

```sh
psql "$HEROKU" -c "GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO $(echo "$HEROKU" | cut -d "/" -f 3 | cut -d ":" -f 1);"
```

Cleanup
-------

1. Remove the Bucardo sync and metadata:

    ```sh
    sh rmk-bucardo-repl.sh --primary "$HEROKU" --replica "$PLANETSCALE"
    ```

2. Optionally, terminate the EC2 instance that was hosting Bucardo.

3. When the migration is complete and validated, delete the source Heroku Postgres database.

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
* <https://gist.github.com/shalvah/8d8b91d3bfe33f08a2583574b6087426>
