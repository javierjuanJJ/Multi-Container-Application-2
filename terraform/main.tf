terraform {
  required_version = ">= 1.5"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "digitalocean" {
  token = var.do_token
}

resource "digitalocean_ssh_key" "this" {
  count = var.ssh_key_fingerprint == null ? 1 : 0

  name       = var.ssh_key_name
  public_key = try(file(pathexpand(var.ssh_public_key_path)), "")
}

locals {
  use_existing_ssh_key = var.ssh_key_fingerprint != null

  droplet_ssh_keys = local.use_existing_ssh_key ? [var.ssh_key_fingerprint] : [digitalocean_ssh_key.this[0].id]
}

resource "digitalocean_droplet" "web" {
  name       = var.droplet_name
  region     = var.droplet_region
  size       = var.droplet_size
  image      = var.droplet_image
  ssh_keys   = local.droplet_ssh_keys
  tags       = var.droplet_tags
  ipv6       = var.droplet_ipv6
  monitoring = var.droplet_monitoring
  backups    = var.droplet_backups

  lifecycle {
    create_before_destroy = true
  }
}

# Cloud Firewall: solo se expone SSH (para terraform/ansible y el runner de CI) y
# HTTP/HTTPS (para el reverse proxy de nginx). MongoDB nunca se publica: la API
# se comunica con el por la red interna de docker compose.
resource "digitalocean_firewall" "web" {
  name        = "${var.droplet_name}-fw"
  droplet_ids = [digitalocean_droplet.web.id]

  dynamic "inbound_rule" {
    for_each = var.allowed_ssh_ips

    content {
      protocol              = "tcp"
      port_range            = "22"
      source_addresses      = [inbound_rule.value]
      source_tags           = []
      destination_addresses = []
      destination_ports     = ""
    }
  }

  dynamic "inbound_rule" {
    for_each = var.open_web_ports ? [1] : []

    content {
      protocol              = "tcp"
      port_range            = "80"
      source_addresses      = ["0.0.0.0/0", "::/0"]
      source_tags           = []
      destination_addresses = []
      destination_ports     = ""
    }
  }

  dynamic "inbound_rule" {
    for_each = var.open_web_ports ? [1] : []

    content {
      protocol              = "tcp"
      port_range            = "443"
      source_addresses      = ["0.0.0.0/0", "::/0"]
      source_tags           = []
      destination_addresses = []
      destination_ports     = ""
    }
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "22"
    destination_addresses = ["0.0.0.0/0", "::/0"]
    destination_ports     = ""
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "80"
    destination_addresses = ["0.0.0.0/0", "::/0"]
    destination_ports     = ""
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "443"
    destination_addresses = ["0.0.0.0/0", "::/0"]
    destination_ports     = ""
  }

  # DNS de DigitalOcean: necesario para resolver los nombres y sacar imagenes.
  outbound_rule {
    protocol              = "udp"
    port_range            = "53"
    destination_addresses = ["0.0.0.0/0", "::/0"]
    destination_ports     = ""
  }
}

# Bonus: registro DNS A para el dominio, apuntando al Droplet (http://your_domain.com).
resource "digitalocean_domain_record" "app" {
  count = var.domain_name == null ? 0 : 1

  domain = var.domain_name
  type   = var.domain_record_type
  name   = var.domain_record_name
  value  = digitalocean_droplet.web.ipv4_address
  ttl    = 1800
  weight = 0
}
