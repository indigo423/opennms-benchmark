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
    database      = <<-EOF
      instance-id: db-benchmark-01
      local-hostname: db-benchmark-01
    EOF
    core          = <<-EOF
      instance-id: core-benchmark-01
      local-hostname: core-benchmark-01
    EOF
    kafka         = <<-EOF
      instance-id: kafka-benchmark-01
      local-hostname: kafka-benchmark-01
    EOF
    minion        = <<-EOF
      instance-id: minion-benchmark-01
      local-hostname: minion-benchmark-01
    EOF
    netsim        = <<-EOF
      instance-id: netsim-benchmark-01
      local-hostname: netsim-benchmark-01
    EOF
    monitoring    = <<-EOF
      instance-id: mon-benchmark-01
      local-hostname: mon-benchmark-01
    EOF
    elasticsearch = <<-EOF
      instance-id: es-benchmark-01
      local-hostname: es-benchmark-01
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
      condition     = can(regex("^https?://", var.ubuntu_cloud_image)) || fileexists(var.ubuntu_cloud_image)
      error_message = "Ubuntu 24.04 cloud image must be either an existing local qcow2 path or an http(s) URL. Got '${var.ubuntu_cloud_image}'."
    }
  }
}

resource "libvirt_volume" "elasticsearch" {
  name = "es-benchmark-01.qcow2"
  pool = var.storage_pool

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = libvirt_volume.ubuntu_base.path
    format = { type = "qcow2" }
  }

  capacity      = var.disk_sizes_gb["elasticsearch"]
  capacity_unit = "GiB"
}

resource "libvirt_volume" "database" {
  name = "db-benchmark-01.qcow2"
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
  name = "core-benchmark-01.qcow2"
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
  name = "kafka-benchmark-01.qcow2"
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
  name = "minion-benchmark-01.qcow2"
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

resource "libvirt_volume" "netsim" {
  name = "netsim-benchmark-01.qcow2"
  pool = var.storage_pool

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = libvirt_volume.ubuntu_base.path
    format = { type = "qcow2" }
  }

  capacity      = var.disk_sizes_gb["netsim"]
  capacity_unit = "GiB"
}

