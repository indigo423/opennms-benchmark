# KVM Terraform Root

Deploys the OpenNMS benchmark lab on a KVM/libvirt host. For setup and deployment instructions see the [main README](../../README.md#kvmlibvirt).

## Deploying to Multiple KVM Hosts

To run the lab on different KVM hosts (e.g. switching between test machines), use **Terraform workspaces** so each host gets its own isolated state. Since `kvm.tfvars` is gitignored, you can freely edit it per host.

### 1. Create a workspace per host

```bash
terraform workspace new host-a
terraform workspace new host-b
```

List workspaces:

```bash
terraform workspace list
```

### 2. Deploy to a specific host

Select the workspace, update `kvm.tfvars` with the target host's URI, then deploy:

```bash
terraform workspace select host-a
# edit kvm.tfvars: set libvirt_uri = "qemu+ssh://root@host-a/system"
../../deploy.sh --provider kvm

terraform workspace select host-b
# edit kvm.tfvars: set libvirt_uri = "qemu+ssh://root@host-b/system"
../../deploy.sh --provider kvm
```

### 3. Destroy a specific host's lab

```bash
terraform workspace select host-a
../../deploy.sh --provider kvm --destroy
```

> Each workspace maintains completely independent state — destroying one host's lab has no effect on others.