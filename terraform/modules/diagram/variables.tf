variable "provider_name" {
  type        = string
  description = "Infrastructure provider name (azure, kvm, proxmox) — used as the assets subdirectory"
}

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
