terraform {
  required_version = ">= 1.5"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.99"
    }
  }
}

# Cloud-init configuration — rendered via the shared module (same templates as KVM and Azure).
# Interface names inside Proxmox q35 VMs with virtio-net (Ubuntu 24.04):
#   ens18 = first NIC, ens19 = second, ens20 = third, ens21 = fourth.
# Verify on your Proxmox setup: ssh ubuntu@<ip> ip link

module "cloud_init_database" {
  source         = "../../../modules/cloud-init"
  vm_name        = "database"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = ["qemu-guest-agent"]
  interfaces = [
    { name = "ens18", address = var.ip_database, prefix = 26, gateway = var.gateway_mgmt },
    { name = "ens19", address = var.ip_database_db, prefix = 26, gateway = null },
  ]
}

module "cloud_init_core" {
  source         = "../../../modules/cloud-init"
  vm_name        = "core"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = ["qemu-guest-agent"]
  interfaces = [
    { name = "ens18", address = var.ip_core, prefix = 26, gateway = var.gateway_mgmt },
    { name = "ens19", address = var.ip_core_db, prefix = 26, gateway = null },
    { name = "ens20", address = var.ip_core_kafka, prefix = 26, gateway = null },
  ]
}

module "cloud_init_kafka" {
  source         = "../../../modules/cloud-init"
  vm_name        = "kafka"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = ["qemu-guest-agent"]
  interfaces = [
    { name = "ens18", address = var.ip_kafka, prefix = 26, gateway = var.gateway_mgmt },
    { name = "ens19", address = var.ip_kafka_kafka, prefix = 26, gateway = null },
  ]
}

module "cloud_init_minion" {
  source         = "../../../modules/cloud-init"
  vm_name        = "minion"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = ["qemu-guest-agent"]
  interfaces = [
    { name = "ens18", address = var.ip_minion, prefix = 26, gateway = var.gateway_mgmt },
    { name = "ens19", address = var.ip_minion_kafka, prefix = 26, gateway = null },
    { name = "ens20", address = var.ip_minion_sim, prefix = 26, gateway = null, routes = [{ to = var.snmp_sim_cidr, via = var.snmp_sim_gateway }] },
  ]
}

module "cloud_init_snmpsim" {
  source         = "../../../modules/cloud-init"
  vm_name        = "snmpsim"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = ["qemu-guest-agent"]
  interfaces = [
    { name = "ens18", address = var.ip_snmpsim, prefix = 26, gateway = var.gateway_mgmt },
    { name = "ens19", address = var.ip_snmpsim_sim, prefix = 26, gateway = null },
  ]
}

module "cloud_init_monitoring" {
  source         = "../../../modules/cloud-init"
  vm_name        = "monitoring"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = ["qemu-guest-agent"]
  interfaces = [
    { name = "ens18", address = var.ip_monitoring, prefix = 26, gateway = null },
    { name = "ens19", address = null, prefix = null, gateway = null },
  ]
}

# Cloud-init snippet files — uploaded to the Proxmox snippets datastore via SFTP.
# Requires a file-based datastore (e.g. "local"); LVM-thin datastores are not supported.

resource "proxmox_virtual_environment_file" "user_data_database" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "database-user-data.yaml"
    data      = module.cloud_init_database.user_data
  }
}

resource "proxmox_virtual_environment_file" "network_data_database" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "database-network-data.yaml"
    data      = module.cloud_init_database.network_config
  }
}

resource "proxmox_virtual_environment_file" "user_data_core" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "core-user-data.yaml"
    data      = module.cloud_init_core.user_data
  }
}

resource "proxmox_virtual_environment_file" "network_data_core" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "core-network-data.yaml"
    data      = module.cloud_init_core.network_config
  }
}

resource "proxmox_virtual_environment_file" "user_data_kafka" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "kafka-user-data.yaml"
    data      = module.cloud_init_kafka.user_data
  }
}

resource "proxmox_virtual_environment_file" "network_data_kafka" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "kafka-network-data.yaml"
    data      = module.cloud_init_kafka.network_config
  }
}

resource "proxmox_virtual_environment_file" "user_data_minion" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "minion-user-data.yaml"
    data      = module.cloud_init_minion.user_data
  }
}

resource "proxmox_virtual_environment_file" "network_data_minion" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "minion-network-data.yaml"
    data      = module.cloud_init_minion.network_config
  }
}

resource "proxmox_virtual_environment_file" "user_data_snmpsim" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "snmpsim-user-data.yaml"
    data      = module.cloud_init_snmpsim.user_data
  }
}

resource "proxmox_virtual_environment_file" "network_data_snmpsim" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "snmpsim-network-data.yaml"
    data      = module.cloud_init_snmpsim.network_config
  }
}

resource "proxmox_virtual_environment_file" "user_data_monitoring" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "monitoring-user-data.yaml"
    data      = module.cloud_init_monitoring.user_data
  }
}

resource "proxmox_virtual_environment_file" "network_data_monitoring" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "monitoring-network-data.yaml"
    data      = module.cloud_init_monitoring.network_config
  }
}

