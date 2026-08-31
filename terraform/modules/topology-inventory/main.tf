terraform {
  required_version = ">= 1.5"
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

locals {
  # Union of all group names across hosts.
  all_groups = sort(distinct(flatten([for h, n in var.hosts : n.groups])))

  # group -> sorted member hostnames.
  group_members = {
    for g in local.all_groups :
    g => sort([for h, n in var.hosts : h if contains(n.groups, g)])
  }

  # Parent groups, with children filtered to those actually present.
  parent_present = {
    for p, children in var.parent_groups :
    p => [for c in children : c if contains(local.all_groups, c)]
    if length([for c in children : c if contains(local.all_groups, c)]) > 0
  }
}

# One inventory per provider root, so two labs deployed from one checkout never
# overwrite each other's Ansible inputs (#277). The provider is the root
# directory's name (terraform/<provider>/), taken from the filesystem rather
# than a variable so no root has to say what it already is. Renamed from
# ansible_inventory so the `removed` block in each root can drop the old
# address from state without deleting the file a running lab still reads.
resource "local_file" "inventory" {
  filename = "${path.root}/../../ansible-inventory.${basename(abspath(path.root))}.yml"

  # NOTE: the template intentionally mirrors the legacy modules/inventory template
  # while azure/proxmox/vmware still use it. When they migrate to this module the
  # legacy one is removed and this becomes the single source.
  lifecycle {
    precondition {
      condition     = alltrue([for h, n in var.hosts : try(n.ansible_host, "") != ""])
      error_message = "Every host needs a management IP (ansible_host); a role in the deployment is missing a 'mgmt' subnet in its topology.yml interfaces."
    }
  }

  content = templatefile("${path.module}/templates/inventory.yml.tftpl", {
    hosts          = var.hosts
    admin_user     = var.admin_user
    ssh_key_path   = var.ssh_key_path
    jump_host      = var.jump_host
    jump_host_name = var.jump_host_name
    group_members  = local.group_members
    parent_groups  = local.parent_present
  })
}
