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

# NSG — SSH from operator IP only on monitoring NIC
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
    source_address_prefix      = var.operator_cidr
    destination_address_prefix = "*"
  }
}

# NICs — database
resource "azurerm_network_interface" "database_db" {
  name                = "nic-${local.loc}-${local.env}-database-vnet-db"
  resource_group_name = var.resource_group
  location            = var.location
  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.db.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.ip_database_db
  }
}

resource "azurerm_network_interface" "database_mgmt" {
  name                = "nic-${local.loc}-${local.env}-database-vnet-mgmt"
  resource_group_name = var.resource_group
  location            = var.location
  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.mgmt.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.ip_database
  }
}

# NICs — core
resource "azurerm_network_interface" "core_db" {
  name                = "nic-${local.loc}-${local.env}-core-vnet-db"
  resource_group_name = var.resource_group
  location            = var.location
  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.db.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.ip_core_db
  }
}

resource "azurerm_network_interface" "core_kafka" {
  name                = "nic-${local.loc}-${local.env}-core-vnet-kafka"
  resource_group_name = var.resource_group
  location            = var.location
  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.kafka.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.ip_core_kafka
  }
}

resource "azurerm_network_interface" "core_mgmt" {
  name                = "nic-${local.loc}-${local.env}-core-vnet-mgmt"
  resource_group_name = var.resource_group
  location            = var.location
  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.mgmt.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.ip_core
  }
}

# NICs — kafka
resource "azurerm_network_interface" "kafka_kafka" {
  name                = "nic-${local.loc}-${local.env}-kafka-vnet-kafka"
  resource_group_name = var.resource_group
  location            = var.location
  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.kafka.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.ip_kafka_kafka
  }
}

resource "azurerm_network_interface" "kafka_mgmt" {
  name                = "nic-${local.loc}-${local.env}-kafka-vnet-mgmt"
  resource_group_name = var.resource_group
  location            = var.location
  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.mgmt.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.ip_kafka
  }
}

# NICs — minion
resource "azurerm_network_interface" "minion_kafka" {
  name                = "nic-${local.loc}-${local.env}-minion-vnet-kafka"
  resource_group_name = var.resource_group
  location            = var.location
  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.kafka.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.ip_minion_kafka
  }
}

resource "azurerm_network_interface" "minion_sim" {
  name                = "nic-${local.loc}-${local.env}-minion-vnet-sim"
  resource_group_name = var.resource_group
  location            = var.location
  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.sim.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.ip_minion_sim
  }
}

resource "azurerm_network_interface" "minion_mgmt" {
  name                = "nic-${local.loc}-${local.env}-minion-vnet-mgmt"
  resource_group_name = var.resource_group
  location            = var.location
  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.mgmt.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.ip_minion
  }
}

# NICs — snmpsim
resource "azurerm_network_interface" "snmpsim_sim" {
  name                = "nic-${local.loc}-${local.env}-snmpsim-vnet-sim"
  resource_group_name = var.resource_group
  location            = var.location
  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.sim.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.ip_snmpsim
  }
}

resource "azurerm_network_interface" "snmpsim_mgmt" {
  name                = "nic-${local.loc}-${local.env}-snmpsim-vnet-mgmt"
  resource_group_name = var.resource_group
  location            = var.location
  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.mgmt.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.ip_snmpsim
  }
}

# NICs — monitoring (jump host, gets public IP)
resource "azurerm_network_interface" "monitoring_mgmt" {
  name                = "nic-${local.loc}-${local.env}-mon-vnet-mgmt"
  resource_group_name = var.resource_group
  location            = var.location
  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.mgmt.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.ip_monitoring
    public_ip_address_id          = azurerm_public_ip.monitoring.id
  }
}

resource "azurerm_network_interface_security_group_association" "monitoring" {
  network_interface_id      = azurerm_network_interface.monitoring_mgmt.id
  network_security_group_id = azurerm_network_security_group.monitoring.id
}