# VMs — full clones of the Ubuntu 24.04 cloud-init template.
# Serialized with depends_on to prevent Proxmox storage lock contention
# during concurrent clone operations.
# Creation order: database → core → kafka → minion → snmpsim → monitoring

resource "proxmox_virtual_environment_vm" "database" {
  name      = "database"
  node_name = var.proxmox_node
  vm_id     = var.vm_ids["database"]
  tags      = ["opennms-benchmark"]

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.disk_sizes_gb["database"]
    iothread     = true
  }

  network_device {
    bridge = var.bridge_mgmt
    model  = "virtio"
  }

  network_device {
    bridge = var.bridge_db
    model  = "virtio"
  }

  agent {
    enabled = true
  }

  serial_device {}

  operating_system {
    type = "l26"
  }

  initialization {
    user_data_file_id    = proxmox_virtual_environment_file.user_data_database.id
    network_data_file_id = proxmox_virtual_environment_file.network_data_database.id
  }
}

resource "proxmox_virtual_environment_vm" "core" {
  name      = "core"
  node_name = var.proxmox_node
  vm_id     = var.vm_ids["core"]
  tags      = ["opennms-benchmark"]

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 16384
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.disk_sizes_gb["core"]
    iothread     = true
  }

  network_device {
    bridge = var.bridge_mgmt
    model  = "virtio"
  }

  network_device {
    bridge = var.bridge_db
    model  = "virtio"
  }

  network_device {
    bridge = var.bridge_kafka
    model  = "virtio"
  }

  agent {
    enabled = true
  }

  serial_device {}

  operating_system {
    type = "l26"
  }

  initialization {
    user_data_file_id    = proxmox_virtual_environment_file.user_data_core.id
    network_data_file_id = proxmox_virtual_environment_file.network_data_core.id
  }

  depends_on = [proxmox_virtual_environment_vm.database]
}

resource "proxmox_virtual_environment_vm" "kafka" {
  name      = "kafka"
  node_name = var.proxmox_node
  vm_id     = var.vm_ids["kafka"]
  tags      = ["opennms-benchmark"]

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.disk_sizes_gb["kafka"]
    iothread     = true
  }

  network_device {
    bridge = var.bridge_mgmt
    model  = "virtio"
  }

  network_device {
    bridge = var.bridge_kafka
    model  = "virtio"
  }

  agent {
    enabled = true
  }

  serial_device {}

  operating_system {
    type = "l26"
  }

  initialization {
    user_data_file_id    = proxmox_virtual_environment_file.user_data_kafka.id
    network_data_file_id = proxmox_virtual_environment_file.network_data_kafka.id
  }

  depends_on = [proxmox_virtual_environment_vm.core]
}

resource "proxmox_virtual_environment_vm" "minion" {
  name      = "minion"
  node_name = var.proxmox_node
  vm_id     = var.vm_ids["minion"]
  tags      = ["opennms-benchmark"]

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.disk_sizes_gb["minion"]
    iothread     = true
  }

  network_device {
    bridge = var.bridge_mgmt
    model  = "virtio"
  }

  network_device {
    bridge = var.bridge_kafka
    model  = "virtio"
  }

  network_device {
    bridge = var.bridge_sim
    model  = "virtio"
  }

  agent {
    enabled = true
  }

  serial_device {}

  operating_system {
    type = "l26"
  }

  initialization {
    user_data_file_id    = proxmox_virtual_environment_file.user_data_minion.id
    network_data_file_id = proxmox_virtual_environment_file.network_data_minion.id
  }

  depends_on = [proxmox_virtual_environment_vm.kafka]
}

resource "proxmox_virtual_environment_vm" "snmpsim" {
  name      = "snmpsim"
  node_name = var.proxmox_node
  vm_id     = var.vm_ids["snmpsim"]
  tags      = ["opennms-benchmark"]

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.disk_sizes_gb["snmpsim"]
    iothread     = true
  }

  network_device {
    bridge = var.bridge_mgmt
    model  = "virtio"
  }

  network_device {
    bridge = var.bridge_sim
    model  = "virtio"
  }

  agent {
    enabled = true
  }

  serial_device {}

  operating_system {
    type = "l26"
  }

  initialization {
    user_data_file_id    = proxmox_virtual_environment_file.user_data_snmpsim.id
    network_data_file_id = proxmox_virtual_environment_file.network_data_snmpsim.id
  }

  depends_on = [proxmox_virtual_environment_vm.minion]
}

resource "proxmox_virtual_environment_vm" "monitoring" {
  name      = "monitoring"
  node_name = var.proxmox_node
  vm_id     = var.vm_ids["monitoring"]
  tags      = ["opennms-benchmark"]

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.disk_sizes_gb["monitoring"]
    iothread     = true
  }

  network_device {
    bridge = var.bridge_mgmt
    model  = "virtio"
  }

  network_device {
    bridge = var.bridge_ext
    model  = "virtio"
  }

  agent {
    enabled = true
  }

  serial_device {}

  operating_system {
    type = "l26"
  }

  initialization {
    user_data_file_id    = proxmox_virtual_environment_file.user_data_monitoring.id
    network_data_file_id = proxmox_virtual_environment_file.network_data_monitoring.id
  }

  depends_on = [proxmox_virtual_environment_vm.snmpsim]
}
