locals {
  hosts = {
    database   = var.ip_database
    core       = var.ip_core
    kafka      = var.ip_kafka
    minion     = var.ip_minion
    snmpsim    = var.ip_snmpsim
    monitoring = var.ip_monitoring
  }
}

module "network" {
  source = "./modules/network"

  subnet_db    = var.subnet_db
  subnet_kafka = var.subnet_kafka
  subnet_sim   = var.subnet_sim
  subnet_mgmt  = var.subnet_mgmt
  bridge_name  = var.bridge_name
}

module "compute" {
  source = "./modules/compute"

  storage_pool        = var.storage_pool
  ubuntu_cloud_image  = var.ubuntu_cloud_image
  admin_user          = var.admin_user
  ssh_public_key      = trimspace(file(pathexpand("${var.ssh_key_path}.pub")))
  snmp_sim_cidr       = var.snmp_sim_cidr
  snmp_sim_gateway    = var.snmp_sim_gateway
  hosts               = local.hosts
  ip_database         = var.ip_database
  ip_core             = var.ip_core
  ip_kafka            = var.ip_kafka
  ip_minion           = var.ip_minion
  ip_snmpsim          = var.ip_snmpsim
  ip_monitoring       = var.ip_monitoring
  ip_database_db      = var.ip_database_db
  ip_core_db          = var.ip_core_db
  ip_core_kafka       = var.ip_core_kafka
  ip_kafka_kafka      = var.ip_kafka_kafka
  ip_minion_kafka     = var.ip_minion_kafka
  ip_minion_sim       = var.ip_minion_sim
  network_db_id       = module.network.network_db_id
  network_kafka_id    = module.network.network_kafka_id
  network_sim_id      = module.network.network_sim_id
  network_mgmt_id     = module.network.network_mgmt_id
  network_external_id = module.network.network_external_id
  gateway_mgmt        = cidrhost(var.subnet_mgmt, 1)
}

module "inventory" {
  source = "../modules/inventory"

  ip_database   = var.ip_database
  ip_core       = var.ip_core
  ip_kafka      = var.ip_kafka
  ip_minion     = var.ip_minion
  ip_snmpsim    = var.ip_snmpsim
  ip_monitoring = var.ip_monitoring
  admin_user    = var.admin_user
  ssh_key_path  = var.ssh_key_path
  jump_host     = var.jump_host
}