resource "libvirt_volume" "monitoring" {
  name = "mon-benchmark-01.qcow2"
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

module "cloud_init_elasticsearch" {
  source         = "../../../modules/cloud-init"
  vm_name        = "es-benchmark-01"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = var.extra_packages
  interfaces = [
    { name = "enp1s0", address = var.ip_elasticsearch, prefix = 26, gateway = var.gateway_mgmt },
    { name = "enp2s0", address = var.ip_es_core,       prefix = 26, gateway = null },
  ]
}

module "cloud_init_database" {
  source         = "../../../modules/cloud-init"
  vm_name        = "db-benchmark-01"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = var.extra_packages
  interfaces = [
    { name = "enp1s0", address = var.ip_database, prefix = 26, gateway = var.gateway_mgmt },
    { name = "enp2s0", address = var.ip_database_db, prefix = 26, gateway = null },
  ]
}

module "cloud_init_core" {
  source         = "../../../modules/cloud-init"
  vm_name        = "core-benchmark-01"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = var.extra_packages
  interfaces = [
    { name = "enp1s0", address = var.ip_core, prefix = 26, gateway = var.gateway_mgmt },
    { name = "enp2s0", address = var.ip_core_db, prefix = 26, gateway = null },
    { name = "enp3s0", address = var.ip_core_kafka, prefix = 26, gateway = null },
  ]
}

module "cloud_init_kafka" {
  source         = "../../../modules/cloud-init"
  vm_name        = "kafka-benchmark-01"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = var.extra_packages
  interfaces = [
    { name = "enp1s0", address = var.ip_kafka, prefix = 26, gateway = var.gateway_mgmt },
    { name = "enp2s0", address = var.ip_kafka_kafka, prefix = 26, gateway = null },
  ]
}

module "cloud_init_minion" {
  source         = "../../../modules/cloud-init"
  vm_name        = "minion-benchmark-01"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = var.extra_packages
  interfaces = [
    { name = "enp1s0", address = var.ip_minion, prefix = 26, gateway = var.gateway_mgmt },
    { name = "enp2s0", address = var.ip_minion_kafka, prefix = 26, gateway = null },
    { name = "enp3s0", address = var.ip_minion_sim, prefix = 26, gateway = null, routes = [{ to = var.net_sim_cidr, via = var.net_sim_gateway }] },
  ]
}

module "cloud_init_netsim" {
  source         = "../../../modules/cloud-init"
  vm_name        = "netsim-benchmark-01"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = var.extra_packages
  local_routes   = [var.net_sim_cidr]
  interfaces = [
    { name = "enp1s0", address = var.ip_netsim, prefix = 26, gateway = var.gateway_mgmt },
    { name = "enp2s0", address = var.ip_netsim_sim, prefix = 26, gateway = null },
  ]
}

module "cloud_init_monitoring" {
  source         = "../../../modules/cloud-init"
  vm_name        = "mon-benchmark-01"
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = var.extra_packages
  interfaces = [
    { name = "enp1s0", address = var.ip_monitoring, prefix = 26, gateway = null },
    { name = "enp2s0", address = null, prefix = null, gateway = null },
  ]
}

resource "libvirt_cloudinit_disk" "elasticsearch" {
  name           = "es-benchmark-01-cloudinit"
  user_data      = module.cloud_init_elasticsearch.user_data
  meta_data      = local.cloud_init_meta_data.elasticsearch
  network_config = module.cloud_init_elasticsearch.network_config
}

resource "libvirt_cloudinit_disk" "database" {
  name           = "db-benchmark-01-cloudinit"
  user_data      = module.cloud_init_database.user_data
  meta_data      = local.cloud_init_meta_data.database
  network_config = module.cloud_init_database.network_config
}

resource "libvirt_cloudinit_disk" "core" {
  name           = "core-benchmark-01-cloudinit"
  user_data      = module.cloud_init_core.user_data
  meta_data      = local.cloud_init_meta_data.core
  network_config = module.cloud_init_core.network_config
}

resource "libvirt_cloudinit_disk" "kafka" {
  name           = "kafka-benchmark-01-cloudinit"
  user_data      = module.cloud_init_kafka.user_data
  meta_data      = local.cloud_init_meta_data.kafka
  network_config = module.cloud_init_kafka.network_config
}

resource "libvirt_cloudinit_disk" "minion" {
  name           = "minion-benchmark-01-cloudinit"
  user_data      = module.cloud_init_minion.user_data
  meta_data      = local.cloud_init_meta_data.minion
  network_config = module.cloud_init_minion.network_config
}

resource "libvirt_cloudinit_disk" "netsim" {
  name           = "netsim-benchmark-01-cloudinit"
  user_data      = module.cloud_init_netsim.user_data
  meta_data      = local.cloud_init_meta_data.netsim
  network_config = module.cloud_init_netsim.network_config
}

resource "libvirt_cloudinit_disk" "monitoring" {
  name           = "mon-benchmark-01-cloudinit"
  user_data      = module.cloud_init_monitoring.user_data
  meta_data      = local.cloud_init_meta_data.monitoring
  network_config = module.cloud_init_monitoring.network_config
}

resource "libvirt_volume" "elasticsearch_cloudinit" {
  name = "es-benchmark-01-cloudinit.iso"
  pool = var.storage_pool

  create = {
    content = {
      url = "file://${libvirt_cloudinit_disk.elasticsearch.path}"
    }
  }
}

resource "libvirt_volume" "database_cloudinit" {
  name = "db-benchmark-01-cloudinit.iso"
  pool = var.storage_pool

  create = {
    content = {
      url = "file://${libvirt_cloudinit_disk.database.path}"
    }
  }
}

resource "libvirt_volume" "core_cloudinit" {
  name = "core-benchmark-01-cloudinit.iso"
  pool = var.storage_pool

  create = {
    content = {
      url = "file://${libvirt_cloudinit_disk.core.path}"
    }
  }
}

resource "libvirt_volume" "kafka_cloudinit" {
  name = "kafka-benchmark-01-cloudinit.iso"
  pool = var.storage_pool

  create = {
    content = {
      url = "file://${libvirt_cloudinit_disk.kafka.path}"
    }
  }
}

resource "libvirt_volume" "minion_cloudinit" {
  name = "minion-benchmark-01-cloudinit.iso"
  pool = var.storage_pool

  create = {
    content = {
      url = "file://${libvirt_cloudinit_disk.minion.path}"
    }
  }
}

resource "libvirt_volume" "netsim_cloudinit" {
  name = "netsim-benchmark-01-cloudinit.iso"
  pool = var.storage_pool

  create = {
    content = {
      url = "file://${libvirt_cloudinit_disk.netsim.path}"
    }
  }
}

resource "libvirt_volume" "monitoring_cloudinit" {
  name = "mon-benchmark-01-cloudinit.iso"
  pool = var.storage_pool

  create = {
    content = {
      url = "file://${libvirt_cloudinit_disk.monitoring.path}"
    }
  }
}

resource "libvirt_domain" "elasticsearch" {
  name        = "es-benchmark-01"
  type        = "kvm"
  running     = true
  memory      = 16384
  memory_unit = "MiB"
  vcpu        = 4

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot         = [{ dev = "hd" }]
  }

  features = {
    acpi = true
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.elasticsearch.pool
            volume = libvirt_volume.elasticsearch.name
          }
        }
        driver = {
          name = "qemu"
          type = "qcow2"
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
            pool   = libvirt_volume.elasticsearch_cloudinit.pool
            volume = libvirt_volume.elasticsearch_cloudinit.name
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
      }
    ]
    consoles = [
      {
        type        = "pty"
        target_port = 0
        target_type = "serial"
      }
    ]
    channels = [
      {
        target = {
          virt_io = {
            name = "org.qemu.guest_agent.0"
          }
        }
        source = {
          unix = {}
        }
      }
    ]
    graphics = [
      {
        vnc = {
          auto_port = true
          listen    = "0.0.0.0"
        }
      }
    ]
    videos = [
      {
        model = {
          type    = "vga"
          primary = "yes"
          heads   = 1
          vram    = 16384
        }
      }
    ]
  }
}

