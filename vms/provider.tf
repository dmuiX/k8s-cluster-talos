terraform {
  required_version = ">= 0.13"
  cloud {
    organization = "dmuiX"
    workspaces {
      name = "k8s-cluster-talos"
    }   
  }
  required_providers {
    cloudflare = { 
      source  = "cloudflare/cloudflare"
      version = "~> 5"
    }   
    libvirt = { 
      source  = "dmacvicar/libvirt"
      version = "~>0.8.3"
    }

  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "libvirt" {
  uri = var.libvirt_uri
}
