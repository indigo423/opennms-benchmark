terraform {
  required_version = ">= 1.5"
  required_providers {
    vsphere = {
      source  = "hashicorp/vsphere"
      version = "~> 2.10"
    }
  }
}

# Cloud-init configuration — rendered via the shared module (same templates as KVM and Proxmox).
# Interface names inside VMware VMs with VMXNET3 adapters (Ubuntu 24.04):
#   ens160 = first NIC  (PCI 0:7.0)
#   ens192 = second NIC (PCI 0:8.0)
#   ens224 = third NIC  (PCI 0:9.0)
#   ens256 = fourth NIC (PCI 0:10.0)
# Verify on your setup: ssh ubuntu@<ip> ip link
#
# Cloud-init is delivered via VMware guestinfo properties read by open-vm-tools at
# boot — no ISO or snippets file needed. The template VM must have open-vm-tools and
# cloud-init installed.

module "cloud_init_elasticsearch" {
  source         = "../../../../modules/cloud-init"
  vm_name        = "es-benchmark-01"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  interfaces = [
    { name = "ens160", address = var.ip_elasticsearch, prefix = 26, gateway = var.gateway_mgmt },
    { name = "ens192", address = var.ip_es_core, prefix = 26, gateway = null },
  ]
}

module "cloud_init_database" {
  source         = "../../../../modules/cloud-init"
  vm_name        = "db-benchmark-01"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  interfaces = [
    { name = "ens160", address = var.ip_database, prefix = 26, gateway = var.gateway_mgmt },
    { name = "ens192", address = var.ip_database_db, prefix = 26, gateway = null },
  ]
}

module "cloud_init_core" {
  source         = "../../../../modules/cloud-init"
  vm_name        = "core-benchmark-01"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  interfaces = [
    { name = "ens160", address = var.ip_core, prefix = 26, gateway = var.gateway_mgmt },
    { name = "ens192", address = var.ip_core_db, prefix = 26, gateway = null },
    { name = "ens224", address = var.ip_core_kafka, prefix = 26, gateway = null },
  ]
}

module "cloud_init_kafka" {
  source         = "../../../../modules/cloud-init"
  vm_name        = "kafka-benchmark-01"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  interfaces = [
    { name = "ens160", address = var.ip_kafka, prefix = 26, gateway = var.gateway_mgmt },
    { name = "ens192", address = var.ip_kafka_kafka, prefix = 26, gateway = null },
  ]
}

module "cloud_init_minion" {
  source         = "../../../../modules/cloud-init"
  vm_name        = "minion-benchmark-01"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  interfaces = [
    { name = "ens160", address = var.ip_minion, prefix = 26, gateway = var.gateway_mgmt },
    { name = "ens192", address = var.ip_minion_kafka, prefix = 26, gateway = null },
    { name = "ens224", address = var.ip_minion_sim, prefix = 26, gateway = null, routes = [{ to = var.net_sim_cidr, via = var.net_sim_gateway }] },
  ]
}

module "cloud_init_netsim" {
  source         = "../../../../modules/cloud-init"
  vm_name        = "netsim-benchmark-01"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  interfaces = [
    { name = "ens160", address = var.ip_netsim, prefix = 26, gateway = var.gateway_mgmt },
    { name = "ens192", address = var.ip_netsim_sim, prefix = 26, gateway = null },
  ]
}

module "cloud_init_monitoring" {
  source         = "../../../../modules/cloud-init"
  vm_name        = "mon-benchmark-01"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  interfaces = [
    { name = "ens160", address = var.ip_monitoring, prefix = 26, gateway = null },
    { name = "ens192", address = null, prefix = null, gateway = null },
  ]
}

# vSphere data sources — resolved at plan time from the provider.

data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

