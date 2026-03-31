locals {
  resource_group = "rg-${var.environment}-${var.project_name}"
  ppg_name       = "ppg-${var.location}-${var.environment}-${var.project_name}"
  vnet_name      = "vnet-${var.location}-${var.environment}-lab"

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

resource "azurerm_resource_group" "lab" {
  name     = local.resource_group
  location = var.location
}

resource "azurerm_proximity_placement_group" "lab" {
  name                = local.ppg_name
  location            = var.location
  resource_group_name = azurerm_resource_group.lab.name
}

module "network" {
  source = "./modules/network"

  resource_group   = azurerm_resource_group.lab.name
  location         = var.location
  environment      = var.environment
  vnet_name        = local.vnet_name
  lab_cidr         = var.lab_cidr
  subnet_db        = var.subnet_db
  subnet_kafka     = var.subnet_kafka
  subnet_sim       = var.subnet_sim
  subnet_mgmt      = var.subnet_mgmt
  ip_database_db   = var.ip_database_db
  ip_database      = var.ip_database
  ip_core_db       = var.ip_core_db
  ip_core_kafka    = var.ip_core_kafka
  ip_core          = var.ip_core
  ip_kafka_kafka   = var.ip_kafka_kafka
  ip_kafka         = var.ip_kafka
  ip_minion_kafka  = var.ip_minion_kafka
  ip_minion_sim    = var.ip_minion_sim
  ip_minion        = var.ip_minion
  ip_netsim        = var.ip_netsim
  ip_netsim_sim    = var.ip_netsim_sim
  ip_monitoring    = var.ip_monitoring
  operator_cidr    = var.operator_cidr
  ip_elasticsearch = var.ip_elasticsearch
  ip_es_core       = var.ip_es_core
}

module "compute" {
  source = "./modules/compute"

  resource_group         = azurerm_resource_group.lab.name
  location               = var.location
  ppg_id                 = azurerm_proximity_placement_group.lab.id
  vm_size_small          = var.vm_size_small
  vm_size_medium         = var.vm_size_medium
  priority               = var.priority
  admin_user             = var.admin_user
  ssh_public_key         = trimspace(file(pathexpand("${var.ssh_key_path}.pub")))
  net_sim_cidr           = var.net_sim_cidr
  net_sim_gateway        = var.net_sim_gateway
  hosts                  = local.hosts
  ip_database            = var.ip_database
  ip_core                = var.ip_core
  ip_kafka               = var.ip_kafka
  ip_minion              = var.ip_minion
  ip_netsim              = var.ip_netsim
  ip_monitoring          = var.ip_monitoring
  ip_database_db         = var.ip_database_db
  ip_core_db             = var.ip_core_db
  ip_core_kafka          = var.ip_core_kafka
  ip_kafka_kafka         = var.ip_kafka_kafka
  ip_minion_kafka        = var.ip_minion_kafka
  ip_minion_sim          = var.ip_minion_sim
  ip_netsim_sim          = var.ip_netsim_sim
  nic_database_mgmt      = module.network.nic_database_mgmt
  nic_database_db        = module.network.nic_database_db
  nic_core_mgmt          = module.network.nic_core_mgmt
  nic_core_db            = module.network.nic_core_db
  nic_core_kafka         = module.network.nic_core_kafka
  nic_kafka_mgmt         = module.network.nic_kafka_mgmt
  nic_kafka_kafka        = module.network.nic_kafka_kafka
  nic_minion_mgmt        = module.network.nic_minion_mgmt
  nic_minion_kafka       = module.network.nic_minion_kafka
  nic_minion_sim         = module.network.nic_minion_sim
  nic_netsim_mgmt        = module.network.nic_netsim_mgmt
  nic_netsim_sim         = module.network.nic_netsim_sim
  nic_monitoring_mgmt    = module.network.nic_monitoring_mgmt
  ip_elasticsearch       = var.ip_elasticsearch
  ip_es_core             = var.ip_es_core
  nic_elasticsearch_mgmt = module.network.nic_elasticsearch_mgmt
  nic_elasticsearch_db   = module.network.nic_elasticsearch_db
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
  jump_host        = module.network.monitoring_public_ip
}