resource "libvirt_domain" "database" {
  name        = "db-benchmark-01"
  type        = "kvm"
  running     = true
  memory      = 4096
  memory_unit = "MiB"
  vcpu        = 2

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot         = [{ dev = "hd" }]
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
        driver = {
          name = "qemu"
          type = "qcow2"
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
      }
    ]
    consoles = [
      {
        type        = "pty"
        target_port = 0
        target_type = "serial"
      }
    ]
    channels = [
      {
        target = {
          virt_io = {
            name = "org.qemu.guest_agent.0"
          }
        }
        source = {
          unix = {}
        }
      }
    ]
    graphics = [
      {
        vnc = {
          auto_port = true
          listen    = "0.0.0.0"
        }
      }
    ]
    videos = [
      {
        model = {
          type    = "vga"
          primary = "yes"
          heads   = 1
          vram    = 16384
        }
      }
    ]
  }
}

resource "libvirt_domain" "core" {
  name        = "core-benchmark-01"
  type        = "kvm"
  running     = true
  memory      = 16384
  memory_unit = "MiB"
  vcpu        = 4

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot         = [{ dev = "hd" }]
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
        driver = {
          name = "qemu"
          type = "qcow2"
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
      }
    ]
    consoles = [
      {
        type        = "pty"
        target_port = 0
        target_type = "serial"
      }
    ]
    channels = [
      {
        target = {
          virt_io = {
            name = "org.qemu.guest_agent.0"
          }
        }
        source = {
          unix = {}
        }
      }
    ]
    graphics = [
      {
        vnc = {
          auto_port = true
          listen    = "0.0.0.0"
        }
      }
    ]
    videos = [
      {
        model = {
          type    = "vga"
          primary = "yes"
          heads   = 1
          vram    = 16384
        }
      }
    ]
  }
}

