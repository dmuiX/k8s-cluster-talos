terraform {
  required_version = ">= 0.13"
  cloud {
    organization = "dmuiX"
    workspaces {
      name = "k8s-cluster-talos"
    }
  }
  required_providers {
    pihole = {
      source  = "ryanwholey/pihole"
      version = "2.0.0-beta.1"
    }
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~>0.8.3"
    }

  }
}

provider "pihole" {
  password = var.pihole_password
  url      = var.pihole_server
}

provider "libvirt" {
  uri = var.libvirt_uri
}
