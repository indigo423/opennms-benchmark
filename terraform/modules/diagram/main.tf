locals {
  tpl_vars = {
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

    vm_name_monitoring    = var.vm_names["monitoring"]
    vm_name_database      = var.vm_names["database"]
    vm_name_core          = var.vm_names["core"]
    vm_name_kafka         = var.vm_names["kafka"]
    vm_name_minion        = var.vm_names["minion"]
    vm_name_netsim        = var.vm_names["netsim"]
    vm_name_elasticsearch = var.vm_names["elasticsearch"]
  }
}

resource "local_file" "diagram_drawio" {
  filename = "${path.root}/../../assets/${var.provider_name}/ck1m.drawio"
  content  = templatefile("${path.module}/templates/ck1m.drawio.tftpl", local.tpl_vars)
}

resource "local_file" "diagram_svg" {
  filename = "${path.root}/../../assets/${var.provider_name}/ck1m.svg"
  content  = templatefile("${path.module}/templates/ck1m.svg.tftpl", local.tpl_vars)
}
