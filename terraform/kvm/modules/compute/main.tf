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
  network_ids = {
    mgmt     = var.network_mgmt_id
    db       = var.network_db_id
    kafka    = var.network_kafka_id
    sim      = var.network_sim_id
    external = var.network_external_id
    lab      = var.network_external_id
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

# OS disk per role — qcow2 backed by the shared Ubuntu base image.
resource "libvirt_volume" "os" {
  for_each = var.topology

  name = "${each.value.vm_name}.qcow2"
  pool = var.storage_pool

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = libvirt_volume.ubuntu_base.path
    format = { type = "qcow2" }
  }

  capacity      = each.value.disk_gb
  capacity_unit = "GiB"
}

module "cloud_init" {
  for_each = var.topology
  source   = "../../../modules/cloud-init"

  vm_name        = each.value.vm_name
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts
  extra_packages = var.extra_packages
  interfaces = [
    for i in each.value.interfaces : {
      name        = i.iface_name
      address     = i.address
      prefix      = i.prefix
      gateway     = i.gateway
      routes      = i.routes
      nameservers = i.nameservers
    }
  ]
}

resource "libvirt_cloudinit_disk" "ci" {
  for_each = var.topology

  name           = "${each.value.vm_name}-cloudinit"
  user_data      = module.cloud_init[each.key].user_data
  meta_data      = "instance-id: ${each.value.vm_name}\nlocal-hostname: ${each.value.vm_name}\n"
  network_config = module.cloud_init[each.key].network_config
}

# The cloud-init disk exposed as a pool volume (ISO) so the domain can attach it.
resource "libvirt_volume" "ci_iso" {
  for_each = var.topology

  name = "${each.value.vm_name}-cloudinit.iso"
  pool = var.storage_pool

  create = {
    content = {
      url = "file://${libvirt_cloudinit_disk.ci[each.key].path}"
    }
  }
}

resource "libvirt_domain" "vm" {
  for_each = var.topology

  name        = each.value.vm_name
  type        = "kvm"
  running     = true
  memory      = each.value.memory
  memory_unit = "MiB"
  vcpu        = each.value.vcpu

  # Without this libvirt defaults to the qemu64 model: an x86-64 baseline CPU
  # with no SSE4.2, AVX or AVX2. Two consequences, both bad for this lab.
  #
  # ClickHouse requires SSE4.2 and dies at package configuration time with
  # "Illegal instruction (core dumped)" — Deployment H cannot install at all.
  #
  # More quietly, every number this lab has ever produced was measured on a
  # CPU without vector instructions. JVM intrinsics, Kafka and Elasticsearch
  # compression and checksums, and the TSDB engines all lean on SSE4.2/AVX2,
  # so results were systematically unrepresentative of the hardware anyone
  # actually runs on — the opposite of what a benchmark lab is for.
  #
  # host-passthrough rather than host-model: this is a single-hypervisor lab
  # with no live migration to preserve, so exposing the host CPU exactly is
  # both the fastest and the most faithful option.
  cpu = {
    mode = "host-passthrough"
  }

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
            pool   = libvirt_volume.os[each.key].pool
            volume = libvirt_volume.os[each.key].name
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
            pool   = libvirt_volume.ci_iso[each.key].pool
            volume = libvirt_volume.ci_iso[each.key].name
          }
        }
        target = {
          dev = "sdb"
          bus = "sata"
        }
      }
    ]
    interfaces = [
      for i in each.value.interfaces : {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = local.network_ids[i.subnet]
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

# Preserve state addresses across the per-role -> for_each refactor (no destroy).
moved {
  from = libvirt_volume.elasticsearch
  to   = libvirt_volume.os["elasticsearch"]
}
moved {
  from = libvirt_volume.database
  to   = libvirt_volume.os["database"]
}
moved {
  from = libvirt_volume.core
  to   = libvirt_volume.os["core"]
}
moved {
  from = libvirt_volume.kafka
  to   = libvirt_volume.os["kafka"]
}
moved {
  from = libvirt_volume.minion
  to   = libvirt_volume.os["minion"]
}
moved {
  from = libvirt_volume.netsim
  to   = libvirt_volume.os["netsim"]
}
moved {
  from = libvirt_volume.monitoring
  to   = libvirt_volume.os["monitoring"]
}

moved {
  from = libvirt_volume.elasticsearch_cloudinit
  to   = libvirt_volume.ci_iso["elasticsearch"]
}
moved {
  from = libvirt_volume.database_cloudinit
  to   = libvirt_volume.ci_iso["database"]
}
moved {
  from = libvirt_volume.core_cloudinit
  to   = libvirt_volume.ci_iso["core"]
}
moved {
  from = libvirt_volume.kafka_cloudinit
  to   = libvirt_volume.ci_iso["kafka"]
}
moved {
  from = libvirt_volume.minion_cloudinit
  to   = libvirt_volume.ci_iso["minion"]
}
moved {
  from = libvirt_volume.netsim_cloudinit
  to   = libvirt_volume.ci_iso["netsim"]
}
moved {
  from = libvirt_volume.monitoring_cloudinit
  to   = libvirt_volume.ci_iso["monitoring"]
}

moved {
  from = libvirt_cloudinit_disk.elasticsearch
  to   = libvirt_cloudinit_disk.ci["elasticsearch"]
}
moved {
  from = libvirt_cloudinit_disk.database
  to   = libvirt_cloudinit_disk.ci["database"]
}
moved {
  from = libvirt_cloudinit_disk.core
  to   = libvirt_cloudinit_disk.ci["core"]
}
moved {
  from = libvirt_cloudinit_disk.kafka
  to   = libvirt_cloudinit_disk.ci["kafka"]
}
moved {
  from = libvirt_cloudinit_disk.minion
  to   = libvirt_cloudinit_disk.ci["minion"]
}
moved {
  from = libvirt_cloudinit_disk.netsim
  to   = libvirt_cloudinit_disk.ci["netsim"]
}
moved {
  from = libvirt_cloudinit_disk.monitoring
  to   = libvirt_cloudinit_disk.ci["monitoring"]
}

moved {
  from = libvirt_domain.elasticsearch
  to   = libvirt_domain.vm["elasticsearch"]
}
moved {
  from = libvirt_domain.database
  to   = libvirt_domain.vm["database"]
}
moved {
  from = libvirt_domain.core
  to   = libvirt_domain.vm["core"]
}
moved {
  from = libvirt_domain.kafka
  to   = libvirt_domain.vm["kafka"]
}
moved {
  from = libvirt_domain.minion
  to   = libvirt_domain.vm["minion"]
}
moved {
  from = libvirt_domain.netsim
  to   = libvirt_domain.vm["netsim"]
}
moved {
  from = libvirt_domain.monitoring
  to   = libvirt_domain.vm["monitoring"]
}

moved {
  from = module.cloud_init_elasticsearch
  to   = module.cloud_init["elasticsearch"]
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
