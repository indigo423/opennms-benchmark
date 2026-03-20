resource "local_file" "ansible_inventory" {
  filename = "${path.root}/../../ansible-inventory.yml"
  content  = templatefile("${path.module}/templates/inventory.yml.tftpl", {
    ip_database   = var.ip_database
    ip_core       = var.ip_core
    ip_kafka      = var.ip_kafka
    ip_minion     = var.ip_minion
    ip_snmpsim    = var.ip_snmpsim
    ip_monitoring = var.ip_monitoring
    admin_user    = var.admin_user
    ssh_key_path  = var.ssh_key_path
  })
}
