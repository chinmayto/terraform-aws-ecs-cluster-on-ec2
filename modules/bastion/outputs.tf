output "bastion_host_public_ip" {
  value = aws_instance.web.public_ip
}