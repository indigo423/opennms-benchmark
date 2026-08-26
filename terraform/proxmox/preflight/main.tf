locals {
  # Reads are cumulative and create nothing. Creates are exclusive, so a rung
  # never brings a later rung's resources into scope.
  reads_version = var.rung >= 0
  reads_host    = var.rung >= 1
  creates_probe = var.rung == 2
  creates_vm    = var.rung == 3

  preflight_vm_name = "preflight-proxmox-01"
}

locals {
  # Resolved from the nodes read, which needs no node_name and so cannot fail on
  # a wrong one. Everything that requires a valid node keys off this.
  node_name_ok = local.reads_host ? contains(one(data.proxmox_virtual_environment_nodes.this[*].names), var.proxmox_node) : false

  # Guarded so rung 0, and any rung with an unresolvable node, collapses to empty
  # rather than erroring on a data source that is out of scope or unreadable.
  datastores = local.reads_host && local.node_name_ok ? coalesce(one(data.proxmox_datastores.this[*].datastores), []) : []

  datastore_content_types = { for d in local.datastores : d.id => sort(tolist(d.content_types)) }
  datastore_types         = { for d in local.datastores : d.id => d.type }
}

# ── rung 0: does the endpoint answer and does the token authenticate? ────────
#
# The cheapest possible proof. Reads the version over the API and creates
# nothing, so a failure here is unambiguously endpoint, TLS, or credential.
data "proxmox_version" "this" {
  count = local.reads_version ? 1 : 0
}

# ── rung 1: what does the host actually look like? ──────────────────────────
#
# Discovers the facts the lab stack assumes rather than trusting tfvars. This
# is where a wrong proxmox_node and a datastore missing the snippets content
# type surface, both before any resource exists.
data "proxmox_virtual_environment_nodes" "this" {
  count = local.reads_host ? 1 : 0
}

# count gated on the node actually existing, not just on the rung. This data
# source requires node_name, so with a wrong proxmox_node the read fails and
# aborts the plan with a raw provider error -- before check "node_name_resolves"
# or any output can say which name was wrong and what the real ones are. That
# would make rung 1 unable to report the very failure it exists to report, in
# the one case where the report is needed.
data "proxmox_datastores" "this" {
  count     = local.reads_host && local.node_name_ok ? 1 : 0
  node_name = var.proxmox_node
}

# Checks rather than variable validations: a preflight should report everything
# it can see in one run, not abort on the first problem. These surface as
# warnings alongside the outputs.
check "node_name_resolves" {
  assert {
    condition     = !local.reads_host || contains(one(data.proxmox_virtual_environment_nodes.this[*].names), var.proxmox_node)
    error_message = "proxmox_node = \"${var.proxmox_node}\" is not a node on this cluster. Available: ${local.reads_host ? join(", ", one(data.proxmox_virtual_environment_nodes.this[*].names)) : "unknown"}."
  }
}

check "snippets_datastore_permits_snippets" {
  assert {
    condition     = !local.reads_host || !local.node_name_ok || contains(try(local.datastore_content_types[var.snippets_datastore], []), "snippets")
    error_message = "Datastore \"${var.snippets_datastore}\" does not permit the 'snippets' content type, so rung 2 cannot pass. A default PVE installation does not enable it. Fix: pvesm set ${var.snippets_datastore} --content <existing>,snippets"
  }
}

# Snippets are plain files, so any block-backed store has nowhere to put them.
# Checking only lvmthin let a ZFS pool or an RBD store pass rung 1 clean and
# then fail at rung 2 with an opaque upload error -- the exact
# failure-cannot-be-attributed outcome this ladder exists to prevent.
#
# The same list lives in the hypervisor role as proxmox_block_datastore_types.
# Duplicated rather than shared because the two are in different languages;
# they have to agree, so change both together.
#
# A blocklist fails open: a PVE storage type in neither list passes this check
# and would surface at rung 2 instead. Kept as a blocklist anyway, to stay
# consistent with the role, and because the preceding check is the real gate --
# PVE will not accept the snippets content type on a block-backed store, so a
# datastore that passes that one is file-based by construction. This check
# exists to say so in a sentence rather than through an upload failure.
locals {
  block_datastore_types = ["lvm", "lvmthin", "zfspool", "rbd", "iscsi", "iscsidirect"]
}

