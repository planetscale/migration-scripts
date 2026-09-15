# PlanetScale Migration — pgcopydb Migration Instance (Azure Terraform)

## What This Does

This Terraform template creates an Azure VM pre-configured with
[pgcopydb](https://github.com/planetscale/pgcopydb), the tool PlanetScale uses to migrate
your PostgreSQL data. The instance runs Ubuntu 24.04 and pulls the latest
[PlanetScale migration helper scripts](https://github.com/planetscale/migration-scripts)
at boot.

## What Gets Created

- A virtual machine with pgcopydb and PostgreSQL client tools installed
- A Premium SSD v2 data disk for migration working data, mounted at `/home/ubuntu`
- A network security group and a public IP for network access
- A system-assigned managed identity with Entra ID SSH login enabled
- Migration helper scripts from `github.com/planetscale/migration-scripts` in `/home/ubuntu/`

A resource group is just a folder that holds Azure resources. This template creates its own
(`planetscale-migration-rg`) and only reads your existing virtual network, so tearing it down never
touches anything of yours.

## Sizing

`vm_size` sets the speed. Data disk IOPS are provisioned to match the VM's NVMe ceiling, so you
never pay for IOPS the VM cannot reach and the disk is never throttled:

| `vm_size` | vCPU / RAM | Provisioned disk IOPS | Throughput |
|-----------|------------|-----------------------|------------|
| `Standard_E4bds_v5` | 4 / 32 GiB | 21,000 | 600 MB/s |
| `Standard_E8bds_v5` *(default)* | 8 / 64 GiB | 44,000 | 1,200 MB/s |
| `Standard_E16bds_v5` | 16 / 128 GiB | 80,000 | 2,000 MB/s |

`data_disk_size_gb` sets capacity only — `500`, `1000` (default), or `3000` GB. Larger VM sizes are not offered because a single Premium
SSD v2 disk tops out at 80,000 IOPS / 2,000 MB/s, which `Standard_E16bds_v5` already saturates.

## How to Deploy

### Prerequisites
- [Terraform](https://developer.hashicorp.com/terraform/install) installed (v1.0+)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest) installed 
- Azure CLI authenticated (`az login`) and your subscription ID (`az account show --query id -o tsv`)
- An existing virtual network and subnet, plus the name of the resource group holding them
- A region that supports zonal Premium SSD v2 disks (the `eastus` default does)
- For keyless SSH: `az extension add --name ssh`

### Steps

1. **Save both files** (`pgcopydb-migration-instance.tf` and `custom-data.sh`) in the same directory

2. **Deploy** (restricting SSH to your IP is recommended — get it from [icanhazip.com](https://icanhazip.com)):
   ```bash
   terraform init
   terraform apply \
     -var="subscription_id=YOUR_SUBSCRIPTION_ID" \
     -var="vnet_resource_group_name=YOUR_NETWORK_RG" \
     -var="vnet_name=YOUR_VNET" \
     -var="subnet_name=YOUR_SUBNET" \
     -var="your_public_ip=$(curl -4 icanhazip.com)"
   ```

3. **Connect** as `ubuntu` — the account the tooling is installed under:
   ```bash
   terraform output -raw generated_ssh_private_key > ./migration_key
   chmod 600 ./migration_key
   ssh -i ./migration_key ubuntu@$(terraform output -raw public_ip)
   ```
   With your own `ssh_public_key`: `ssh ubuntu@$(terraform output -raw public_ip)`.

   Entra ID (`az ssh vm ...`, or the portal's **Connect**) needs no key but logs
   you in as yourself, not `ubuntu` — add `sudo su - ubuntu`.

First boot takes 10–15 minutes because pgcopydb is built from source. Watch progress with
`sudo tail -f /var/log/pgcopydb-setup.log` (or `/var/log/cloud-init-output.log`), and confirm the
data disk mounted with `df -h /home/ubuntu`.

If a zone has no NVMe capacity for the chosen size, `apply` fails with an allocation error — retry
with a different `-var="zone=2"`, since NVMe is required for the disk performance above.

## How to Tear Down

```bash
terraform destroy \
  -var="subscription_id=YOUR_SUBSCRIPTION_ID" \
  -var="vnet_resource_group_name=YOUR_NETWORK_RG" \
  -var="vnet_name=YOUR_VNET" \
  -var="subnet_name=YOUR_SUBNET" \
  -var="your_public_ip=$(curl -4 icanhazip.com)"
```

## Questions?

Visit [PlanetScale documentation](https://planetscale.com/docs) for more information.
