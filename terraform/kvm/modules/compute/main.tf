# Ubuntu 24.04 LTS cloud image — must be the cloud image (qcow2), NOT the server installer ISO.
# Download before running terraform apply:
#   wget -O /var/lib/libvirt/images/noble-server-cloudimg-amd64.img \
#     https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

resource "libvirt_volume" "ubuntu_base" {
  name   = "ubuntu-24.04-base"
  pool   = var.storage_pool
  source = var.ubuntu_cloud_image
  format = "qcow2"

  lifecycle {
    precondition {
      condition     = fileexists(var.ubuntu_cloud_image)
      error_message = "Ubuntu 24.04 cloud image not found at '${var.ubuntu_cloud_image}'. Download noble-server-cloudimg-amd64.img from https://cloud-images.ubuntu.com/noble/current/ first."
    }
  }
}

# Per-VM volumes (thin-provisioned clones of base image)
resource "libvirt_volume" "database" {
  name           = "database.qcow2"
  pool           = var.storage_pool
  base_volume_id = libvirt_volume.ubuntu_base.id
  format         = "qcow2"
}

resource "libvirt_volume" "core" {
  name           = "core.qcow2"
  pool           = var.storage_pool
  base_volume_id = libvirt_volume.ubuntu_base.id
  format         = "qcow2"
}

resource "libvirt_volume" "kafka" {
  name           = "kafka.qcow2"
  pool           = var.storage_pool
  base_volume_id = libvirt_volume.ubuntu_base.id
  format         = "qcow2"
}

resource "libvirt_volume" "minion" {
  name           = "minion.qcow2"
  pool           = var.storage_pool
  base_volume_id = libvirt_volume.ubuntu_base.id
  format         = "qcow2"
}

resource "libvirt_volume" "snmpsim" {
  name           = "snmpsim.qcow2"
  pool           = var.storage_pool
  base_volume_id = libvirt_volume.ubuntu_base.id
  format         = "qcow2"
}

resource "libvirt_volume" "monitoring" {
  name           = "monitoring.qcow2"
  pool           = var.storage_pool
  base_volume_id = libvirt_volume.ubuntu_base.id
  format         = "qcow2"
}

# Cloud-init disks
module "cloud_init_database" {
  source         = "../../../modules/cloud-init"
  vm_name        = "database"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  interfaces = [
    { name = "eth0", address = var.ip_database, prefix = 26, gateway = null },
    { name = "eth1", address = var.ip_database_db, prefix = 26, gateway = null },
  ]
}

module "cloud_init_core" {
  source         = "../../../modules/cloud-init"
  vm_name        = "core"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  interfaces = [
    { name = "eth0", address = var.ip_core, prefix = 26, gateway = null },
    { name = "eth1", address = var.ip_core_db, prefix = 26, gateway = null },
    { name = "eth2", address = var.ip_core_kafka, prefix = 26, gateway = null },
  ]
}

module "cloud_init_kafka" {
  source         = "../../../modules/cloud-init"
  vm_name        = "kafka"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  interfaces = [
    { name = "eth0", address = var.ip_kafka, prefix = 26, gateway = null },
    { name = "eth1", address = var.ip_kafka_kafka, prefix = 26, gateway = null },
  ]
}

module "cloud_init_minion" {
  source         = "../../../modules/cloud-init"
  vm_name        = "minion"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  interfaces = [
    { name = "eth0", address = var.ip_minion, prefix = 26, gateway = null },
    { name = "eth1", address = var.ip_minion_kafka, prefix = 26, gateway = null },
    { name = "eth2", address = var.ip_minion_sim, prefix = 26, gateway = null },
  ]
  extra_routes = [
    { to = var.snmp_sim_cidr, via = var.snmp_sim_gateway }
  ]
}

module "cloud_init_snmpsim" {
  source         = "../../../modules/cloud-init"
  vm_name        = "snmpsim"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  interfaces = [
    { name = "eth0", address = var.ip_snmpsim, prefix = 26, gateway = null },
    { name = "eth1", address = var.ip_snmpsim, prefix = 26, gateway = null },
  ]
}

