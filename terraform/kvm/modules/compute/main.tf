terraform {
  required_version = ">= 1.5"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9.6"
    }
  }
}

locals {
  cloud_init_meta_data = {
    database   = <<-EOF
      instance-id: database
      local-hostname: database
    EOF
    core       = <<-EOF
      instance-id: core
      local-hostname: core
    EOF
    kafka      = <<-EOF
      instance-id: kafka
      local-hostname: kafka
    EOF
    minion     = <<-EOF
      instance-id: minion
      local-hostname: minion
    EOF
    snmpsim    = <<-EOF
      instance-id: snmpsim
      local-hostname: snmpsim
    EOF
    monitoring = <<-EOF
      instance-id: monitoring
      local-hostname: monitoring
    EOF
  }
}

# Ubuntu 24.04 LTS cloud image — must be the cloud image (qcow2), NOT the server installer ISO.
# Download before running terraform apply:
#   wget -O /var/lib/libvirt/images/noble-server-cloudimg-amd64.img \
#     https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

resource "libvirt_volume" "ubuntu_base" {
  name = "ubuntu-24.04-base"
  pool = var.storage_pool

  target = {
    format = { type = "qcow2" }
  }

  create = {
    content = {
      url = var.ubuntu_cloud_image
    }
  }

  lifecycle {
    precondition {
      condition     = fileexists(var.ubuntu_cloud_image)
      error_message = "Ubuntu 24.04 cloud image not found at '${var.ubuntu_cloud_image}'. Download noble-server-cloudimg-amd64.img from https://cloud-images.ubuntu.com/noble/current/ first."
    }
  }
}

resource "libvirt_volume" "database" {
  name = "database.qcow2"
  pool = var.storage_pool

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = libvirt_volume.ubuntu_base.path
    format = { type = "qcow2" }
  }

  capacity      = var.disk_sizes_gb["database"]
  capacity_unit = "GiB"
}

resource "libvirt_volume" "core" {
  name = "core.qcow2"
  pool = var.storage_pool

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = libvirt_volume.ubuntu_base.path
    format = { type = "qcow2" }
  }

  capacity      = var.disk_sizes_gb["core"]
  capacity_unit = "GiB"
}

resource "libvirt_volume" "kafka" {
  name = "kafka.qcow2"
  pool = var.storage_pool

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = libvirt_volume.ubuntu_base.path
    format = { type = "qcow2" }
  }

  capacity      = var.disk_sizes_gb["kafka"]
  capacity_unit = "GiB"
}

resource "libvirt_volume" "minion" {
  name = "minion.qcow2"
  pool = var.storage_pool

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = libvirt_volume.ubuntu_base.path
    format = { type = "qcow2" }
  }

  capacity      = var.disk_sizes_gb["minion"]
  capacity_unit = "GiB"
}

resource "libvirt_volume" "snmpsim" {
  name = "snmpsim.qcow2"
  pool = var.storage_pool

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = libvirt_volume.ubuntu_base.path
    format = { type = "qcow2" }
  }

  capacity      = var.disk_sizes_gb["snmpsim"]
  capacity_unit = "GiB"
}

resource "libvirt_volume" "monitoring" {
  name = "monitoring.qcow2"
  pool = var.storage_pool

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = libvirt_volume.ubuntu_base.path
    format = { type = "qcow2" }
  }

  capacity      = var.disk_sizes_gb["monitoring"]
  capacity_unit = "GiB"
}

module "cloud_init_database" {
  source         = "../../../modules/cloud-init"
  vm_name        = "database"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = var.extra_packages
  interfaces = [
    { name = "enp1s0", address = var.ip_database, prefix = 26, gateway = null },
    { name = "enp2s0", address = var.ip_database_db, prefix = 26, gateway = null },
    { name = "enp3s0", address = null, prefix = null, gateway = null },
  ]
}

module "cloud_init_core" {
  source         = "../../../modules/cloud-init"
  vm_name        = "core"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = var.extra_packages
  interfaces = [
    { name = "enp1s0", address = var.ip_core, prefix = 26, gateway = null },
    { name = "enp2s0", address = var.ip_core_db, prefix = 26, gateway = null },
    { name = "enp3s0", address = var.ip_core_kafka, prefix = 26, gateway = null },
    { name = "enp4s0", address = null, prefix = null, gateway = null },
  ]
}

module "cloud_init_kafka" {
  source         = "../../../modules/cloud-init"
  vm_name        = "kafka"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = var.extra_packages
  interfaces = [
    { name = "enp1s0", address = var.ip_kafka, prefix = 26, gateway = null },
    { name = "enp2s0", address = var.ip_kafka_kafka, prefix = 26, gateway = null },
    { name = "enp3s0", address = null, prefix = null, gateway = null },
  ]
}

