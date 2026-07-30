# Shared lab variables — provider-agnostic, read by every provider.
# These values are load-bearing across Ansible inventory, OpenNMS config,
# and Prometheus scrape targets. Do not make them per-provider variables.
#
# Per-host addresses live in lab-addresses.tfvars, which the spec-driven
# providers do not read: they derive every address from the deployment spec.

# Network — RFC 5737 TEST-NET-3, non-routable by internet standards
lab_cidr     = "192.0.2.0/24"
subnet_db    = "192.0.2.0/26"
subnet_kafka = "192.0.2.64/26"
subnet_sim   = "192.0.2.128/26"
subnet_mgmt  = "192.0.2.192/26"

# SNMP simulation network — routed via the netsim node
net_sim_cidr = "10.42.0.0/16"

# Admin username
admin_user = "azureuser"
