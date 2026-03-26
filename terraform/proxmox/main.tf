locals {
  hosts = {
    "db-benchmark-01"     = var.ip_database
    "core-benchmark-01"   = var.ip_core
    "kafka-benchmark-01"  = var.ip_kafka
    "minion-benchmark-01" = var.ip_minion
    "netsim-benchmark-01" = var.ip_netsim
    "mon-benchmark-01"    = var.ip_monitoring
  }
}

module "compute" {
  source = "./modules/compute"

  proxmox_node       = var.proxmox_node
  template_vm_id     = var.template_vm_id
  storage_pool       = var.storage_pool
  snippets_datastore = var.snippets_datastore
  admin_user         = var.admin_user
  ssh_public_key     = trimspace(file(pathexpand("${var.ssh_key_path}.pub")))
  snmp_sim_cidr      = var.snmp_sim_cidr
  snmp_sim_gateway   = var.snmp_sim_gateway
  hosts              = local.hosts
  ip_database        = var.ip_database
  ip_core            = var.ip_core
  ip_kafka           = var.ip_kafka
  ip_minion          = var.ip_minion
  ip_netsim          = var.ip_netsim
  ip_monitoring      = var.ip_monitoring
  ip_database_db     = var.ip_database_db
  ip_core_db         = var.ip_core_db
  ip_core_kafka      = var.ip_core_kafka
  ip_kafka_kafka     = var.ip_kafka_kafka
  ip_minion_kafka    = var.ip_minion_kafka
  ip_minion_sim      = var.ip_minion_sim
  ip_netsim_sim      = var.ip_netsim_sim
  bridge_mgmt        = var.bridge_mgmt
  gateway_mgmt       = cidrhost(var.subnet_mgmt, 1)
  bridge_db          = var.bridge_db
  bridge_kafka       = var.bridge_kafka
  bridge_sim         = var.bridge_sim
  bridge_ext         = var.bridge_ext
  vm_ids             = var.vm_ids
  disk_sizes_gb      = var.disk_sizes_gb
}

module "inventory" {
  source = "../modules/inventory"

  ip_database   = var.ip_database
  ip_core       = var.ip_core
  ip_kafka      = var.ip_kafka
  ip_minion     = var.ip_minion
  ip_netsim     = var.ip_netsim
  ip_monitoring = var.ip_monitoring
  admin_user    = var.admin_user
  ssh_key_path  = var.ssh_key_path
  jump_host     = var.jump_host
}
