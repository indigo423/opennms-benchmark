# VMware vSphere Terraform Provider

Deploys the OpenNMS benchmark lab on a VMware vSphere environment managed by vCenter. For general setup and deployment instructions see the [main README](../../README.md).

## Prerequisites

Complete these steps **before** running `terraform apply`.

### 1. Create port groups

Create five port groups on a vSwitch or dvSwitch in your vSphere environment. Internal port groups (db, kafka, sim) carry only lab traffic and do not require uplinks. The management and external port groups need uplinks for operator SSH access.

| Variable | Purpose | Subnet |
|---|---|---|
| `pg_mgmt` | Management — static IPs, operator SSH | `192.0.2.192/26` |
| `pg_db` | Database traffic between Core and PostgreSQL | `192.0.2.0/26` |
| `pg_kafka` | Kafka coordination (Core, Kafka, Minion) | `192.0.2.64/26` |
| `pg_sim` | SNMP simulation network (Minion ↔ NetSim) | `192.0.2.128/26` |
| `pg_ext` | External DHCP — monitoring VM gets a routable IP here | _(DHCP)_ |

### 2. Build a template VM

The provider clones all VMs from a single Ubuntu 24.04 LTS template. Build it once:

1. Import the Ubuntu 24.04 cloud image OVA (or attach the cloud `.vmdk`):
   ```bash
   govc import.ova noble-server-cloudimg-amd64.ova
   ```
2. Boot the VM and install required packages:
   ```bash
   apt install -y open-vm-tools cloud-init
   ```
3. Generalize (clear cloud-init state):
   ```bash
   cloud-init clean --logs
   sudo shutdown -h now
   ```
4. In the vSphere UI, right-click the VM → **Convert to Template**.

The template name must match the `template_name` variable in `vmware.tfvars`.

## Deployment

```bash
cp vmware.tfvars.example vmware.tfvars
# Edit vmware.tfvars with your vCenter credentials and topology values

# From the repo root:
./deploy.sh --provider vmware

# With self-signed vCenter certificate:
./deploy.sh --provider vmware --tf-args "-var vsphere_insecure=true"
```

## Network interface naming

VMware VMXNET3 adapters on Ubuntu 24.04 enumerate by PCI slot:

| Interface | NIC order | Used by |
|---|---|---|
| `ens160` | 1st (PCI 0:7.0) | Management (`pg_mgmt`) on all VMs |
| `ens192` | 2nd (PCI 0:8.0) | Role-specific subnet on all VMs |
| `ens224` | 3rd (PCI 0:9.0) | Core (kafka), Minion (sim) |
| `ens256` | 4th (PCI 0:10.0) | _(reserved)_ |

Verify on a running VM: `ssh ubuntu@<ip> ip link`

## Cloud-init delivery

Unlike KVM (cdrom ISO) or Proxmox (snippets file), VMware delivers cloud-init payloads via **VMware guestinfo** properties set in `extra_config`. `open-vm-tools` reads these properties at boot and hands them to cloud-init, which configures users, SSH keys, `/etc/hosts`, and Netplan network configuration.

This means no ISO attachment or file upload is needed — cloud-init is fully declarative in the Terraform resource.

## Jump host

The monitoring VM (`mon-benchmark-01`) has two NICs:

- `ens160` — static IP `192.0.2.200` on `pg_mgmt`
- `ens192` — DHCP address on `pg_ext` (the lab jump host)

`deploy.sh` automatically discovers the external IP after the first apply by SSHing through the vSphere host to the monitoring VM, then re-runs apply with `-var jump_host=<ip>` to regenerate the Ansible inventory with ProxyJump configured.

If you need to set it manually:

```bash
# Find the external IP
ssh ubuntu@192.0.2.200 ip -4 addr show ens192

# Re-apply with the discovered IP
terraform apply -var-file=../lab.tfvars -var-file=../disk-sizes.tfvars -var-file=vmware.tfvars -var jump_host=<ip>
```
