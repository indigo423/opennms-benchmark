locals {
  network_config = templatefile("${path.module}/templates/network-config.yaml.tftpl", {
    interfaces   = var.interfaces
    extra_routes = var.extra_routes
  })

  user_data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    vm_name        = var.vm_name
    admin_user     = var.admin_user
    ssh_public_key = var.ssh_public_key
    hosts          = var.hosts
  })
}
