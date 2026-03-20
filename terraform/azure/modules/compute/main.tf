locals {
  # Ubuntu 24.04 LTS — Azure marketplace cloud image (cloud-init pre-installed)
  # Do not change to a non-cloud image variant
  image = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

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
  # SNMP simulation route — only the Minion needs to reach 10.42.0.0/16
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

resource "azurerm_linux_virtual_machine" "database" {
  name                  = "database"
  resource_group_name   = var.resource_group
  location              = var.location
  size                  = var.vm_size_small
  priority              = var.priority
  proximity_placement_group_id = var.ppg_id
  admin_username        = var.admin_user
  network_interface_ids = [var.nic_database_mgmt, var.nic_database_db]
  custom_data           = module.cloud_init_database.user_data_base64

  admin_ssh_key {
    username   = var.admin_user
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = local.image.publisher
    offer     = local.image.offer
    sku       = local.image.sku
    version   = local.image.version
  }
}

resource "azurerm_linux_virtual_machine" "core" {
  name                  = "core"
  resource_group_name   = var.resource_group
  location              = var.location
  size                  = var.vm_size_medium
  priority              = var.priority
  proximity_placement_group_id = var.ppg_id
  admin_username        = var.admin_user
  network_interface_ids = [var.nic_core_mgmt, var.nic_core_db, var.nic_core_kafka]
  custom_data           = module.cloud_init_core.user_data_base64

  admin_ssh_key {
    username   = var.admin_user
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = local.image.publisher
    offer     = local.image.offer
    sku       = local.image.sku
    version   = local.image.version
  }
}

resource "azurerm_linux_virtual_machine" "kafka" {
  name                  = "kafka"
  resource_group_name   = var.resource_group
  location              = var.location
  size                  = var.vm_size_small
  priority              = var.priority
  proximity_placement_group_id = var.ppg_id
  admin_username        = var.admin_user
  network_interface_ids = [var.nic_kafka_mgmt, var.nic_kafka_kafka]
  custom_data           = module.cloud_init_kafka.user_data_base64

  admin_ssh_key {
    username   = var.admin_user
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = local.image.publisher
    offer     = local.image.offer
    sku       = local.image.sku
    version   = local.image.version
  }
}

resource "azurerm_linux_virtual_machine" "minion" {
  name                  = "minion"
  resource_group_name   = var.resource_group
  location              = var.location
  size                  = var.vm_size_small
  priority              = var.priority
  proximity_placement_group_id = var.ppg_id
  admin_username        = var.admin_user
  network_interface_ids = [var.nic_minion_mgmt, var.nic_minion_kafka, var.nic_minion_sim]
  custom_data           = module.cloud_init_minion.user_data_base64

  admin_ssh_key {
    username   = var.admin_user
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = local.image.publisher
    offer     = local.image.offer
    sku       = local.image.sku
    version   = local.image.version
  }
}

resource "azurerm_linux_virtual_machine" "snmpsim" {
  name                  = "snmpsim"
  resource_group_name   = var.resource_group
  location              = var.location
  size                  = var.vm_size_small
  priority              = var.priority
  proximity_placement_group_id = var.ppg_id
  admin_username        = var.admin_user
  network_interface_ids = [var.nic_snmpsim_mgmt, var.nic_snmpsim_sim]
  custom_data           = module.cloud_init_snmpsim.user_data_base64

  admin_ssh_key {
    username   = var.admin_user
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = local.image.publisher
    offer     = local.image.offer
    sku       = local.image.sku
    version   = local.image.version
  }
}

resource "azurerm_linux_virtual_machine" "monitoring" {
  name                  = "mon"
  resource_group_name   = var.resource_group
  location              = var.location
  size                  = var.vm_size_small
  priority              = var.priority
  proximity_placement_group_id = var.ppg_id
  admin_username        = var.admin_user
  network_interface_ids = [var.nic_monitoring_mgmt]
  custom_data           = module.cloud_init_monitoring.user_data_base64

  admin_ssh_key {
    username   = var.admin_user
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = local.image.publisher
    offer     = local.image.offer
    sku       = local.image.sku
    version   = local.image.version
  }
}