module "cloud_init_monitoring" {
  source         = "../../../modules/cloud-init"
  vm_name        = "mon"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  interfaces = [
    { name = "eth0", address = var.ip_monitoring, prefix = 26, gateway = null },
  ]
}

resource "libvirt_cloudinit_disk" "database" {
  name           = "database-cloudinit.iso"
  pool           = var.storage_pool
  user_data      = module.cloud_init_database.user_data
  network_config = module.cloud_init_database.network_config
}

resource "libvirt_cloudinit_disk" "core" {
  name           = "core-cloudinit.iso"
  pool           = var.storage_pool
  user_data      = module.cloud_init_core.user_data
  network_config = module.cloud_init_core.network_config
}

resource "libvirt_cloudinit_disk" "kafka" {
  name           = "kafka-cloudinit.iso"
  pool           = var.storage_pool
  user_data      = module.cloud_init_kafka.user_data
  network_config = module.cloud_init_kafka.network_config
}

resource "libvirt_cloudinit_disk" "minion" {
  name           = "minion-cloudinit.iso"
  pool           = var.storage_pool
  user_data      = module.cloud_init_minion.user_data
  network_config = module.cloud_init_minion.network_config
}

resource "libvirt_cloudinit_disk" "snmpsim" {
  name           = "snmpsim-cloudinit.iso"
  pool           = var.storage_pool
  user_data      = module.cloud_init_snmpsim.user_data
  network_config = module.cloud_init_snmpsim.network_config
}

resource "libvirt_cloudinit_disk" "monitoring" {
  name           = "monitoring-cloudinit.iso"
  pool           = var.storage_pool
  user_data      = module.cloud_init_monitoring.user_data
  network_config = module.cloud_init_monitoring.network_config
}

# VMs (libvirt domains)
resource "libvirt_domain" "database" {
  name    = "database"
  memory  = 4096
  vcpu    = 2
  cloudinit = libvirt_cloudinit_disk.database.id

  disk { volume_id = libvirt_volume.database.id }

  network_interface { network_id = var.network_mgmt_id }
  network_interface { network_id = var.network_db_id }
}

resource "libvirt_domain" "core" {
  name    = "core"
  memory  = 16384
  vcpu    = 4
  cloudinit = libvirt_cloudinit_disk.core.id

  disk { volume_id = libvirt_volume.core.id }

  network_interface { network_id = var.network_mgmt_id }
  network_interface { network_id = var.network_db_id }
  network_interface { network_id = var.network_kafka_id }
}

resource "libvirt_domain" "kafka" {
  name    = "kafka"
  memory  = 4096
  vcpu    = 2
  cloudinit = libvirt_cloudinit_disk.kafka.id

  disk { volume_id = libvirt_volume.kafka.id }

  network_interface { network_id = var.network_mgmt_id }
  network_interface { network_id = var.network_kafka_id }
}

resource "libvirt_domain" "minion" {
  name    = "minion"
  memory  = 4096
  vcpu    = 2
  cloudinit = libvirt_cloudinit_disk.minion.id

  disk { volume_id = libvirt_volume.minion.id }

  network_interface { network_id = var.network_mgmt_id }
  network_interface { network_id = var.network_kafka_id }
  network_interface { network_id = var.network_sim_id }
}

resource "libvirt_domain" "snmpsim" {
  name    = "snmpsim"
  memory  = 4096
  vcpu    = 2
  cloudinit = libvirt_cloudinit_disk.snmpsim.id

  disk { volume_id = libvirt_volume.snmpsim.id }

  network_interface { network_id = var.network_mgmt_id }
  network_interface { network_id = var.network_sim_id }
}

resource "libvirt_domain" "monitoring" {
  name    = "mon"
  memory  = 4096
  vcpu    = 2
  cloudinit = libvirt_cloudinit_disk.monitoring.id

  disk { volume_id = libvirt_volume.monitoring.id }

  network_interface { network_id = var.network_mgmt_id }
}
