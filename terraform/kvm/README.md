# KVM Terraform Root

Deploys the OpenNMS benchmark lab on a KVM/libvirt host.

## Prerequisites

### 1. Ubuntu 24.04 LTS Cloud Image

Download the cloud image (not the server installer ISO) into the libvirt storage pool before running `terraform apply`:

```bash
wget -O /var/lib/libvirt/images/noble-server-cloudimg-amd64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

The path must match `ubuntu_cloud_image` in `kvm.tfvars`. Terraform will fail with a clear error if the file is missing.

### 2. Libvirt storage pool

Ensure the `default` storage pool exists and is active:

```bash
virsh pool-list --all
virsh pool-start default   # if inactive
```

### 3. SSH key

The public key is read automatically from `ssh_key_path` in `kvm.tfvars` (defaults to `~/.ssh/id_rsa.pub`). No environment variable needed.

## Deploy

```bash
cd terraform/kvm
terraform init
terraform apply -var-file=../lab.tfvars -var-file=kvm.tfvars
```

## Getting VM IP Addresses

After `terraform apply`, VMs on the `lab-mgmt` network have static IPs defined in `lab.tfvars`. VMs on the `lab-external` bridge network receive a DHCP address from your router — these are only known after the VM boots.

Once `qemu-guest-agent` is running inside the VMs, query all assigned IPs with:

```bash
LIBVIRT_URI="qemu+ssh://user@your-kvm-host/system"
for vm in database core kafka minion snmpsim mon; do
  echo -n "$vm: "
  virsh -c $LIBVIRT_URI domifaddr $vm --source agent 2>/dev/null || echo "no lease yet"
done
```

Use `--source agent` (via qemu-guest-agent) to see all interfaces including the external DHCP one. If the agent isn't ready yet, retry after a minute — cloud-init installs it on first boot.

## Deploying to a Remote KVM Host

By default, `kvm.tfvars` connects to the local KVM daemon:

```hcl
libvirt_uri = "qemu:///system"
```

To deploy to a **remote** KVM host, change this to an SSH URI:

```hcl
libvirt_uri = "qemu+ssh://user@your-kvm-host/system"
```

The `dmacvicar/libvirt` provider uses libvirt's native transport layer, so no additional Terraform plugins are required.

### Prerequisites on the remote KVM host

1. **libvirtd running**

   ```bash
   sudo systemctl enable --now libvirtd
   ```

2. **Your user in the `libvirt` group**

   ```bash
   sudo usermod -aG libvirt $USER
   # Log out and back in for the group change to take effect
   ```

3. **SSH access** — the connecting user must be able to SSH to the host without a passphrase prompt. Load your key into the SSH agent on your local machine:

   ```bash
   ssh-add ~/.ssh/id_rsa
   ```

4. **Ubuntu 24.04 LTS cloud image** on the remote host, at the path specified by `ubuntu_cloud_image` in `kvm.tfvars`:

   ```bash
   sudo wget -O /var/lib/libvirt/images/noble-server-cloudimg-amd64.img \
     https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
   ```

5. **libvirt default storage pool** active on the remote host:

   ```bash
   virsh -c qemu+ssh://user@your-kvm-host/system pool-list --all
   virsh -c qemu+ssh://user@your-kvm-host/system pool-start default   # if inactive
   ```

### Remote-specific `kvm.tfvars`

Create a separate var file (e.g., `kvm-remote.tfvars`) to avoid editing the defaults:

```hcl
libvirt_uri        = "qemu+ssh://user@your-kvm-host/system"
ubuntu_cloud_image = "/var/lib/libvirt/images/noble-server-cloudimg-amd64.img"
storage_pool       = "default"
ssh_key_path       = "~/.ssh/id_rsa"
admin_user         = "ubuntu"
```

All paths in `kvm.tfvars` (storage pool, cloud image) are resolved **on the remote host**, not your local machine.

### Deploy to the remote host

```bash
cd terraform/kvm
terraform init
terraform apply -var-file=../lab.tfvars -var-file=kvm.tfvars -var-file=kvm-remote.tfvars
```

### Verify connectivity before applying

Test that Terraform can reach libvirtd on the remote host before running `apply`:

```bash
virsh -c qemu+ssh://user@your-kvm-host/system list --all
```

A successful response (even an empty VM list) confirms the connection works.

## Deploying to Multiple KVM Hosts

To run the lab on different KVM hosts (e.g. switching between test machines), use one **tfvars file per host** combined with **Terraform workspaces** so each host gets its own isolated state.

### 1. Create a tfvars file per host

```
kvm-host-a.tfvars
kvm-host-b.tfvars
```

Each file overrides only the host-specific values:

```hcl
# kvm-host-a.tfvars
libvirt_uri = "qemu+ssh://root@your-kvm.host/system?no_verify=1"
bridge_name = "br0"
```

```hcl
# kvm-host-b.tfvars
libvirt_uri = "qemu+ssh://root@other-host.example.com/system?no_verify=1"
bridge_name = "br0"
```

All other values (`lab.tfvars`, `kvm.tfvars`) are shared across hosts.

### 2. Create a workspace per host

```bash
terraform workspace new host-a
terraform workspace new host-b
```

List workspaces:

```bash
terraform workspace list
```

### 3. Deploy to a specific host

Select the workspace, then apply with the matching tfvars:

```bash
terraform workspace select host-a
terraform apply -var-file=../lab.tfvars -var-file=kvm.tfvars -var-file=kvm-host-a.tfvars

terraform workspace select host-b
terraform apply -var-file=../lab.tfvars -var-file=kvm.tfvars -var-file=kvm-host-b.tfvars
```

### 4. Destroy a specific host's lab

```bash
terraform workspace select host-a
terraform destroy -var-file=../lab.tfvars -var-file=kvm.tfvars -var-file=kvm-host-a.tfvars
```

> Each workspace maintains completely independent state — destroying one host's lab has no effect on others.

## Network Quality Note

All 6 VMs must be connected by a network sufficient to avoid introducing artificial latency into benchmark measurements. On a single KVM host this is inherent. On a multi-host KVM cluster, ensure VMs are placed on the same physical host or connected via a low-latency fabric.
