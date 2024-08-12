####################################################
# Create an IAM role - ecsInstanceRole  
####################################################
data "aws_iam_policy" "ecsInstanceRolePolicy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}
data "aws_iam_policy_document" "ecsInstanceRolePolicy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "ecsInstanceRole" {
  name               = "ecsInstanceRole"
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.ecsInstanceRolePolicy.json
}
resource "aws_iam_role_policy_attachment" "ecsInstancePolicy" {
  role       = aws_iam_role.ecsInstanceRole.name
  policy_arn = data.aws_iam_policy.ecsInstanceRolePolicy.arn
}
resource "aws_iam_instance_profile" "ecsInstanceRoleProfile" {
  name = aws_iam_role.ecsInstanceRole.name
  role = aws_iam_role.ecsInstanceRole.name
}

####################################################
# Get latest Amazon Linux 2 AMI
####################################################
data "aws_ami" "amazon-linux-2" {
  most_recent = true

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "owner-alias"
    values = ["amazon"]
  }

  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-hvm-*-x86_64-ebs"]
  }

  owners = ["amazon"]
}

####################################################
# Create the security group for EC2
####################################################
resource "aws_security_group" "security_group_ec2" {
  description = "Allow traffic for EC2"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Allow ingress traffic from ALB on HTTP on ephemeral ports"
    from_port       = 1024
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
  }

  ingress {
    description     = "Allow SSH ingress traffic from bastion host"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [var.bastion_security_group_id]
  }

  egress {
    description = "Allow all egress traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-sg-ec2"
  })
}

####################################################
# Create Launch Template Resource
####################################################
resource "aws_launch_template" "ecs-launch-template" {
  image_id               = data.aws_ami.amazon-linux-2.id
  instance_type          = var.instance_type
  key_name               = var.instance_key
  vpc_security_group_ids = [aws_security_group.security_group_ec2.id]
  update_default_version = true

  private_dns_name_options {
    enable_resource_name_dns_a_record = false
  }

  iam_instance_profile {
    name = aws_iam_role.ecsInstanceRole.name
  }

  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 30
      volume_type = "gp2"
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.common_tags, {
      Name = "${var.naming_prefix}-ECS-Instance"
    })
  }

  user_data = filebase64("${path.module}/ecs.sh")
}

####################################################
# Create auto scaling group
####################################################
resource "aws_autoscaling_group" "aws-autoscaling-group" {
  name                  = "${var.naming_prefix}-ASG"
  vpc_zone_identifier   = tolist(var.private_subnets)
  desired_capacity      = 2
  max_size              = 6
  min_size              = 1
  health_check_type     = "EC2"
  protect_from_scale_in = true

  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupStandbyInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances"
  ]

  launch_template {
    id      = aws_launch_template.ecs-launch-template.id
    version = aws_launch_template.ecs-launch-template.latest_version
  }

  instance_refresh {
    strategy = "Rolling"
  }
  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }
}


####################################################
# Create VPC Endpoints for following Services
# com.amazonaws.${var.aws_region}.ecs-agent     - VPC Interface Endpoint  
# com.amazonaws.${var.aws_region}.ecs-telemetry - VPC Interface Endpoint
# com.amazonaws.${var.aws_region}.ecs           - VPC Interface Endpoint
# com.amazonaws.${var.aws_region}.ecr.dkr       - VPC Interface Endpoint
# com.amazonaws.${var.aws_region}.ecr.api       - VPC Interface Endpoint
# com.amazonaws.${var.aws_region}.logs          - VPC Interface Endpoint
# com.amazonaws.${var.aws_region}.s3            - VPC Gateway Endpoint
####################################################
locals {
  endpoint_list = ["com.amazonaws.${var.aws_region}.ecs-agent",
    "com.amazonaws.${var.aws_region}.ecs-telemetry",
    "com.amazonaws.${var.aws_region}.ecs",
    "com.amazonaws.${var.aws_region}.ecr.dkr",
    "com.amazonaws.${var.aws_region}.ecr.api",
    "com.amazonaws.${var.aws_region}.logs",
  ]
}

####################################################
# Create the security group for VPC Endpoints
####################################################
resource "aws_security_group" "security_group_endpoints" {
  description = "Allow traffic for VPC Endpoints"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Allow ingress traffic from EC2 Hosts"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.security_group_ec2.id]
  }

  egress {
    description = "Allow all egress traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-sg-vpc-endpoints"
  })
}

####################################################
# Create the VPC endpoints
####################################################
resource "aws_vpc_endpoint" "vpc_endpoint" {
  count               = 6
  vpc_id              = var.vpc_id
  vpc_endpoint_type   = "Interface"
  service_name        = local.endpoint_list[count.index]
  subnet_ids          = var.private_subnets[*]
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.security_group_endpoints.id]

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-Endpoint-${local.endpoint_list[count.index]}"
  })
}

####################################################
# Create VPC Gateway Endpoint for S3
####################################################
resource "aws_vpc_endpoint" "vpc_endpoint_s3" {
  vpc_id            = var.vpc_id
  vpc_endpoint_type = "Gateway"
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  route_table_ids   = [var.private_route_table_id]

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-Endpoint-com.amazonaws.${var.aws_region}.s3"
  })
}