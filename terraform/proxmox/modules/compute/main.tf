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
# Interface names arrive already rendered in each.value.interfaces[*].iface_name,
# derived in the provider root from var.proxmox_machine -- the same value this
# module sets on the VM. q35 yields enp6s18/enp6s19/enp6s20 and pc (i440fx)
# yields ens18/ens19/ens20, so the two must come from one place or every guest
# comes up with no network.

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

  # Set here rather than inherited from the template. Guest NIC names depend on
  # it, and the interface names in each.value.interfaces were rendered from the
  # same variable, so the two cannot disagree.
  machine = var.proxmox_machine

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  # type = "host" passes the Broadwell-EP instruction set (AVX2, AES-NI) straight
  # through with no emulation. Meaningful for a benchmark bed: an emulated CPU
  # model would make the numbers describe the emulation, not the hardware.
  #
  # numa = true on a dual-socket host so the guest's memory comes from one node
  # instead of being spread across the QPI link unawares. sockets stays at 1
  # deliberately: every role here is at most 4 vCPU against a 12-core socket, so
  # a single-socket guest fits inside one NUMA node and never traverses the
  # interconnect. Raising sockets would spread it on purpose.
  cpu {
    cores   = each.value.vcpu
    sockets = 1
    type    = "host"
    numa    = true
  }

  memory {
    dedicated = each.value.memory
  }

  # virtio-scsi-single, not virtio-scsi-pci: PVE only honours a disk's iothread
  # with the "single" controller, which gives each disk its own virtio-scsi
  # controller and its own I/O thread. With the shared pci controller the
  # iothread flag below is accepted and inert -- which is what the first
  # deployment ran with, inheriting the controller from the template.
  scsi_hardware = "virtio-scsi-single"

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

  # Declared, not inherited. The template carries vga=serial0, so a clone got a
  # serial primary console by accident -- and Terraform, not managing vga, planned
  # to remove it on the next replacement. That console is how the ens18-vs-enp6s18
  # mismatch was diagnosed: it is the only way to see a guest that has no network
  # precisely because its network is misconfigured.
  vga {
    type = "serial0"
  }

  operating_system {
    type = "l26"
  }

  initialization {
    user_data_file_id    = proxmox_virtual_environment_file.user_data[each.key].id
    network_data_file_id = proxmox_virtual_environment_file.network_data[each.key].id
  }
}
