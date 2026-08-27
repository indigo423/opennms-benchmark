variable "spec" {
  type        = any
  description = <<-EOT
    The decoded deployments/<slug>/topology.yml. Passed in already decoded
    rather than read here: file() resolves against path.root, so a module
    reading it would resolve relative to the caller anyway, and passing the
    value keeps this module free of filesystem assumptions.
  EOT
}

variable "subnet_cidr" {
  type        = map(string)
  description = <<-EOT
    Subnet name -> CIDR, for the subnets that carry allocated addresses.

    Subnets absent from this map are still valid in a spec; they simply get no
    allocated address (see `unaddressed_subnets`). That is how `external` and
    `lab` work: DHCP, or an address the spec pins itself.
  EOT
}

variable "unaddressed_subnets" {
  type        = list(string)
  default     = ["external", "lab"]
  description = "Subnets that never receive an allocated address. A node on one gets null unless the spec pins an address for it."
}

variable "named_route_spec" {
  type = map(object({
    to     = string
    role   = string
    subnet = string
  }))
  default     = {}
  description = <<-EOT
    Shared routes a spec may reference by name, each declaring the provider role
    and subnet its next hop is taken from.

    Derived rather than declared, deliberately: a hardcoded next hop drifted the
    moment the allocation scheme changed, leaving every minion routing the
    simulated network at an address no node held, silently (#171).
  EOT
}

# ── cross-provider contracts ─────────────────────────────────────────────────
#
# These were byte-identical in terraform/kvm and terraform/aws before this
# module existed. They are defaulted here so a provider gets them by consuming
# the module rather than by copying them, which is the drift this module is for.

variable "provider_role" {
  type        = map(string)
  default     = { loadgen = "netsim" }
  description = "Spec role -> provider role, identity unless remapped. nl6 runs on netsim."
}

variable "role_shortname" {
  type = map(string)
  default = {
    database = "db", core = "core", kafka = "kafka", minion = "minion"
    netsim   = "netsim", monitoring = "mon", elasticsearch = "es"
    sentinel = "sentinel", mimir = "mimir", victoriametrics = "vm"
    rrd      = "rrd", rustfs = "rustfs"
  }
  description = "Provider role -> VM-name prefix, used to build \"<prefix>-benchmark-NN\"."
}

variable "role_order" {
  type = list(string)
  default = [
    "database", "core", "kafka", "minion", "monitoring", "netsim",
    "elasticsearch", "sentinel", "rrd", "mimir", "victoriametrics",
    "rustfs",
  ]
  description = <<-EOT
    Order that fixes each role's address block. Append only: reordering or
    inserting moves every later role's addresses, on every provider at once.
  EOT
}

variable "role_block_size" {
  type        = number
  default     = 4
  description = <<-EOT
    Addresses reserved per role per subnet, so a role can scale to that many
    nodes without walking into the next role's space.

    The previous scheme packed roles at adjacent offsets, which handed two VMs
    the same address as soon as a role had count > 1. Deployment A could never
    have been provisioned.
  EOT
}

variable "role_block_base" {
  type        = number
  default     = 4
  description = "First host offset used for allocation. 0 is the network address and 1 the mgmt gateway; 2-3 are left spare."
}
