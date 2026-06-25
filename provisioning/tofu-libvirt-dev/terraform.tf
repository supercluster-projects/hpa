terraform {
  required_version = ">= 1.9"

  required_providers {
    libvirt = {
      source  = "registry.terraform.io/dmacvicar/libvirt"
      version = "~> 0.8"
    }
    talos = {
      source  = "registry.opentofu.org/siderolabs/talos"
      version = "~> 0.6"
    }
  }
}
