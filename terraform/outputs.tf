output "droplet_id" {
  description = "ID del Droplet creado."
  value       = digitalocean_droplet.web.id
}

output "droplet_name" {
  description = "Nombre del Droplet creado."
  value       = digitalocean_droplet.web.name
}

output "droplet_region" {
  description = "Region del Droplet creado."
  value       = digitalocean_droplet.web.region
}

output "ipv4_address" {
  description = "IP publica IPv4 del Droplet."
  value       = digitalocean_droplet.web.ipv4_address
}

output "ipv4_address_private" {
  description = "IP privada del Droplet (red interna de DigitalOcean)."
  value       = digitalocean_droplet.web.ipv4_address_private
}

output "ipv6_address" {
  description = "IP publica IPv6 del Droplet."
  value       = digitalocean_droplet.web.ipv6_address
}

output "ssh_command" {
  description = "Comando para conectarse por SSH al Droplet."
  value       = "ssh root@${digitalocean_droplet.web.ipv4_address}"
}

output "ansible_inventory_host" {
  description = "Linea de inventario para el Droplet, lista para pegar en inventory.ini."
  value       = "web-1 ansible_host=${digitalocean_droplet.web.ipv4_address} ansible_user=root"
}

output "firewall_id" {
  description = "ID del Cloud Firewall que protege el Droplet."
  value       = digitalocean_firewall.web.id
}

output "domain_url" {
  description = "URL publica del bonus. Sale vacio si no se definio domain_name."
  value = var.domain_name == null ? null : format(
    "http://%s%s",
    var.domain_record_name == "@" ? var.domain_name : "${var.domain_record_name}.${var.domain_name}",
    var.domain_record_type == "CNAME" ? "" : "",
  )
}
