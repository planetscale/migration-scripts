# pgcopydb Migration Instance Templates

Infrastructure-as-code templates for provisioning a migration instance pre-configured with [pgcopydb](https://github.com/planetscale/pgcopydb) and the [PlanetScale migration helper scripts](../pgcopydb-helpers/). Each template creates a compute instance running Ubuntu 24.04 that installs pgcopydb, PostgreSQL client tools, and the helper scripts at boot.

## Available Templates

| Template | Platform | Tool | README |
|----------|----------|------|--------|
| [AWS CloudFormation](./aws-cloudformation/) | AWS EC2 | CloudFormation | [README](./aws-cloudformation/README-pgcopydb-cfn.md) |
| [AWS Terraform](./aws-terraform/) | AWS EC2 | Terraform | [README](./aws-terraform/README-pgcopydb-aws-tf.md) |
| [GCP Terraform](./gcp-terraform/) | GCP Compute Engine | Terraform | [README](./gcp-terraform/README-pgcopydb-gcp.md) |

All three templates produce an equivalent migration instance — choose based on your cloud provider and preferred provisioning tool.

## What Gets Provisioned

- A compute instance with pgcopydb and PostgreSQL 18 client tools
- An attached data volume for migration working data
- Network and access configuration (security group/firewall rule, IAM/SSH via SSM or IAP)
- Migration helper scripts from this repo deployed to `/home/ubuntu/`, including `env-template`

The templates do not create `~/.env`. The helper scripts own that file, and `env-template` is its reference copy.

## After Provisioning

Connect to the instance, then create the configuration file that every helper script reads:

```bash
cp ~/env-template ~/.env
chmod 600 ~/.env
```

Edit `~/.env` and set `PGCOPYDB_SOURCE_PGURI` and `PGCOPYDB_TARGET_PGURI`. The other settings have working defaults — see [Script Configuration](../pgcopydb-helpers/README.md#script-configuration).

Then customize `~/filters.ini` and follow the [migration workflow](../pgcopydb-helpers/README.md#migration-workflow).
