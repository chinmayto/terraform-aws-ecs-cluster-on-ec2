
output "alb_dns_name" {
  value = aws_lb.aws-application_load_balancer.dns_name
}


output "alb_security_group_id" {
  value = aws_security_group.aws-sg-load-balancer.id
}


output "alb_target_group_arn" {
  value = aws_alb_target_group.alb_target_group.arn
}


output "auto_scaling_group_id" {
  value = aws_alb_target_group.alb_target_group.id
}