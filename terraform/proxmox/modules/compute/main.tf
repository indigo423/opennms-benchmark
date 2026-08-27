terraform {
  required_version = ">= 1.5"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.99"
    }
  }
}

# One set of resources per node in the rendered topology, replacing seven
# hardcoded copies of each. The node set, its addresses and its routes come from
# ../../../modules/topology via the provider root, so this module only knows how
# to turn a node into Proxmox objects.
#
# Interface names arrive already rendered in each.value.interfaces[*].iface_name.
# They are NOT derived here, because the correct name depends on the template's
# machine type -- PVE's default i440fx yields ens18/ens19/ens20, machine=q35
# yields enp6s18 -- and the template is a hypervisor object this repository never
# sees. See the README's template steps.

module "cloud_init" {
  for_each = var.topology
  source   = "../../../modules/cloud-init"

  vm_name        = each.value.vm_name
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = var.extra_packages
  local_routes   = each.value.local_routes
  interfaces = [
    for i in each.value.interfaces : {
      name        = i.iface_name
      address     = i.address
      prefix      = i.prefix
      gateway     = i.gateway
      routes      = i.routes
      nameservers = i.nameservers
    }
  ]
}

# Cloud-init is delivered as snippet files, which the Proxmox API refuses to
# accept over HTTP: the provider opens an SSH session and writes them over SFTP.
# That is why the provider block needs an ssh stanza and a PAM account, and why
# snippets_datastore must be file-based.
resource "proxmox_virtual_environment_file" "user_data" {
  for_each = var.topology

  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "${each.value.vm_name}-user-data.yaml"
    data      = module.cloud_init[each.key].user_data
  }
}

resource "proxmox_virtual_environment_file" "network_data" {
  for_each = var.topology

  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "${each.value.vm_name}-network-config.yaml"
    data      = module.cloud_init[each.key].network_config
  }
}

resource "proxmox_virtual_environment_vm" "vm" {
  for_each = var.topology

  name      = each.value.vm_name
  node_name = var.proxmox_node
  vm_id     = each.value.vm_id
  tags      = ["opennms-benchmark"]

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = each.value.vcpu
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = each.value.disk_gb
    iothread     = true
  }

  # One NIC per subnet the spec gives this node, in spec order, so the Nth NIC
  # matches the Nth interface name the topology rendered.
  dynamic "network_device" {
    for_each = each.value.interfaces
    content {
      bridge = network_device.value.bridge
      model  = "virtio"
    }
  }

  # Terraform waits for the agent to report an address, which is what proves
  # cloud-init ran rather than merely that the clone succeeded. It is also the
  # failure most easily misread: without egress the guest cannot install
  # qemu-guest-agent, and the symptom is a provider timeout that says nothing
  # about routing. See the README on the management subnet's gateway.
  agent {
    enabled = true
  }

  serial_device {}

  operating_system {
    type = "l26"
  }

  initialization {
    user_data_file_id    = proxmox_virtual_environment_file.user_data[each.key].id
    network_data_file_id = proxmox_virtual_environment_file.network_data[each.key].id
  }
}
