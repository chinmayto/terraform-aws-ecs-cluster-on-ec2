variable "aws_region" {}
variable "common_tags" {}
variable "naming_prefix" {}
variable "instance_type" {}
variable "instance_key" {}
variable "private_subnets" {}
variable "vpc_id" {}
variable "alb_security_group_id" {}
variable "bastion_security_group_id" {}
variable "private_route_table_id" {}
variable "sg_ingress_ports" {
  type = list(object({
    description = string
    port        = number
  }))
  default = [
    {
      description = "Allows SSH access"
      port        = 22
    },
    {
      description = "Allows HTTP traffic"
      port        = 80
    },
  ]
}
