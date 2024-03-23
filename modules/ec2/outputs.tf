output "ami_id" {
  value = data.aws_ami.amazon-linux-2.id
}

output "auto_scaling_group_arn" {
  value = aws_autoscaling_group.aws-autoscaling-group.arn
}

output "auto_scaling_group_id" {
  value = aws_autoscaling_group.aws-autoscaling-group.id
}
output "security_group_ec2" {
  value = aws_security_group.security_group_ec2.id
}
