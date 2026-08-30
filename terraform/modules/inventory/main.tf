# One inventory per provider root, so two labs deployed from one checkout never
# overwrite each other's Ansible inputs (#277). The provider is the root
# directory's name (terraform/<provider>/), taken from the filesystem rather
# than a variable so no root has to say what it already is. Renamed from
# ansible_inventory so the `removed` block in each root can drop the old
# address from state without deleting the file a running lab still reads.
resource "local_file" "inventory" {
  filename = "${path.root}/../../ansible-inventory.${basename(abspath(path.root))}.yml"
  content = templatefile("${path.module}/templates/inventory.yml.tftpl", {
    ip_database          = var.ip_database
    ip_core              = var.ip_core
    ip_kafka             = var.ip_kafka
    ip_minion            = var.ip_minion
    ip_netsim            = var.ip_netsim
    ip_monitoring        = var.ip_monitoring
    ip_elasticsearch     = var.ip_elasticsearch
    admin_user           = var.admin_user
    ssh_key_path         = var.ssh_key_path
    jump_host            = var.jump_host
    netsim_sim_interface = var.netsim_sim_interface
  })
}