check "snippets_datastore_is_file_based" {
  assert {
    condition     = !local.reads_host || !local.node_name_ok || !contains(local.block_datastore_types, try(local.datastore_types[var.snippets_datastore], "dir"))
    error_message = "Datastore \"${var.snippets_datastore}\" is type ${try(local.datastore_types[var.snippets_datastore], "unknown")}, which is block-backed and cannot hold snippets. Snippets are plain files: point snippets_datastore at a file-based store such as a dir store."
  }
}

# ── rung 2: can the provider write a snippet? ───────────────────────────────
#
# The highest-risk mechanism in the whole Proxmox path, and the reason the
# provider needs SSH at all. Passing rungs 0 through 2 is the affirmative
# answer to "does the provider work".
resource "proxmox_virtual_environment_file" "probe" {
  count        = local.creates_probe ? 1 : 0
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    # Named distinctly from any lab snippet (<vm-name>-user-data.yaml) so a
    # destroy here can never reach the lab stack's files.
    file_name = "preflight-probe.yaml"
    data      = <<-EOT
      #cloud-config
      # Written by terraform/proxmox/preflight rung 2. Proves the provider can
      # reach the snippets datastore over SSH as a PAM account. Not consumed by
      # any VM. Safe to delete; `terraform destroy` here removes it.
    EOT
  }
}

# ── rung 3: does a VM clone, configure, and report back? ────────────────────
#
# Reuses the shared cloud-init module rather than a hand-rolled document, so
# this proves the template the lab stack actually renders. modules/compute is
# deliberately not reused: it defines seven VMs, which is the opposite of
# minimal.
module "cloud_init" {
  count  = local.creates_vm ? 1 : 0
  source = "../../modules/cloud-init"

  vm_name        = local.preflight_vm_name
  admin_user     = var.admin_user
  ssh_public_key = trimspace(file(pathexpand("${var.ssh_key_path}.pub")))
  hosts          = {}
  extra_packages = ["qemu-guest-agent"]

  # A single interface, name from preflight_interface because it depends on the
  # template's machine type. address = null selects DHCP, which is the default;
  # the static overrides exist to re-test on the management bridge after host
  # prep.
  interfaces = [
    {
      name        = var.preflight_interface
      address     = var.preflight_address
      prefix      = var.preflight_prefix
      gateway     = var.preflight_gateway
      nameservers = var.preflight_nameservers
    },
  ]
}

resource "proxmox_virtual_environment_file" "user_data" {
  count        = local.creates_vm ? 1 : 0
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "${local.preflight_vm_name}-user-data.yaml"
    data      = one(module.cloud_init[*].user_data)
  }
}

resource "proxmox_virtual_environment_file" "network_data" {
  count        = local.creates_vm ? 1 : 0
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "${local.preflight_vm_name}-network-config.yaml"
    data      = one(module.cloud_init[*].network_config)
  }
}

resource "proxmox_virtual_environment_vm" "preflight" {
  count     = local.creates_vm ? 1 : 0
  name      = local.preflight_vm_name
  node_name = var.proxmox_node
  vm_id     = var.preflight_vm_id

  # preflight_vm_id's own validation excludes the lab stack's 196-202 but cannot
  # reference another variable: cross-variable validation needs Terraform 1.9 and
  # this root declares >= 1.5. So the template collision -- which the variable's
  # description already promises to prevent -- is asserted here instead, where
  # both values are in scope. Without it, preflight_vm_id = template_vm_id plans
  # cleanly and then tries to clone the template into its own ID.
  lifecycle {
    precondition {
      condition     = var.preflight_vm_id != var.template_vm_id
      error_message = "preflight_vm_id (${var.preflight_vm_id}) is the template's own VM ID. Rung 3 clones the template, so the source and destination cannot be the same."
    }
  }

  # Distinct from the lab stack's "opennms-benchmark" tag so preflight leftovers
  # are identifiable at a glance in the Proxmox UI.
  tags = ["proxmox-preflight"]

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = 1
    type  = "host"
  }

  memory {
    dedicated = 1024
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.preflight_disk_gb
    iothread     = true
  }

  network_device {
    bridge = var.preflight_bridge
    model  = "virtio"
  }

  # Enabled on purpose. Terraform waits for the agent to report an address, so
  # this is what proves cloud-init ran to completion rather than merely that the
  # clone succeeded. It is also the failure an operator is most likely to
  # misread: no egress means no qemu-guest-agent, which surfaces as a provider
  # timeout rather than a routing error.
  agent {
    enabled = true
  }

  serial_device {}

  operating_system {
    type = "l26"
  }

  initialization {
    user_data_file_id    = one(proxmox_virtual_environment_file.user_data[*].id)
    network_data_file_id = one(proxmox_virtual_environment_file.network_data[*].id)
  }
}
