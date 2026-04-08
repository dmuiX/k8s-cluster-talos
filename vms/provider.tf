terraform {
  required_version = ">= 1.14"
  required_providers {
    cloudflare = { 
      source  = "cloudflare/cloudflare"
      version = "~> 5.18.0"
    }   
    libvirt = { 
      source  = "dmacvicar/libvirt"
      version = "~>0.9.7"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "libvirt" {
  uri = var.libvirt_uri
}
