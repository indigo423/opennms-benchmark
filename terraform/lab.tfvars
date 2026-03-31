# Shared lab variables — provider-agnostic
# These values are load-bearing across Ansible inventory, OpenNMS config,
# and Prometheus scrape targets. Do not make them per-provider variables.

# Network — RFC 5737 TEST-NET-3, non-routable by internet standards
lab_cidr     = "192.0.2.0/24"
subnet_db    = "192.0.2.0/26"
subnet_kafka = "192.0.2.64/26"
subnet_sim   = "192.0.2.128/26"
subnet_mgmt  = "192.0.2.192/26"

# Management IPs (subnet-mgmt) — used by Ansible, Prometheus, operator SSH
ip_database   = "192.0.2.196"
ip_core       = "192.0.2.197"
ip_kafka      = "192.0.2.198"
ip_minion     = "192.0.2.199"
ip_monitoring = "192.0.2.200"
ip_netsim          = "192.0.2.201"
ip_elasticsearch   = "192.0.2.202"

# Internal IPs per subnet
ip_database_db  = "192.0.2.4"
ip_core_db      = "192.0.2.5"
ip_kafka_kafka  = "192.0.2.68"
ip_core_kafka   = "192.0.2.69"
ip_minion_kafka = "192.0.2.70"
ip_minion_sim   = "192.0.2.133"
ip_netsim_sim   = "192.0.2.134"
ip_es_core      = "192.0.2.6"

# SNMP simulation network — routed via netsim VM
net_sim_cidr    = "10.42.0.0/16"
net_sim_gateway = "192.0.2.134"

# VM names
vm_names = {
  database   = "db-benchmark-01"
  core       = "core-benchmark-01"
  kafka      = "kafka-benchmark-01"
  minion     = "minion-benchmark-01"
  netsim     = "netsim-benchmark-01"
  monitoring    = "mon-benchmark-01"
  elasticsearch = "es-benchmark-01"
}

# Admin username
admin_user = "azureuser"
