locals {
  tpl_vars = {
    subnet_mgmt  = var.subnet_mgmt
    subnet_db    = var.subnet_db
    subnet_kafka = var.subnet_kafka
    subnet_sim   = var.subnet_sim
  }
}

resource "local_file" "diagram_drawio" {
  filename = "${path.root}/../../assets/ck1m.drawio"
  content  = templatefile("${path.module}/templates/ck1m.drawio.tftpl", local.tpl_vars)
}

resource "local_file" "diagram_svg" {
  filename = "${path.root}/../../assets/ck1m.svg"
  content  = templatefile("${path.module}/templates/ck1m.svg.tftpl", local.tpl_vars)
}