module "cloud_init_minion" {
  source         = "../../../modules/cloud-init"
  vm_name        = "minion"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = var.extra_packages
  interfaces = [
    { name = "enp1s0", address = var.ip_minion, prefix = 26, gateway = null },
    { name = "enp2s0", address = var.ip_minion_kafka, prefix = 26, gateway = null },
    { name = "enp3s0", address = var.ip_minion_sim, prefix = 26, gateway = null, routes = [{ to = var.snmp_sim_cidr, via = var.snmp_sim_gateway }] },
    { name = "enp4s0", address = null, prefix = null, gateway = null },
  ]
}

module "cloud_init_snmpsim" {
  source         = "../../../modules/cloud-init"
  vm_name        = "snmpsim"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = var.extra_packages
  interfaces = [
    { name = "enp1s0", address = var.ip_snmpsim, prefix = 26, gateway = null },
    { name = "enp2s0", address = var.ip_snmpsim, prefix = 26, gateway = null },
    { name = "enp3s0", address = null, prefix = null, gateway = null },
  ]
}

module "cloud_init_monitoring" {
  source         = "../../../modules/cloud-init"
  vm_name        = "monitoring"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = var.extra_packages
  interfaces = [
    { name = "enp1s0", address = var.ip_monitoring, prefix = 26, gateway = null },
    { name = "enp2s0", address = null, prefix = null, gateway = null },
  ]
}

resource "libvirt_cloudinit_disk" "database" {
  name           = "database-cloudinit"
  user_data      = module.cloud_init_database.user_data
  meta_data      = local.cloud_init_meta_data.database
  network_config = module.cloud_init_database.network_config
}

resource "libvirt_cloudinit_disk" "core" {
  name           = "core-cloudinit"
  user_data      = module.cloud_init_core.user_data
  meta_data      = local.cloud_init_meta_data.core
  network_config = module.cloud_init_core.network_config
}

resource "libvirt_cloudinit_disk" "kafka" {
  name           = "kafka-cloudinit"
  user_data      = module.cloud_init_kafka.user_data
  meta_data      = local.cloud_init_meta_data.kafka
  network_config = module.cloud_init_kafka.network_config
}

resource "libvirt_cloudinit_disk" "minion" {
  name           = "minion-cloudinit"
  user_data      = module.cloud_init_minion.user_data
  meta_data      = local.cloud_init_meta_data.minion
  network_config = module.cloud_init_minion.network_config
}

resource "libvirt_cloudinit_disk" "snmpsim" {
  name           = "snmpsim-cloudinit"
  user_data      = module.cloud_init_snmpsim.user_data
  meta_data      = local.cloud_init_meta_data.snmpsim
  network_config = module.cloud_init_snmpsim.network_config
}

resource "libvirt_cloudinit_disk" "monitoring" {
  name           = "monitoring-cloudinit"
  user_data      = module.cloud_init_monitoring.user_data
  meta_data      = local.cloud_init_meta_data.monitoring
  network_config = module.cloud_init_monitoring.network_config
}

resource "libvirt_volume" "database_cloudinit" {
  name = "database-cloudinit.iso"
  pool = var.storage_pool

  create = {
    content = {
      url = libvirt_cloudinit_disk.database.path
    }
  }
}

resource "libvirt_volume" "core_cloudinit" {
  name = "core-cloudinit.iso"
  pool = var.storage_pool

  create = {
    content = {
      url = libvirt_cloudinit_disk.core.path
    }
  }
}

resource "libvirt_volume" "kafka_cloudinit" {
  name = "kafka-cloudinit.iso"
  pool = var.storage_pool

  create = {
    content = {
      url = libvirt_cloudinit_disk.kafka.path
    }
  }
}

resource "libvirt_volume" "minion_cloudinit" {
  name = "minion-cloudinit.iso"
  pool = var.storage_pool

  create = {
    content = {
      url = libvirt_cloudinit_disk.minion.path
    }
  }
}

resource "libvirt_volume" "snmpsim_cloudinit" {
  name = "snmpsim-cloudinit.iso"
  pool = var.storage_pool

  create = {
    content = {
      url = libvirt_cloudinit_disk.snmpsim.path
    }
  }
}

resource "libvirt_volume" "monitoring_cloudinit" {
  name = "monitoring-cloudinit.iso"
  pool = var.storage_pool

  create = {
    content = {
      url = libvirt_cloudinit_disk.monitoring.path
    }
  }
}

resource "libvirt_domain" "database" {
  name        = "database"
  type        = "kvm"
  memory      = 4096
  memory_unit = "MiB"
  vcpu        = 2

  os = {
    type    = "hvm"
    arch    = "x86_64"
    machine = "q35"
  }

  features = {
    acpi = true
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.database.pool
            volume = libvirt_volume.database.name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_volume.database_cloudinit.pool
            volume = libvirt_volume.database_cloudinit.name
          }
        }
        target = {
          dev = "sdb"
          bus = "sata"
        }
      }
    ]
    interfaces = [
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_mgmt_id
          }
        }
      },
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_db_id
          }
        }
      },
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_external_id
          }
        }
      }
    ]
    consoles = [
      {
        type        = "pty"
        target_port = 0
        target_type = "serial"
      }
    ]
    graphics = [
      {
        type        = "vnc"
        listen_type = "address"
        auto_port   = true
      }
    ]
  }
}

