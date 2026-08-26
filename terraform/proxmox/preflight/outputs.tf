output "rung" {
  value       = var.rung
  description = "The rung that ran"
}

# ── rung 0 ───────────────────────────────────────────────────────────────────

output "pve_version" {
  value       = one(data.proxmox_version.this[*].version)
  description = "Reported Proxmox VE version. Compare against the provider's declared compatibility range: bpg/proxmox targets PVE 9.x."
}

output "pve_release" {
  value       = one(data.proxmox_version.this[*].release)
  description = "Reported Proxmox VE release"
}

# ── rung 1 ───────────────────────────────────────────────────────────────────

output "node_names" {
  value       = local.reads_host ? one(data.proxmox_virtual_environment_nodes.this[*].names) : null
  description = "Every node name on the cluster. If proxmox_node is not in this list, nothing downstream can work."
}

output "node_name_matches" {
  value       = local.reads_host ? contains(one(data.proxmox_virtual_environment_nodes.this[*].names), var.proxmox_node) : null
  description = "Whether the configured proxmox_node exists on this cluster"
}

output "datastore_content_types" {
  value       = local.reads_host && local.node_name_ok ? local.datastore_content_types : null
  description = "Permitted content types per datastore. The lab stack needs 'snippets' on snippets_datastore and 'images' on storage_pool."
}

output "datastore_space_available_gib" {
  value = local.reads_host && local.node_name_ok ? {
    for d in local.datastores : d.id => floor(coalesce(d.space_available, 0) / 1024 / 1024 / 1024)
  } : null
  description = "Available space per datastore in GiB. Reconcile storage_pool against the lab stack's total provisioned disk before applying it: a full LVM-thin pool corrupts guests rather than failing writes."
}

# The explicit verdict on the blocker most likely to stop the lab stack, stated
# rather than left for the reader to infer from the content-type map.
output "snippets_datastore_ready" {
  value = !local.reads_host ? null : !local.node_name_ok ? "unknown — proxmox_node does not resolve, so no datastore could be read" : (
    contains(try(local.datastore_content_types[var.snippets_datastore], []), "snippets")
    ? "yes — \"${var.snippets_datastore}\" permits snippets, rung 2 can run"
    : "NO — \"${var.snippets_datastore}\" permits [${join(", ", try(local.datastore_content_types[var.snippets_datastore], ["<datastore not found>"]))}]. Rung 2 will fail. Fix: pvesm set ${var.snippets_datastore} --content <existing>,snippets"
  )
  description = "Whether the configured snippets datastore can hold cloud-init snippets"
}

# ── rung 2 ───────────────────────────────────────────────────────────────────

output "probe_snippet_id" {
  value       = one(proxmox_virtual_environment_file.probe[*].id)
  description = "The uploaded probe snippet. Non-null means the API token, the SSH agent, the PAM account, the SFTP transport and the datastore content type are all working — the provider verdict is yes."
}

# ── rung 3 ───────────────────────────────────────────────────────────────────

output "preflight_vm_ipv4" {
  value       = one(proxmox_virtual_environment_vm.preflight[*].ipv4_addresses)
  description = "Addresses the guest agent reported. Non-empty means the clone booted and cloud-init completed; the agent cannot report if it was never installed."
}

output "preflight_vm_id" {
  value       = one(proxmox_virtual_environment_vm.preflight[*].vm_id)
  description = "VM ID of the preflight VM, for manual cleanup if state is ever lost"
}
