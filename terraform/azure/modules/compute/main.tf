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
  # Ubuntu 24.04 LTS — Azure marketplace cloud image (cloud-init pre-installed)
  # Do not change to a non-cloud image variant
  image = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # t-shirt size class -> Azure SKU
  size_map = {
    small  = var.vm_size_small
    medium = var.vm_size_medium
  }
}

module "cloud_init" {
  for_each = var.topology
  source   = "../../../modules/cloud-init"

  vm_name        = each.value.vm_name
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  # Azure delivers only user-data; static routes are installed via a systemd
  # service in user-data rather than a separate network-config document.
  network_config_supported = false
  interfaces = [
    for idx, iface in each.value.interfaces : {
      name    = "eth${idx}"
      address = iface.address
      prefix  = 26
      gateway = null
      routes  = iface.routes
    }
  ]
}

resource "azurerm_linux_virtual_machine" "vm" {
  for_each = var.topology

  name                         = each.value.vm_name
  resource_group_name          = var.resource_group
  location                     = var.location
  size                         = local.size_map[each.value.size]
  priority                     = var.priority
  proximity_placement_group_id = var.ppg_id
  admin_username               = var.admin_user
  network_interface_ids        = [for iface in each.value.interfaces : var.nic_ids["${each.key}-${iface.subnet}"]]
  custom_data                  = module.cloud_init[each.key].user_data_base64

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

# Preserve state addresses across the per-role -> for_each refactor (no destroy).
moved {
  from = azurerm_linux_virtual_machine.database
  to   = azurerm_linux_virtual_machine.vm["database"]
}
moved {
  from = azurerm_linux_virtual_machine.core
  to   = azurerm_linux_virtual_machine.vm["core"]
}
moved {
  from = azurerm_linux_virtual_machine.kafka
  to   = azurerm_linux_virtual_machine.vm["kafka"]
}
moved {
  from = azurerm_linux_virtual_machine.minion
  to   = azurerm_linux_virtual_machine.vm["minion"]
}
moved {
  from = azurerm_linux_virtual_machine.netsim
  to   = azurerm_linux_virtual_machine.vm["netsim"]
}
moved {
  from = azurerm_linux_virtual_machine.monitoring
  to   = azurerm_linux_virtual_machine.vm["monitoring"]
}
moved {
  from = azurerm_linux_virtual_machine.elasticsearch
  to   = azurerm_linux_virtual_machine.vm["elasticsearch"]
}

moved {
  from = module.cloud_init_database
  to   = module.cloud_init["database"]
}
moved {
  from = module.cloud_init_core
  to   = module.cloud_init["core"]
}
moved {
  from = module.cloud_init_kafka
  to   = module.cloud_init["kafka"]
}
moved {
  from = module.cloud_init_minion
  to   = module.cloud_init["minion"]
}
moved {
  from = module.cloud_init_netsim
  to   = module.cloud_init["netsim"]
}
moved {
  from = module.cloud_init_monitoring
  to   = module.cloud_init["monitoring"]
}
moved {
  from = module.cloud_init_elasticsearch
  to   = module.cloud_init["elasticsearch"]
}