data "vsphere_datastore" "ds" {
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_compute_cluster" "cluster" {
  name          = var.cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "template" {
  name          = var.template_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "mgmt" {
  name          = var.pg_mgmt
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "db" {
  name          = var.pg_db
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "kafka" {
  name          = var.pg_kafka
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "sim" {
  name          = var.pg_sim
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "ext" {
  name          = var.pg_ext
  datacenter_id = data.vsphere_datacenter.dc.id
}

# VMs — full clones of the Ubuntu 24.04 cloud-init template.
# Cloud-init payload is delivered via VMware guestinfo properties.
# open-vm-tools reads guestinfo.userdata and guestinfo.metadata at boot and
# hands them to cloud-init, which configures users, SSH keys, /etc/hosts,
# and network interfaces (via Netplan).
#
# Creation order: database → core → kafka → minion → netsim → monitoring → elasticsearch

resource "vsphere_virtual_machine" "database" {
  name             = "db-benchmark-01"
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.ds.id
  num_cpus         = 2
  memory           = 4096
  guest_id         = data.vsphere_virtual_machine.template.guest_id
  firmware         = data.vsphere_virtual_machine.template.firmware
  annotation       = "opennms-benchmark"

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
  }

  disk {
    label            = "disk0"
    size             = var.disk_sizes_gb["database"]
    thin_provisioned = true
  }

  network_interface {
    network_id   = data.vsphere_network.mgmt.id
    adapter_type = "vmxnet3"
  }

  network_interface {
    network_id   = data.vsphere_network.db.id
    adapter_type = "vmxnet3"
  }

  extra_config = {
    "guestinfo.userdata"          = module.cloud_init_database.user_data_base64
    "guestinfo.userdata.encoding" = "base64"
    "guestinfo.metadata"          = base64encode(module.cloud_init_database.network_config)
    "guestinfo.metadata.encoding" = "base64"
  }
}

resource "vsphere_virtual_machine" "core" {
  name             = "core-benchmark-01"
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.ds.id
  num_cpus         = 4
  memory           = 16384
  guest_id         = data.vsphere_virtual_machine.template.guest_id
  firmware         = data.vsphere_virtual_machine.template.firmware
  annotation       = "opennms-benchmark"

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
  }

  disk {
    label            = "disk0"
    size             = var.disk_sizes_gb["core"]
    thin_provisioned = true
  }

  network_interface {
    network_id   = data.vsphere_network.mgmt.id
    adapter_type = "vmxnet3"
  }

  network_interface {
    network_id   = data.vsphere_network.db.id
    adapter_type = "vmxnet3"
  }

  network_interface {
    network_id   = data.vsphere_network.kafka.id
    adapter_type = "vmxnet3"
  }

  extra_config = {
    "guestinfo.userdata"          = module.cloud_init_core.user_data_base64
    "guestinfo.userdata.encoding" = "base64"
    "guestinfo.metadata"          = base64encode(module.cloud_init_core.network_config)
    "guestinfo.metadata.encoding" = "base64"
  }

  depends_on = [vsphere_virtual_machine.database]
}

resource "vsphere_virtual_machine" "kafka" {
  name             = "kafka-benchmark-01"
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.ds.id
  num_cpus         = 2
  memory           = 4096
  guest_id         = data.vsphere_virtual_machine.template.guest_id
  firmware         = data.vsphere_virtual_machine.template.firmware
  annotation       = "opennms-benchmark"

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
  }

  disk {
    label            = "disk0"
    size             = var.disk_sizes_gb["kafka"]
    thin_provisioned = true
  }

  network_interface {
    network_id   = data.vsphere_network.mgmt.id
    adapter_type = "vmxnet3"
  }

  network_interface {
    network_id   = data.vsphere_network.kafka.id
    adapter_type = "vmxnet3"
  }

  extra_config = {
    "guestinfo.userdata"          = module.cloud_init_kafka.user_data_base64
    "guestinfo.userdata.encoding" = "base64"
    "guestinfo.metadata"          = base64encode(module.cloud_init_kafka.network_config)
    "guestinfo.metadata.encoding" = "base64"
  }

  depends_on = [vsphere_virtual_machine.core]
}

resource "vsphere_virtual_machine" "minion" {
  name             = "minion-benchmark-01"
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.ds.id
  num_cpus         = 2
  memory           = 4096
  guest_id         = data.vsphere_virtual_machine.template.guest_id
  firmware         = data.vsphere_virtual_machine.template.firmware
  annotation       = "opennms-benchmark"

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
  }

  disk {
    label            = "disk0"
    size             = var.disk_sizes_gb["minion"]
    thin_provisioned = true
  }

  network_interface {
    network_id   = data.vsphere_network.mgmt.id
    adapter_type = "vmxnet3"
  }

  network_interface {
    network_id   = data.vsphere_network.kafka.id
    adapter_type = "vmxnet3"
  }

  network_interface {
    network_id   = data.vsphere_network.sim.id
    adapter_type = "vmxnet3"
  }

  extra_config = {
    "guestinfo.userdata"          = module.cloud_init_minion.user_data_base64
    "guestinfo.userdata.encoding" = "base64"
    "guestinfo.metadata"          = base64encode(module.cloud_init_minion.network_config)
    "guestinfo.metadata.encoding" = "base64"
  }

  depends_on = [vsphere_virtual_machine.kafka]
}

resource "vsphere_virtual_machine" "netsim" {
  name             = "netsim-benchmark-01"
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.ds.id
  num_cpus         = 2
  memory           = 4096
  guest_id         = data.vsphere_virtual_machine.template.guest_id
  firmware         = data.vsphere_virtual_machine.template.firmware
  annotation       = "opennms-benchmark"

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
  }

  disk {
    label            = "disk0"
    size             = var.disk_sizes_gb["netsim"]
    thin_provisioned = true
  }

  network_interface {
    network_id   = data.vsphere_network.mgmt.id
    adapter_type = "vmxnet3"
  }

  network_interface {
    network_id   = data.vsphere_network.sim.id
    adapter_type = "vmxnet3"
  }

  extra_config = {
    "guestinfo.userdata"          = module.cloud_init_netsim.user_data_base64
    "guestinfo.userdata.encoding" = "base64"
    "guestinfo.metadata"          = base64encode(module.cloud_init_netsim.network_config)
    "guestinfo.metadata.encoding" = "base64"
  }

  depends_on = [vsphere_virtual_machine.minion]
}

resource "vsphere_virtual_machine" "monitoring" {
  name             = "mon-benchmark-01"
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.ds.id
  num_cpus         = 2
  memory           = 4096
  guest_id         = data.vsphere_virtual_machine.template.guest_id
  firmware         = data.vsphere_virtual_machine.template.firmware
  annotation       = "opennms-benchmark"

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
  }

  disk {
    label            = "disk0"
    size             = var.disk_sizes_gb["monitoring"]
    thin_provisioned = true
  }

  network_interface {
    network_id   = data.vsphere_network.mgmt.id
    adapter_type = "vmxnet3"
  }

  # External NIC — DHCP-assigned routable address, used as the SSH jump host.
  network_interface {
    network_id   = data.vsphere_network.ext.id
    adapter_type = "vmxnet3"
  }

  extra_config = {
    "guestinfo.userdata"          = module.cloud_init_monitoring.user_data_base64
    "guestinfo.userdata.encoding" = "base64"
    "guestinfo.metadata"          = base64encode(module.cloud_init_monitoring.network_config)
    "guestinfo.metadata.encoding" = "base64"
  }

  depends_on = [vsphere_virtual_machine.netsim]
}

resource "vsphere_virtual_machine" "elasticsearch" {
  name             = "es-benchmark-01"
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.ds.id
  num_cpus         = 4
  memory           = 8192
  guest_id         = data.vsphere_virtual_machine.template.guest_id
  firmware         = data.vsphere_virtual_machine.template.firmware
  annotation       = "opennms-benchmark"

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
  }

  disk {
    label            = "disk0"
    size             = var.disk_sizes_gb["elasticsearch"]
    thin_provisioned = true
  }

  network_interface {
    network_id   = data.vsphere_network.mgmt.id
    adapter_type = "vmxnet3"
  }

  network_interface {
    network_id   = data.vsphere_network.db.id
    adapter_type = "vmxnet3"
  }

  extra_config = {
    "guestinfo.userdata"          = module.cloud_init_elasticsearch.user_data_base64
    "guestinfo.userdata.encoding" = "base64"
    "guestinfo.metadata"          = base64encode(module.cloud_init_elasticsearch.network_config)
    "guestinfo.metadata.encoding" = "base64"
  }

  depends_on = [vsphere_virtual_machine.monitoring]
}
