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
  name      = "lab-db"
  autostart = true

  ips = [
    {
      address = cidrhost(var.subnet_db, 1)
      netmask = cidrnetmask(var.subnet_db)
    }
  ]
}

resource "libvirt_network" "kafka" {
  name      = "lab-kafka"
  autostart = true

  ips = [
    {
      address = cidrhost(var.subnet_kafka, 1)
      netmask = cidrnetmask(var.subnet_kafka)
    }
  ]
}

resource "libvirt_network" "sim" {
  name      = "lab-sim"
  autostart = true

  ips = [
    {
      address = cidrhost(var.subnet_sim, 1)
      netmask = cidrnetmask(var.subnet_sim)
    }
  ]
}

resource "libvirt_network" "mgmt" {
  name      = "lab-mgmt"
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
  name      = "lab-external"
  autostart = true

  forward = {
    mode = "bridge"
  }

  bridge = {
    name = var.bridge_name
  }
}
