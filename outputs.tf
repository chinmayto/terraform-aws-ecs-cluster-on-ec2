output "alb_dns_name" {
  value = "http://${module.alb.alb_dns_name}"
}

output "bastion_host_public_ip" {
  value = "http://${module.bastion_host.bastion_host_public_ip}"
}

