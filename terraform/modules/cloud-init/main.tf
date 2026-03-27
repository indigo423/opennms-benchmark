locals {
  # Flatten all per-interface static routes so user-data can install them via
  # a systemd service. This is needed on Azure, which only accepts custom_data
  # (user-data) and ignores the separate network-config document used by KVM.
  static_routes = flatten([
    for iface in var.interfaces : iface.routes
  ])

  network_config = templatefile("${path.module}/templates/network-config.yaml.tftpl", {
    interfaces = var.interfaces
  })

  user_data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    vm_name        = var.vm_name
    admin_user     = var.admin_user
    ssh_public_key = var.ssh_public_key
    hosts          = var.hosts
    extra_packages = var.extra_packages
    local_routes   = var.local_routes
    static_routes  = var.network_config_supported ? [] : local.static_routes
  })
}
