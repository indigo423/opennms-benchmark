locals {
  resource_group = "rg-${var.environment}-${var.project_name}"
  ppg_name       = "ppg-${var.location}-${var.environment}-${var.project_name}"
  vnet_name      = "vnet-${var.location}-${var.environment}-lab"

  hosts = {
    database   = var.ip_database
    core       = var.ip_core
    kafka      = var.ip_kafka
    minion     = var.ip_minion
    snmpsim    = var.ip_snmpsim
    monitoring = var.ip_monitoring
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

  resource_group  = azurerm_resource_group.lab.name
  location        = var.location
  environment     = var.environment
  vnet_name       = local.vnet_name
  lab_cidr        = var.lab_cidr
  subnet_db       = var.subnet_db
  subnet_kafka    = var.subnet_kafka
  subnet_sim      = var.subnet_sim
  subnet_mgmt     = var.subnet_mgmt
  ip_database_db  = var.ip_database_db
  ip_database     = var.ip_database
  ip_core_db      = var.ip_core_db
  ip_core_kafka   = var.ip_core_kafka
  ip_core         = var.ip_core
  ip_kafka_kafka  = var.ip_kafka_kafka
  ip_kafka        = var.ip_kafka
  ip_minion_kafka = var.ip_minion_kafka
  ip_minion_sim   = var.ip_minion_sim
  ip_minion       = var.ip_minion
  ip_snmpsim      = var.ip_snmpsim
  ip_monitoring   = var.ip_monitoring
  operator_cidr   = var.operator_cidr
}

module "compute" {
  source = "./modules/compute"

  resource_group      = azurerm_resource_group.lab.name
  location            = var.location
  ppg_id              = azurerm_proximity_placement_group.lab.id
  vm_size_small       = var.vm_size_small
  vm_size_medium      = var.vm_size_medium
  priority            = var.priority
  admin_user          = var.admin_user
  ssh_public_key      = var.ssh_public_key
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
  nic_database_mgmt   = module.network.nic_database_mgmt
  nic_database_db     = module.network.nic_database_db
  nic_core_mgmt       = module.network.nic_core_mgmt
  nic_core_db         = module.network.nic_core_db
  nic_core_kafka      = module.network.nic_core_kafka
  nic_kafka_mgmt      = module.network.nic_kafka_mgmt
  nic_kafka_kafka     = module.network.nic_kafka_kafka
  nic_minion_mgmt     = module.network.nic_minion_mgmt
  nic_minion_kafka    = module.network.nic_minion_kafka
  nic_minion_sim      = module.network.nic_minion_sim
  nic_snmpsim_mgmt    = module.network.nic_snmpsim_mgmt
  nic_snmpsim_sim     = module.network.nic_snmpsim_sim
  nic_monitoring_mgmt = module.network.nic_monitoring_mgmt
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
}
