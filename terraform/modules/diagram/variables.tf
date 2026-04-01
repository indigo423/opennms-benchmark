variable "subnet_mgmt" {
  type        = string
  description = "Management subnet CIDR (e.g. 192.0.2.192/26)"
}

variable "subnet_db" {
  type        = string
  description = "Database subnet CIDR (e.g. 192.0.2.0/26)"
}

variable "subnet_kafka" {
  type        = string
  description = "Kafka subnet CIDR (e.g. 192.0.2.64/26)"
}

variable "subnet_sim" {
  type        = string
  description = "SNMP simulation subnet CIDR (e.g. 192.0.2.128/26)"
}

# Management IPs
variable "ip_monitoring" { type = string }
variable "ip_database" { type = string }
variable "ip_core" { type = string }
variable "ip_kafka" { type = string }
variable "ip_minion" { type = string }
variable "ip_netsim" { type = string }
variable "ip_elasticsearch" { type = string }

# Per-subnet IPs
variable "ip_database_db" { type = string }
variable "ip_core_db" { type = string }
variable "ip_es_core" { type = string }
variable "ip_kafka_kafka" { type = string }
variable "ip_core_kafka" { type = string }
variable "ip_minion_kafka" { type = string }
variable "ip_minion_sim" { type = string }
variable "ip_netsim_sim" { type = string }

# VM names map (keys: monitoring, database, core, kafka, minion, netsim, elasticsearch)
variable "vm_names" {
  type = map(string)
}
