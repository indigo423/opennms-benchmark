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

```bash
export TF_VAR_ssh_public_key=$(cat ~/.ssh/id_rsa.pub)
```

## Deploy

```bash
cd terraform/kvm
terraform init
terraform apply -var-file=../lab.tfvars -var-file=kvm.tfvars
```

## Network Quality Note

All 6 VMs must be connected by a network sufficient to avoid introducing artificial latency into benchmark measurements. On a single KVM host this is inherent. On a multi-host KVM cluster, ensure VMs are placed on the same physical host or connected via a low-latency fabric.
