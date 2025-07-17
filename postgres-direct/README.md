Postgres to PlanetScale via logical replication and an optional proxy
=====================================================================

If you're already on Postgres and want to migrate to [PlanetScale for Postgres](https://planetscale.com/blog/planetscale-for-postgres), you can skip AWS DMS and migrate straight from any Postgres source that supports logical replication into PlanetScale for Postgres.

All of these tools provide a usage message when run without arguments.

Migrating data via logical replication
--------------------------------------

First, enable logical replication in your source Postgres database. In Amazon Aurora this is the `rds.logical_replication` parameter in the database cluster parameter group (and takes a while to apply, even if you apply immediately). In Neon this is a database-level setting. Alas, in Heroku this is not supported at all. Then, use the tools as follows:

Second, ensure there is network connectivity from the Internet to your database so that PlanetScale can reach it. In most hosts this is trivially the case. In AWS, you will need to ensure your Aurora or RDS _instance_ (not your Aurora _cluster_) allows public connectivity, its security group allows public connectivity, and its subnets' routing table(s) have a route from the Internet via an Internet Gateway.

`mk-logical-repl.sh` sets up logical replication between a primary (presumably elsewhere) and a replica (presumably PlanetScale for Postgres), including importing the schema.

`stat-logical-repl.sh` monitors (in a variety of ways) how caught up replication is to inform when you can move on to switching live traffic to PlanetScale.

`rm-logical-repl.sh` tears down the subscription and publication that `mk-logical-repl.sh` setup. Use this after you've switched traffic to PlanetScale.

Switching traffic to PlanetScale with downtime
----------------------------------------------

If you're OK taking a brief outage to complete your migration then you can switch traffic very simply:

1. Stop writing to your original primary Postgres database.
2. Use `ff-seq.sh` to ensure sequences on the replica are ahead of where they are on the primary.
3. Start writing to your new PlanetScale for Postgres primary.
4. Use `rm-logical-repl.sh` to teardown logical replication.

Switching traffic to PlanetScale without downtime
-------------------------------------------------

More likely, though, your application cannot tolerate downtime to migrate to PlanetScale for Postgres. This variation uses a second PlanetScale for Postgres database that acts as a proxy to control the process without downtime.

1. Create a second PlanetScale for Postgres database of equal size to the one receiving logical replication. This one doesn't need to be Metal even if your replica is.
2. `mk-proxy.sh` to setup this new database as a proxy using Postgres Foreign Data Wrappers.
3. Reconfigure your application to send Postgres traffic through this proxy.
4. Monitor `stat-logical-repl.sh` until logical replication is caught up.
5. Use `mv-proxy.sh` to reconfigure the proxy to be backed by your PlanetScale for Postgres database instead of your original primary. This step includes using `ff-seq.sh` to fast-forward your sequences.
6. Reconfigure your application to send Postgres traffic directly to your real PlanetScale for Postgres database instead of your proxy.
7. Use `rm-proxy.sh` to teardown the proxy. Delete it from the PlanetScale app.
8. Use `rm-logical-repl.sh` to teardown logical replication.

Replicating back as a failsafe
------------------------------

PlanetScale for Postgres supports logical replication in both directions so you can setup logical replication from PlanetScale for Postgres as the primary back to another database in your original provider as a failsafe, using `mk-logical-repl.sh` as outlined above.
