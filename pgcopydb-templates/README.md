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

- A compute instance with pgcopydb and PostgreSQL 17 client tools
- An attached data volume for migration working data
- Network and access configuration (security group/firewall rule, IAM/SSH via SSM or IAP)
- Migration helper scripts from this repo deployed to `/home/ubuntu/`

## After Provisioning

Once the instance is running, connect to it and follow the [migration workflow](../pgcopydb-helpers/README.md#migration-workflow) starting with setting up `~/.env` and `~/filters.ini`.
