output "nodes" {
  value       = local.nodes
  description = "Node key -> { prole, index, cfg }. One entry per instance, so a role with count 3 yields three."
}

output "node_address" {
  value       = local.node_address
  description = "Node key -> subnet -> address. Only the subnets a node declares appear; an unaddressed subnet yields null."
}

output "vm_name" {
  value       = local.vm_name
  description = "Node key -> guest hostname (\"<shortname>-benchmark-NN\"). A cross-provider contract; deployment overlays reference these literally."
}

output "named_routes" {
  value       = local.named_routes
  description = "Route name -> { to, via }. `via` is null when the next hop did not resolve, which unresolved_named_routes reports."
}

output "unresolved_named_routes" {
  value       = local.unresolved_named_routes
  description = "Human-readable descriptions of named routes whose next hop does not resolve. Empty means every declared route is satisfiable. Callers assert on this."
}

output "nodes_by_prole" {
  value       = local.nodes_by_prole
  description = "Provider role -> sorted node keys, so selection is stable across plans."
}

output "spec_role_for" {
  value       = local.spec_role_for
  description = "Provider role -> spec role, for error messages that name what the author actually wrote."
}

output "ip_offset" {
  value       = local.ip_offset
  description = "Provider role -> first host offset of its address block. Exposed for diagnostics and tests rather than for rendering."
}

output "all_addresses" {
  value       = local.all_addresses
  description = "Every address any node holds, on any subnet. Used to assert that no address is issued twice and that every named-route next hop is actually held by a node."
}

output "disk_gb" {
  value       = local.disk_gb
  description = "Node key -> disk GiB. Spec value, else the per-role pin, else the size-class default."
}
