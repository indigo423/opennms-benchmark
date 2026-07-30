terraform {
  required_version = ">= 1.5"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9.6"
    }
  }
}

# KVM uses 4 isolated bridge networks and one external bridge-backed network.

resource "libvirt_network" "db" {
  name      = "${var.name_prefix}-db"
  autostart = true

  ips = [
    {
      address = cidrhost(var.subnet_db, 1)
      netmask = cidrnetmask(var.subnet_db)
    }
  ]
}

resource "libvirt_network" "kafka" {
  name      = "${var.name_prefix}-kafka"
  autostart = true

  ips = [
    {
      address = cidrhost(var.subnet_kafka, 1)
      netmask = cidrnetmask(var.subnet_kafka)
    }
  ]
}

resource "libvirt_network" "sim" {
  name      = "${var.name_prefix}-sim"
  autostart = true

  ips = [
    {
      address = cidrhost(var.subnet_sim, 1)
      netmask = cidrnetmask(var.subnet_sim)
    }
  ]
}

resource "libvirt_network" "mgmt" {
  name      = "${var.name_prefix}-mgmt"
  autostart = true

  forward = {
    mode = "nat"
  }

  ips = [
    {
      address = cidrhost(var.subnet_mgmt, 1)
      netmask = cidrnetmask(var.subnet_mgmt)
    }
  ]
}

resource "libvirt_network" "external" {
  name      = "${var.name_prefix}-external"
  autostart = true

  forward = {
    mode = "bridge"
  }

  bridge = {
    name = var.bridge_name
  }
}
