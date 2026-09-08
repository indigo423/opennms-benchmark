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

  # Identity of the base image, derived from its source so the volume name
  # changes whenever the pin does. See the comment on libvirt_volume.ubuntu_base
  # for why the name has to carry this.
  #
  # Two branches, and both name actual content:
  #
  #   dated release URL -> its date. Each dated directory is a distinct build.
  #   existing local file -> a hash of its BYTES, via filesha256.
  #
  # Nothing else is reachable: the precondition on libvirt_volume.ubuntu_base
  # rejects it. That is the point. This used to fall back to sha256 of the URL
  # *string*, which changes when the input changes rather than when the image
  # does, so the noble/current/ alias produced one stable name across every
  # Ubuntu build published in six months and nothing ever reported it (#304).
  #
  # filesha256 evaluates where Terraform runs, which is also where the provider
  # uploads the file from, so the two agree about which file this is.
  #
  # The third branch is a sentinel and never names a volume: the precondition on
  # libvirt_volume.ubuntu_base rejects anything that reaches it. It exists
  # because locals are evaluated BEFORE resource preconditions, so without it a
  # rejected pin dies here instead, with "filesha256 failed: open
  # https:/cloud-images... no such file or directory" - which describes the
  # fallback rather than the mistake, and buries the message that explains what
  # to do. Keep it, and keep it obviously not a build identifier.
  #
  # The rule is NOT a variable validation, which would be the natural home and
  # reads better. Variable validation is evaluated on destroy too, so it would
  # strand a host that already holds a lab built on a pin the rule now rejects:
  # the operator could neither apply nor tear down. Resource preconditions are
  # skipped for resources being destroyed. Both behaviours verified. See #304.
  ubuntu_image_tag = try(
    regex("release-([0-9]+)", var.ubuntu_cloud_image)[0],
    substr(filesha256(var.ubuntu_cloud_image), 0, 12),
    "unpinnable",
  )
}

# Ubuntu 24.04 LTS cloud image — must be the cloud image (qcow2), NOT the server installer ISO.
#
# The volume name carries the image identity, and that is load-bearing rather
# than cosmetic. With a constant name, Terraform compares the name and the URL
# *string* — never the downloaded bytes — so on a host that already holds this
# volume, changing the URL produces no diff and the new image is never fetched.
# The pin would land in the repository and never on the machine.
#
# That also made the pre-pin state worse than merely floating: the substrate was
# a function of when a given host first ran apply, which Terraform does not
# track and the repository cannot see. Two hosts running identical code held
# different Ubuntu builds and nothing reported it.
#
# Consequence worth expecting: the first apply after the pin changes REPLACES
# this volume, and Terraform destroys the old one itself. It is not orphaned and
# it is not unreferenced. At the moment of replacement it is the backing file of
# every libvirt_volume.os in the lab. Nothing is left in the pool to remove.
#
# On a host that already holds a lab, a bump is therefore a rebuild. deploy.sh
# refuses it before Terraform runs (see check_base_image_pin there) and tells you
# to tear the lab down first. Measured against dmacvicar/libvirt 0.9.9; see #261
# and the version note on create_before_destroy below.
resource "libvirt_volume" "ubuntu_base" {
  name = "ubuntu-24.04-base-${local.ubuntu_image_tag}"
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
    # Ordering, not optimisation. libvirt 0.9.9 declares no RequiresReplace on
    # libvirt_volume.backing_store, so a changed base name plans as an in-place
    # update on every OS disk and lands in the provider's Update, which errors
    # unconditionally (dmacvicar/terraform-provider-libvirt#1374). Destroy-first
    # deletes this volume BEFORE reaching that error, leaving every OS disk with
    # a qcow2 header naming a file that no longer exists: the domains keep
    # running on an open fd and die at their next reboot. Create-first sequences
    # the destroy after the failing update, so it never runs. The apply still
    # fails, but nothing is lost and every backing chain still resolves.
    #
    # This works only because the name carries the image identity: the old and
    # new volumes have different names and can coexist. Under a constant name
    # Terraform rejects create_before_destroy as a name collision.
    #
    # If #1374 lands, backing_store becomes force-new, libvirt_volume.os starts
    # being REPLACED. It is created from a backing store and nothing else, so it
    # comes back blank. This line does not help there; the deploy.sh guard does.
    create_before_destroy = true

    # The pin must name immutable content, because a benchmark substrate that
    # can change under a stable name is the whole defect (#304). A dated
    # release qualifies: the directory is a distinct build. A remote URL that
    # is not dated does not, however plausible it looks, so it is refused here
    # rather than given a stable-looking name by the tag derivation above.
    #
    # A rejected pin does NOT lock an operator out of a lab built before this
    # rule existed: Terraform skips condition checks for resources being
    # destroyed, so `make destroy PROVIDER=kvm` still works. Verified, not
    # assumed. The recovery is destroy, correct the pin, deploy.
    precondition {
      condition = (
        can(regex("/release-[0-9]+/", var.ubuntu_cloud_image))
        || (!can(regex("^https?://", var.ubuntu_cloud_image)) && fileexists(var.ubuntu_cloud_image))
      )
      error_message = <<-EOT
        ubuntu_cloud_image must name immutable content. Got '${var.ubuntu_cloud_image}'.

        Accepted:
          - a dated release URL, e.g.
            https://cloud-images.ubuntu.com/releases/noble/release-20260814/ubuntu-24.04-server-cloudimg-amd64.img
          - a path to a file that exists on the machine running Terraform
            (not on the KVM host - the upload resolves client-side)

        Rejected: a floating alias such as .../noble/current/..., whose contents
        change while its name does not. A tag derived from it never changes, so
        the image on a host becomes a function of when that host first ran apply.

        The pin now defaults from terraform/kvm/variables.tf. To adopt it, delete
        the ubuntu_cloud_image line from kvm.tfvars. If this host already holds a
        lab, that changes the base image tag, so deploy.sh will refuse until you
        run `make destroy PROVIDER=kvm` first. See #304 and #261.
      EOT
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
  # with no SSE4.2, AVX or AVX2.
  #
  # Software that requires SSE4.2 then dies outright, at package configuration
  # time, with "Illegal instruction (core dumped)".
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
