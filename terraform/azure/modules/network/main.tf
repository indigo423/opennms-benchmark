terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

locals {
  env = var.environment
  loc = var.location

  subnet_ids = {
    db    = azurerm_subnet.db.id
    kafka = azurerm_subnet.kafka.id
    sim   = azurerm_subnet.sim.id
    mgmt  = azurerm_subnet.mgmt.id
  }

  # Flatten role x interface into one NIC map keyed "<role>-<subnet>". Only the
  # mgmt NIC of a public_ip role gets the monitoring public IP.
  nics = merge([
    for role, node in var.topology : {
      for iface in node.interfaces :
      "${role}-${iface.subnet}" => {
        nic_label = node.nic_label
        subnet    = iface.subnet
        address   = iface.address
        public_ip = node.public_ip && iface.subnet == "mgmt"
      }
    }
  ]...)
}

# Public IP for monitoring jump host
resource "azurerm_public_ip" "monitoring" {
  name                = "net-${local.loc}-${local.env}-mon-publicip"
  resource_group_name = var.resource_group
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# VNet with initial subnet (db)
resource "azurerm_virtual_network" "lab" {
  name                = var.vnet_name
  resource_group_name = var.resource_group
  location            = var.location
  address_space       = [var.lab_cidr]
}

resource "azurerm_subnet" "db" {
  name                 = "subnet-db"
  resource_group_name  = var.resource_group
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_db]
}

resource "azurerm_subnet" "kafka" {
  name                 = "subnet-kafka"
  resource_group_name  = var.resource_group
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_kafka]
}

resource "azurerm_subnet" "sim" {
  name                 = "subnet-sim"
  resource_group_name  = var.resource_group
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_sim]
}

resource "azurerm_subnet" "mgmt" {
  name                 = "subnet-mgmt"
  resource_group_name  = var.resource_group
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_mgmt]
}

# NSG — SSH/HTTPS from operator IP only, on the monitoring NIC
resource "azurerm_network_security_group" "monitoring" {
  name                = "nsg-nic-${local.loc}-${local.env}-mon-vnet-mgmt"
  resource_group_name = var.resource_group
  location            = var.location

  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.operator_cidr != "" ? var.operator_cidr : "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-https"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.operator_cidr != "" ? var.operator_cidr : "*"
    destination_address_prefix = "*"
  }
}

# NICs — one per role x interface (see local.nics). Names reproduce the previous
# hand-written scheme "nic-<loc>-<env>-<nic_label>-vnet-<subnet>" exactly.
resource "azurerm_network_interface" "nic" {
  for_each = local.nics

  name                = "nic-${local.loc}-${local.env}-${each.value.nic_label}-vnet-${each.value.subnet}"
  resource_group_name = var.resource_group
  location            = var.location

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = local.subnet_ids[each.value.subnet]
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.address
    public_ip_address_id          = each.value.public_ip ? azurerm_public_ip.monitoring.id : null
  }
}

resource "azurerm_network_interface_security_group_association" "monitoring" {
  network_interface_id      = azurerm_network_interface.nic["monitoring-mgmt"].id
  network_security_group_id = azurerm_network_security_group.monitoring.id
}

# Preserve state addresses across the count=1 -> for_each refactor (no destroy).
moved {
  from = azurerm_network_interface.database_mgmt
  to   = azurerm_network_interface.nic["database-mgmt"]
}
moved {
  from = azurerm_network_interface.database_db
  to   = azurerm_network_interface.nic["database-db"]
}
moved {
  from = azurerm_network_interface.core_mgmt
  to   = azurerm_network_interface.nic["core-mgmt"]
}
moved {
  from = azurerm_network_interface.core_db
  to   = azurerm_network_interface.nic["core-db"]
}
moved {
  from = azurerm_network_interface.core_kafka
  to   = azurerm_network_interface.nic["core-kafka"]
}
moved {
  from = azurerm_network_interface.kafka_mgmt
  to   = azurerm_network_interface.nic["kafka-mgmt"]
}
moved {
  from = azurerm_network_interface.kafka_kafka
  to   = azurerm_network_interface.nic["kafka-kafka"]
}
moved {
  from = azurerm_network_interface.minion_mgmt
  to   = azurerm_network_interface.nic["minion-mgmt"]
}
moved {
  from = azurerm_network_interface.minion_kafka
  to   = azurerm_network_interface.nic["minion-kafka"]
}
moved {
  from = azurerm_network_interface.minion_sim
  to   = azurerm_network_interface.nic["minion-sim"]
}
moved {
  from = azurerm_network_interface.netsim_mgmt
  to   = azurerm_network_interface.nic["netsim-mgmt"]
}
moved {
  from = azurerm_network_interface.netsim_sim
  to   = azurerm_network_interface.nic["netsim-sim"]
}
moved {
  from = azurerm_network_interface.monitoring_mgmt
  to   = azurerm_network_interface.nic["monitoring-mgmt"]
}
moved {
  from = azurerm_network_interface.elasticsearch_mgmt
  to   = azurerm_network_interface.nic["elasticsearch-mgmt"]
}
moved {
  from = azurerm_network_interface.elasticsearch_db
  to   = azurerm_network_interface.nic["elasticsearch-db"]
}
