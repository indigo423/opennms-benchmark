locals {
  hosts = {
    "db-benchmark-01"     = var.ip_database
    "core-benchmark-01"   = var.ip_core
    "kafka-benchmark-01"  = var.ip_kafka
    "minion-benchmark-01" = var.ip_minion
    "netsim-benchmark-01" = var.ip_netsim
    "mon-benchmark-01"    = var.ip_monitoring
    "es-benchmark-01"     = var.ip_elasticsearch
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
  net_sim_cidr        = var.net_sim_cidr
  net_sim_gateway     = var.net_sim_gateway
  hosts               = local.hosts
  ip_database         = var.ip_database
  ip_core             = var.ip_core
  ip_kafka            = var.ip_kafka
  ip_minion           = var.ip_minion
  ip_netsim           = var.ip_netsim
  ip_monitoring       = var.ip_monitoring
  ip_database_db      = var.ip_database_db
  ip_core_db          = var.ip_core_db
  ip_core_kafka       = var.ip_core_kafka
  ip_kafka_kafka      = var.ip_kafka_kafka
  ip_minion_kafka     = var.ip_minion_kafka
  ip_minion_sim       = var.ip_minion_sim
  ip_netsim_sim       = var.ip_netsim_sim
  ip_elasticsearch    = var.ip_elasticsearch
  ip_es_core          = var.ip_es_core
  network_db_id       = module.network.network_db_id
  network_kafka_id    = module.network.network_kafka_id
  network_sim_id      = module.network.network_sim_id
  network_mgmt_id     = module.network.network_mgmt_id
  network_external_id = module.network.network_external_id
  gateway_mgmt        = cidrhost(var.subnet_mgmt, 1)
}

module "diagram" {
  source = "../modules/diagram"

  subnet_mgmt  = var.subnet_mgmt
  subnet_db    = var.subnet_db
  subnet_kafka = var.subnet_kafka
  subnet_sim   = var.subnet_sim

  ip_monitoring    = var.ip_monitoring
  ip_database      = var.ip_database
  ip_core          = var.ip_core
  ip_kafka         = var.ip_kafka
  ip_minion        = var.ip_minion
  ip_netsim        = var.ip_netsim
  ip_elasticsearch = var.ip_elasticsearch

  ip_database_db  = var.ip_database_db
  ip_core_db      = var.ip_core_db
  ip_es_core      = var.ip_es_core
  ip_kafka_kafka  = var.ip_kafka_kafka
  ip_core_kafka   = var.ip_core_kafka
  ip_minion_kafka = var.ip_minion_kafka
  ip_minion_sim   = var.ip_minion_sim
  ip_netsim_sim   = var.ip_netsim_sim

  vm_names = var.vm_names
}

module "inventory" {
  source = "../modules/inventory"

  ip_database      = var.ip_database
  ip_core          = var.ip_core
  ip_kafka         = var.ip_kafka
  ip_minion        = var.ip_minion
  ip_netsim        = var.ip_netsim
  ip_monitoring    = var.ip_monitoring
  ip_elasticsearch = var.ip_elasticsearch
  admin_user       = var.admin_user
  ssh_key_path     = var.ssh_key_path
  jump_host        = var.jump_host
}
