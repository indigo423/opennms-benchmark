# Shared (from lab.tfvars) — declared for cross-provider tfvars compatibility; not used by this module
variable "lab_cidr" { type = string }
variable "subnet_db" { type = string }
variable "subnet_kafka" { type = string }
variable "subnet_sim" { type = string }
variable "subnet_mgmt" { type = string }
variable "ip_database" { type = string }
variable "ip_core" { type = string }
variable "ip_kafka" { type = string }
variable "ip_minion" { type = string }
variable "ip_netsim" { type = string }
variable "ip_monitoring" { type = string }
variable "ip_database_db" { type = string }
variable "ip_core_db" { type = string }
variable "ip_core_kafka" { type = string }
variable "ip_kafka_kafka" { type = string }
variable "ip_minion_kafka" { type = string }
variable "ip_minion_sim" { type = string }
variable "ip_netsim_sim" { type = string }
variable "net_sim_cidr" { type = string }
variable "net_sim_gateway" { type = string }
variable "admin_user" { type = string }
variable "vm_names" {
  type    = map(string)
  default = null # accepted from lab.tfvars; not used by this module
}
variable "ip_elasticsearch" { type = string }
variable "ip_es_core" { type = string }

# VMware-specific (from vmware.tfvars)
variable "vsphere_server" {
  type        = string
  description = "vCenter Server hostname or IP address"
}

variable "vsphere_user" {
  type        = string
  description = "vCenter user principal (e.g. administrator@vsphere.local)"
}

variable "vsphere_password" {
  type        = string
  sensitive   = true
  description = "vCenter user password"
}

variable "vsphere_insecure" {
  type        = bool
  default     = false
  description = "Skip TLS certificate verification (set true for self-signed certs)"
}

variable "datacenter" {
  type        = string
  description = "vSphere datacenter name"
}

variable "cluster" {
  type        = string
  description = "vSphere cluster or host name"
}

variable "datastore" {
  type        = string
  description = "vSphere datastore for VM disks"
}

variable "template_name" {
  type        = string
  description = "Name of the Ubuntu 24.04 cloud-init template VM to clone from"
}

variable "ssh_key_path" {
  type        = string
  description = "Path to SSH private key (without .pub extension)"
}

# Port group names — pre-existing on a vSwitch or dvSwitch.
# Each corresponds to one lab subnet.
variable "pg_mgmt" {
  type        = string
  description = "Port group for management network (192.0.2.192/26)"
}

variable "pg_db" {
  type        = string
  description = "Port group for database subnet (192.0.2.0/26)"
}

variable "pg_kafka" {
  type        = string
  description = "Port group for Kafka subnet (192.0.2.64/26)"
}

variable "pg_sim" {
  type        = string
  description = "Port group for SNMP simulation subnet (192.0.2.128/26)"
}

variable "pg_ext" {
  type        = string
  description = "Port group with external DHCP access — monitoring VM only; its DHCP address serves as the lab jump host"
}

variable "disk_sizes_gb" {
  type        = map(number)
  description = "Disk size in GB per VM"
  default = {
    database      = 20
    core          = 30
    kafka         = 20
    minion        = 20
    netsim        = 20
    monitoring    = 30
    elasticsearch = 50
  }
}

variable "jump_host" {
  type        = string
  default     = ""
  description = "External IP of the monitoring VM for SSH jump host. Set after first apply."
}
