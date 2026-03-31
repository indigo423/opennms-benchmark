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

module "cloud_init_elasticsearch" {
  source         = "../../../modules/cloud-init"
  vm_name        = "es-benchmark-01"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = ["qemu-guest-agent"]
  interfaces = [
    { name = "ens18", address = var.ip_elasticsearch, prefix = 26, gateway = var.gateway_mgmt },
    { name = "ens19", address = var.ip_es_core, prefix = 26, gateway = null },
  ]
}

module "cloud_init_database" {
  source         = "../../../modules/cloud-init"
  vm_name        = "db-benchmark-01"
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
  vm_name        = "core-benchmark-01"
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
  vm_name        = "kafka-benchmark-01"
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
  vm_name        = "minion-benchmark-01"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = ["qemu-guest-agent"]
  interfaces = [
    { name = "ens18", address = var.ip_minion, prefix = 26, gateway = var.gateway_mgmt },
    { name = "ens19", address = var.ip_minion_kafka, prefix = 26, gateway = null },
    { name = "ens20", address = var.ip_minion_sim, prefix = 26, gateway = null, routes = [{ to = var.net_sim_cidr, via = var.net_sim_gateway }] },
  ]
}

module "cloud_init_netsim" {
  source         = "../../../modules/cloud-init"
  vm_name        = "netsim-benchmark-01"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = ["qemu-guest-agent"]
  local_routes   = [var.net_sim_cidr]
  interfaces = [
    { name = "ens18", address = var.ip_netsim, prefix = 26, gateway = var.gateway_mgmt },
    { name = "ens19", address = var.ip_netsim_sim, prefix = 26, gateway = null },
  ]
}

module "cloud_init_monitoring" {
  source         = "../../../modules/cloud-init"
  vm_name        = "mon-benchmark-01"
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

resource "proxmox_virtual_environment_file" "user_data_elasticsearch" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "es-benchmark-01-user-data.yaml"
    data      = module.cloud_init_elasticsearch.user_data
  }
}

resource "proxmox_virtual_environment_file" "network_data_elasticsearch" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "es-benchmark-01-network-data.yaml"
    data      = module.cloud_init_elasticsearch.network_config
  }
}

resource "proxmox_virtual_environment_file" "user_data_database" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "db-benchmark-01-user-data.yaml"
    data      = module.cloud_init_database.user_data
  }
}

resource "proxmox_virtual_environment_file" "network_data_database" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "db-benchmark-01-network-data.yaml"
    data      = module.cloud_init_database.network_config
  }
}

resource "proxmox_virtual_environment_file" "user_data_core" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "core-benchmark-01-user-data.yaml"
    data      = module.cloud_init_core.user_data
  }
}

resource "proxmox_virtual_environment_file" "network_data_core" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "core-benchmark-01-network-data.yaml"
    data      = module.cloud_init_core.network_config
  }
}

resource "proxmox_virtual_environment_file" "user_data_kafka" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "kafka-benchmark-01-user-data.yaml"
    data      = module.cloud_init_kafka.user_data
  }
}

resource "proxmox_virtual_environment_file" "network_data_kafka" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "kafka-benchmark-01-network-data.yaml"
    data      = module.cloud_init_kafka.network_config
  }
}

resource "proxmox_virtual_environment_file" "user_data_minion" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "minion-benchmark-01-user-data.yaml"
    data      = module.cloud_init_minion.user_data
  }
}

resource "proxmox_virtual_environment_file" "network_data_minion" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "minion-benchmark-01-network-data.yaml"
    data      = module.cloud_init_minion.network_config
  }
}

resource "proxmox_virtual_environment_file" "user_data_netsim" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "netsim-benchmark-01-user-data.yaml"
    data      = module.cloud_init_netsim.user_data
  }
}

resource "proxmox_virtual_environment_file" "network_data_netsim" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "netsim-benchmark-01-network-data.yaml"
    data      = module.cloud_init_netsim.network_config
  }
}

resource "proxmox_virtual_environment_file" "user_data_monitoring" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "mon-benchmark-01-user-data.yaml"
    data      = module.cloud_init_monitoring.user_data
  }
}

resource "proxmox_virtual_environment_file" "network_data_monitoring" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "mon-benchmark-01-network-data.yaml"
    data      = module.cloud_init_monitoring.network_config
  }
}

# VMs — full clones of the Ubuntu 24.04 cloud-init template.
# Serialized with depends_on to prevent Proxmox storage lock contention
# during concurrent clone operations.
# Creation order: database → core → kafka → minion → netsim → monitoring

resource "proxmox_virtual_environment_vm" "database" {
  name      = "db-benchmark-01"
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
  name      = "core-benchmark-01"
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
  name      = "kafka-benchmark-01"
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
  name      = "minion-benchmark-01"
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

resource "proxmox_virtual_environment_vm" "netsim" {
  name      = "netsim-benchmark-01"
  node_name = var.proxmox_node
  vm_id     = var.vm_ids["netsim"]
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
    size         = var.disk_sizes_gb["netsim"]
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
    user_data_file_id    = proxmox_virtual_environment_file.user_data_netsim.id
    network_data_file_id = proxmox_virtual_environment_file.network_data_netsim.id
  }

  depends_on = [proxmox_virtual_environment_vm.minion]
}

resource "proxmox_virtual_environment_vm" "monitoring" {
  name      = "mon-benchmark-01"
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

  depends_on = [proxmox_virtual_environment_vm.netsim]
}

resource "proxmox_virtual_environment_vm" "elasticsearch" {
  name      = "es-benchmark-01"
  node_name = var.proxmox_node
  vm_id     = var.vm_ids["elasticsearch"]
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
    dedicated = 8192
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.disk_sizes_gb["elasticsearch"]
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
    user_data_file_id    = proxmox_virtual_environment_file.user_data_elasticsearch.id
    network_data_file_id = proxmox_virtual_environment_file.network_data_elasticsearch.id
  }

  depends_on = [proxmox_virtual_environment_vm.monitoring]
}