resource "libvirt_domain" "core" {
  name        = "core"
  type        = "kvm"
  memory      = 16384
  memory_unit = "MiB"
  vcpu        = 4

  os = {
    type    = "hvm"
    arch    = "x86_64"
    machine = "q35"
  }

  features = {
    acpi = true
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.core.pool
            volume = libvirt_volume.core.name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_volume.core_cloudinit.pool
            volume = libvirt_volume.core_cloudinit.name
          }
        }
        target = {
          dev = "sdb"
          bus = "sata"
        }
      }
    ]
    interfaces = [
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_mgmt_id
          }
        }
      },
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_db_id
          }
        }
      },
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_kafka_id
          }
        }
      },
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_external_id
          }
        }
      }
    ]
    consoles = [
      {
        type        = "pty"
        target_port = 0
        target_type = "serial"
      }
    ]
    graphics = [
      {
        type        = "vnc"
        listen_type = "address"
        auto_port   = true
      }
    ]
  }
}

resource "libvirt_domain" "kafka" {
  name        = "kafka"
  type        = "kvm"
  memory      = 4096
  memory_unit = "MiB"
  vcpu        = 2

  os = {
    type    = "hvm"
    arch    = "x86_64"
    machine = "q35"
  }

  features = {
    acpi = true
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.kafka.pool
            volume = libvirt_volume.kafka.name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_volume.kafka_cloudinit.pool
            volume = libvirt_volume.kafka_cloudinit.name
          }
        }
        target = {
          dev = "sdb"
          bus = "sata"
        }
      }
    ]
    interfaces = [
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_mgmt_id
          }
        }
      },
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_kafka_id
          }
        }
      },
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_external_id
          }
        }
      }
    ]
    consoles = [
      {
        type        = "pty"
        target_port = 0
        target_type = "serial"
      }
    ]
    graphics = [
      {
        type        = "vnc"
        listen_type = "address"
        auto_port   = true
      }
    ]
  }
}

resource "libvirt_domain" "minion" {
  name        = "minion"
  type        = "kvm"
  memory      = 4096
  memory_unit = "MiB"
  vcpu        = 2

  os = {
    type    = "hvm"
    arch    = "x86_64"
    machine = "q35"
  }

  features = {
    acpi = true
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.minion.pool
            volume = libvirt_volume.minion.name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_volume.minion_cloudinit.pool
            volume = libvirt_volume.minion_cloudinit.name
          }
        }
        target = {
          dev = "sdb"
          bus = "sata"
        }
      }
    ]
    interfaces = [
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_mgmt_id
          }
        }
      },
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_kafka_id
          }
        }
      },
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_sim_id
          }
        }
      },
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_external_id
          }
        }
      }
    ]
    consoles = [
      {
        type        = "pty"
        target_port = 0
        target_type = "serial"
      }
    ]
    graphics = [
      {
        type        = "vnc"
        listen_type = "address"
        auto_port   = true
      }
    ]
  }
}

resource "libvirt_domain" "snmpsim" {
  name        = "snmpsim"
  type        = "kvm"
  memory      = 4096
  memory_unit = "MiB"
  vcpu        = 2

  os = {
    type    = "hvm"
    arch    = "x86_64"
    machine = "q35"
  }

  features = {
    acpi = true
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.snmpsim.pool
            volume = libvirt_volume.snmpsim.name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_volume.snmpsim_cloudinit.pool
            volume = libvirt_volume.snmpsim_cloudinit.name
          }
        }
        target = {
          dev = "sdb"
          bus = "sata"
        }
      }
    ]
    interfaces = [
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_mgmt_id
          }
        }
      },
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_sim_id
          }
        }
      },
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_external_id
          }
        }
      }
    ]
    consoles = [
      {
        type        = "pty"
        target_port = 0
        target_type = "serial"
      }
    ]
    graphics = [
      {
        type        = "vnc"
        listen_type = "address"
        auto_port   = true
      }
    ]
  }
}

resource "libvirt_domain" "monitoring" {
  name        = "monitoring"
  type        = "kvm"
  memory      = 4096
  memory_unit = "MiB"
  vcpu        = 2

  os = {
    type    = "hvm"
    arch    = "x86_64"
    machine = "q35"
  }

  features = {
    acpi = true
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.monitoring.pool
            volume = libvirt_volume.monitoring.name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_volume.monitoring_cloudinit.pool
            volume = libvirt_volume.monitoring_cloudinit.name
          }
        }
        target = {
          dev = "sdb"
          bus = "sata"
        }
      }
    ]
    interfaces = [
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_mgmt_id
          }
        }
      },
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_external_id
          }
        }
      }
    ]
    consoles = [
      {
        type        = "pty"
        target_port = 0
        target_type = "serial"
      }
    ]
    graphics = [
      {
        type        = "vnc"
        listen_type = "address"
        auto_port   = true
      }
    ]
  }
}
