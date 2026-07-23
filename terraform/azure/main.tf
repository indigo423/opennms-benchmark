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

  # Topology spec (keyed by role): the deployment-under-test as data. Node count
  # is 1 per role today; interface addresses are the current lab.tfvars values so
  # this refactor is byte-for-byte identical in plan. nic_label reproduces the
  # legacy NIC-name token (monitoring -> "mon", elasticsearch -> "es").
  topology = {
    database = {
      vm_name   = "db-benchmark-01"
      nic_label = "database"
      size      = "small"
      public_ip = false
      interfaces = [
        { subnet = "mgmt", address = var.ip_database, routes = [] },
        { subnet = "db", address = var.ip_database_db, routes = [] },
      ]
    }
    core = {
      vm_name   = "core-benchmark-01"
      nic_label = "core"
      size      = "medium"
      public_ip = false
      interfaces = [
        { subnet = "mgmt", address = var.ip_core, routes = [] },
        { subnet = "db", address = var.ip_core_db, routes = [] },
        { subnet = "kafka", address = var.ip_core_kafka, routes = [] },
      ]
    }
    kafka = {
      vm_name   = "kafka-benchmark-01"
      nic_label = "kafka"
      size      = "small"
      public_ip = false
      interfaces = [
        { subnet = "mgmt", address = var.ip_kafka, routes = [] },
        { subnet = "kafka", address = var.ip_kafka_kafka, routes = [] },
      ]
    }
    minion = {
      vm_name   = "minion-benchmark-01"
      nic_label = "minion"
      size      = "small"
      public_ip = false
      interfaces = [
        { subnet = "mgmt", address = var.ip_minion, routes = [] },
        { subnet = "kafka", address = var.ip_minion_kafka, routes = [] },
        { subnet = "sim", address = var.ip_minion_sim, routes = [{ to = var.net_sim_cidr, via = var.net_sim_gateway }] },
      ]
    }
    netsim = {
      vm_name   = "netsim-benchmark-01"
      nic_label = "netsim"
      size      = "small"
      public_ip = false
      interfaces = [
        { subnet = "mgmt", address = var.ip_netsim, routes = [] },
        { subnet = "sim", address = var.ip_netsim_sim, routes = [] },
      ]
    }
    monitoring = {
      vm_name   = "mon-benchmark-01"
      nic_label = "mon"
      size      = "small"
      public_ip = true
      interfaces = [
        { subnet = "mgmt", address = var.ip_monitoring, routes = [] },
      ]
    }
    elasticsearch = {
      vm_name   = "es-benchmark-01"
      nic_label = "es"
      size      = "small"
      public_ip = false
      interfaces = [
        { subnet = "mgmt", address = var.ip_elasticsearch, routes = [] },
        { subnet = "db", address = var.ip_es_core, routes = [] },
      ]
    }
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

  resource_group = azurerm_resource_group.lab.name
  location       = var.location
  environment    = var.environment
  vnet_name      = local.vnet_name
  lab_cidr       = var.lab_cidr
  subnet_db      = var.subnet_db
  subnet_kafka   = var.subnet_kafka
  subnet_sim     = var.subnet_sim
  subnet_mgmt    = var.subnet_mgmt
  operator_cidr  = var.operator_cidr
  topology       = local.topology
}

module "compute" {
  source = "./modules/compute"

  resource_group = azurerm_resource_group.lab.name
  location       = var.location
  ppg_id         = azurerm_proximity_placement_group.lab.id
  vm_size_small  = var.vm_size_small
  vm_size_medium = var.vm_size_medium
  priority       = var.priority
  admin_user     = var.admin_user
  ssh_public_key = trimspace(file(pathexpand("${var.ssh_key_path}.pub")))
  hosts          = local.hosts
  nic_ids        = module.network.nic_ids
  topology       = local.topology
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

  ip_database          = var.ip_database
  ip_core              = var.ip_core
  ip_kafka             = var.ip_kafka
  ip_minion            = var.ip_minion
  ip_netsim            = var.ip_netsim
  ip_monitoring        = var.ip_monitoring
  ip_elasticsearch     = var.ip_elasticsearch
  admin_user           = var.admin_user
  ssh_key_path         = var.ssh_key_path
  jump_host            = module.network.monitoring_public_ip
  netsim_sim_interface = "eth1"
}
