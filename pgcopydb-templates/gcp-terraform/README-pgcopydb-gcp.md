# PlanetScale Migration — pgcopydb Migration Instance (GCP Terraform)

## What This Does

This Terraform template creates a Compute Engine instance pre-configured with
[pgcopydb](https://github.com/planetscale/pgcopydb), the tool PlanetScale uses to migrate
your PostgreSQL data. The instance runs Ubuntu 24.04 and pulls the latest
[PlanetScale migration helper scripts](https://github.com/planetscale/migration-scripts)
at boot.

## What Gets Created

- A Compute Engine instance with pgcopydb and PostgreSQL client tools installed
- A persistent disk for migration working data
- A firewall rule for SSH access via IAP tunnel
- A startup script that installs all required tools
- Migration helper scripts from `github.com/planetscale/migration-scripts` in `/home/ubuntu/`

## How to Deploy

### Prerequisites
- [Terraform](https://developer.hashicorp.com/terraform/install) installed (v1.0+)
- A GCP project with a VPC and subnet
- `gcloud` CLI authenticated

### Steps

1. **Save both files** (`pgcopydb-migration-instance.tf` and `startup-script.sh`) in the same directory

2. **Deploy** (restricting SSH to your IP is recommended — get it from [icanhazip.com](https://icanhazip.com)):
   ```bash
   terraform init
   terraform apply \
     -var="project_id=YOUR_PROJECT" \
     -var="vpc_name=YOUR_VPC" \
     -var="subnet_name=YOUR_SUBNET" \
     -var="your_public_ip=$(curl -s icanhazip.com)"
   ```

3. **Connect** via IAP tunnel:
   ```bash
   gcloud compute ssh $(terraform output -raw instance_name) \
     --zone=$(terraform output -raw zone) \
     --project=YOUR_PROJECT \
     --tunnel-through-iap
   ```
   Or via the GCP Console (browser-based SSH — open the instance in Compute Engine and click **SSH**).

## How to Tear Down

```bash
terraform destroy \
  -var="project_id=YOUR_PROJECT" \
  -var="vpc_name=YOUR_VPC" \
  -var="subnet_name=YOUR_SUBNET" \
  -var="your_public_ip=$(curl -s icanhazip.com)"
```

## Questions?

Visit [PlanetScale documentation](https://planetscale.com/docs) for more information.