resource "libvirt_domain" "kafka" {
  name        = "kafka-benchmark-01"
  type        = "kvm"
  running     = true
  memory      = 4096
  memory_unit = "MiB"
  vcpu        = 2

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot         = [{ dev = "hd" }]
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
        driver = {
          name = "qemu"
          type = "qcow2"
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
      }
    ]
    consoles = [
      {
        type        = "pty"
        target_port = 0
        target_type = "serial"
      }
    ]
    channels = [
      {
        target = {
          virt_io = {
            name = "org.qemu.guest_agent.0"
          }
        }
        source = {
          unix = {}
        }
      }
    ]
    graphics = [
      {
        vnc = {
          auto_port = true
          listen    = "0.0.0.0"
        }
      }
    ]
    videos = [
      {
        model = {
          type    = "vga"
          primary = "yes"
          heads   = 1
          vram    = 16384
        }
      }
    ]
  }
}

resource "libvirt_domain" "minion" {
  name        = "minion-benchmark-01"
  type        = "kvm"
  running     = true
  memory      = 4096
  memory_unit = "MiB"
  vcpu        = 2

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot         = [{ dev = "hd" }]
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
        driver = {
          name = "qemu"
          type = "qcow2"
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
      }
    ]
    consoles = [
      {
        type        = "pty"
        target_port = 0
        target_type = "serial"
      }
    ]
    channels = [
      {
        target = {
          virt_io = {
            name = "org.qemu.guest_agent.0"
          }
        }
        source = {
          unix = {}
        }
      }
    ]
    graphics = [
      {
        vnc = {
          auto_port = true
          listen    = "0.0.0.0"
        }
      }
    ]
    videos = [
      {
        model = {
          type    = "vga"
          primary = "yes"
          heads   = 1
          vram    = 16384
        }
      }
    ]
  }
}

resource "libvirt_domain" "netsim" {
  name        = "netsim-benchmark-01"
  type        = "kvm"
  running     = true
  memory      = 4096
  memory_unit = "MiB"
  vcpu        = 2

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot         = [{ dev = "hd" }]
  }

  features = {
    acpi = true
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.netsim.pool
            volume = libvirt_volume.netsim.name
          }
        }
        driver = {
          name = "qemu"
          type = "qcow2"
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
            pool   = libvirt_volume.netsim_cloudinit.pool
            volume = libvirt_volume.netsim_cloudinit.name
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
      }
    ]
    consoles = [
      {
        type        = "pty"
        target_port = 0
        target_type = "serial"
      }
    ]
    channels = [
      {
        target = {
          virt_io = {
            name = "org.qemu.guest_agent.0"
          }
        }
        source = {
          unix = {}
        }
      }
    ]
    graphics = [
      {
        vnc = {
          auto_port = true
          listen    = "0.0.0.0"
        }
      }
    ]
    videos = [
      {
        model = {
          type    = "vga"
          primary = "yes"
          heads   = 1
          vram    = 16384
        }
      }
    ]
  }
}

resource "libvirt_domain" "monitoring" {
  name        = "mon-benchmark-01"
  type        = "kvm"
  running     = true
  memory      = 4096
  memory_unit = "MiB"
  vcpu        = 2

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot         = [{ dev = "hd" }]
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
        driver = {
          name = "qemu"
          type = "qcow2"
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
    channels = [
      {
        target = {
          virt_io = {
            name = "org.qemu.guest_agent.0"
          }
        }
        source = {
          unix = {}
        }
      }
    ]
    graphics = [
      {
        vnc = {
          auto_port = true
          listen    = "0.0.0.0"
        }
      }
    ]
    videos = [
      {
        model = {
          type    = "vga"
          primary = "yes"
          heads   = 1
          vram    = 16384
        }
      }
    ]
  }
}
