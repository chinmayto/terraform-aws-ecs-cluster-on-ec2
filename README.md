# A comprehensive guide for Amazon ECS with EC2 Launch Type using Terraform

In this post, we will explore how to create an ECS cluster with the EC2 launch type using Terraform. The EC2 launch type offers much more flexibility compared to the Fargate launch type but comes with higher operational overhead. Let's dive into the details, starting with an overview of the architecture and then breaking down each step of the implementation.

### ECS Launch Types
Amazon ECS (Elastic Container Service) supports multiple launch types, primarily EC2 and Fargate:

**EC2 Launch Type:** With EC2, you have full control over the infrastructure, including the ability to select the instance types, control scaling policies, and manage the underlying EC2 instances. This launch type offers more customization and flexibility but requires more operational effort to manage the infrastructure. 
ECS EC2 is ideal for those needing more control over the infrastructure, with the ability to customize instances, manage scaling, and optimize costs. It’s suitable for applications that require specific configurations or persistent resources.

**Fargate Launch Type:** Fargate is a serverless option that abstracts away the underlying infrastructure, allowing you to focus on managing your containers without worrying about the EC2 instances. It simplifies operations but provides less control over the environment.
ECS Fargate is best for teams looking for simplicity, reduced operational overhead, and pay-as-you-go pricing. It’s perfect for microservices and ephemeral workloads.

## Architecture Overview:
Before we get started, let's take a quick look at the architecture we'll be working with:

![alt text](/images/architecture.png)

ECS Launch Types:
![alt text](/images/ecs_launch_type.png)

## Step 1: VPC with Public and Private Subnets: 
We'll create a VPC with two public and two private subnets across two Availability Zones (AZs). The public subnets will host the bastion 
host, and the private subnets will host the ECS cluster and other resources.

```terraform
####################################################
# Get list of available AZs
####################################################
data "aws_availability_zones" "available_zones" {
  state = "available"
}

####################################################
# Create the VPC
####################################################
resource "aws_vpc" "app_vpc" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_hostnames = var.enable_dns_hostnames

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-${var.name}"
  })
}

####################################################
# Create the internet gateway
####################################################
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.app_vpc.id

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-igw"
  })
}

####################################################
# Create the public subnets
####################################################
resource "aws_subnet" "public_subnets" {
  vpc_id = aws_vpc.app_vpc.id

  count             = 2
  cidr_block        = cidrsubnet(var.vpc_cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available_zones.names[count.index]

  map_public_ip_on_launch = true # This makes public subnet

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-pubsubnet-${count.index + 1}"
  })
}

####################################################
# Create the private subnets
####################################################
resource "aws_subnet" "private_subnets" {
  vpc_id = aws_vpc.app_vpc.id

  count             = 2
  cidr_block        = cidrsubnet(var.vpc_cidr_block, 8, 2 + count.index)
  availability_zone = data.aws_availability_zones.available_zones.names[count.index]

  map_public_ip_on_launch = false # This makes private subnet

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-privsubnet-${count.index + 1}"
  })
}

####################################################
# Create the public route table
####################################################
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.app_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-pub-rtable"
  })

}

####################################################
# Assign the public route table to the public subnet
####################################################
resource "aws_route_table_association" "public_rt_asso" {
  count          = 2
  subnet_id      = element(aws_subnet.public_subnets[*].id, count.index)
  route_table_id = aws_route_table.public_route_table.id
}

####################################################
# Set default route table as private route table
####################################################
resource "aws_default_route_table" "private_route_table" {
  default_route_table_id = aws_vpc.app_vpc.default_route_table_id
  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-priv-rtable"
  })
}

####################################################
# Assign the private route table to the private subnet
####################################################
resource "aws_route_table_association" "private_rt_asso" {
  count          = 2
  subnet_id      = element(aws_subnet.private_subnets[*].id, count.index)
  route_table_id = aws_default_route_table.private_route_table.id
}
```

## Step 2: Bastion Host: 
A bastion host in the public subnet serves as a secure gateway to access instances in the private subnet. It is helpful for debugging containers that do not start correctly (No need to host a website as stated below!!).

```terraform
####################################################
# Get latest Amazon Linux 2 AMI
####################################################
data "aws_ami" "amazon-linux-2" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm*"]
  }
}

####################################################
# Create the security group for EC2
####################################################
resource "aws_security_group" "bastion_security_group" {
  description = "Allow traffic for EC2 Bastion Host"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.sg_ingress_ports
    iterator = sg_ingress

    content {
      description = sg_ingress.value["description"]
      from_port   = sg_ingress.value["port"]
      to_port     = sg_ingress.value["port"]
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-sg-bastion"
  })
}


####################################################
# Create the Linux EC2 instance with a website
####################################################
resource "aws_instance" "web" {
  ami                    = data.aws_ami.amazon-linux-2.id
  instance_type          = var.instance_type
  key_name               = var.instance_key
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.bastion_security_group.id]

  user_data = <<-EOF
  #!/bin/bash
  yum update -y
  yum install -y httpd.x86_64
  systemctl start httpd.service
  systemctl enable httpd.service
  instanceId=$(curl http://169.254.169.254/latest/meta-data/instance-id)
  instanceAZ=$(curl http://169.254.169.254/latest/meta-data/placement/availability-zone)
  pubHostName=$(curl http://169.254.169.254/latest/meta-data/public-hostname)
  pubIPv4=$(curl http://169.254.169.254/latest/meta-data/public-ipv4)
  privHostName=$(curl http://169.254.169.254/latest/meta-data/local-hostname)
  privIPv4=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
  
  echo "<font face = "Verdana" size = "5">"                               > /var/www/html/index.html
  echo "<center><h1>Bastion Host Deployed with Terraform</h1></center>"   >> /var/www/html/index.html
  echo "<center> <b>EC2 Instance Metadata</b> </center>"                  >> /var/www/html/index.html
  echo "<center> <b>Instance ID:</b> $instanceId </center>"               >> /var/www/html/index.html
  echo "<center> <b>AWS Availablity Zone:</b> $instanceAZ </center>"      >> /var/www/html/index.html
  echo "<center> <b>Public Hostname:</b> $pubHostName </center>"          >> /var/www/html/index.html
  echo "<center> <b>Public IPv4:</b> $pubIPv4 </center>"                  >> /var/www/html/index.html
  echo "<center> <b>Private Hostname:</b> $privHostName </center>"        >> /var/www/html/index.html
  echo "<center> <b>Private IPv4:</b> $privIPv4 </center>"                >> /var/www/html/index.html
  echo "</font>"                                                          >> /var/www/html/index.html
EOF

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-ec2-${var.ec2_name}"
  })
}
```

## Step 3: Compute Layer on EC2: 
We'll create an EC2 launch template with an ECS-optimized AMI. Configure `ecs.config` file to have name of ECS cluster it will be part of. The EC2 instances will be part of an Auto Scaling group (ASG) that has tag `AmazonECSManaged` and has enabled metrics for autoscaling.
Create a role `ecsInstanceRole` to grant permissions.

IAM Role `ecsInstanceRole` with policy `AmazonEC2ContainerServiceforEC2Role`
```terraform
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
```
Create security group allowing ingress traffic from ALB on ephermal ports and from Bastion Host on SSH port 22
```terraform
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
```

Get latest ECS Optimized AMI and define launch template
```terraform
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
```
We will use userdata as above to update ecs.config with ECS Cluster name:
```terraform
#!/bin/bash
echo ECS_CLUSTER=my-ecs-cluster >> /etc/ecs/ecs.config
```

Next, create ASG with metrics enabled and with tag `AmazonECSManaged`. The `instance_refresh` block allows us to configure the warmup time for new EC2 instances to reduce too long startup times. `enabled_metrics` defines which metrics the ASG should provide and available in CloudWatch. `protect_from_scale_in` must be set to true because we have enabled `managed_termination_protection` in the capacity provider.

```terraform
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
```

## Step 4: Custom Endpoints for Private Subnet Services: 
Since the ECS cluster will reside in a private subnet, we'll create VPC interface endpoints for services like `ecs-agent`, `ecs-telemetry`, `ecs`, `ecr.dkr`, `ecr.api`, `logs`, and a VPC gateway endpoint for `S3`. VPC interface endpoints are placed in separate security group allowing ingress traffic from EC2 host instances security group over port 443, this will allow accessing ECR over private network.

```terraform
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
```

## Step 5: Create the ECS Cluster
We'll create the ECS cluster, define the task execution role, and configure the ECS service with an ordered placement strategy and constraints.

IAM Role `ecsTaskExecutionRole` with policy `AmazonECSTaskExecutionRolePolicy`
```terraform
####################################################
# Create an IAM role - ecsTaskExecutionRole  
####################################################
data "aws_iam_policy" "ecsTaskExecutionRolePolicy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
data "aws_iam_policy_document" "ecsExecutionRolePolicy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "ecsTaskExecutionRole"
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.ecsExecutionRolePolicy.json
}
resource "aws_iam_role_policy_attachment" "ecsTaskExecutionPolicy" {
  role       = aws_iam_role.ecsTaskExecutionRole.name
  policy_arn = data.aws_iam_policy.ecsTaskExecutionRolePolicy.arn
}
```
Create an ECS cluster with cluster capacity provider as autoscaling group. Here, `maximum_scaling_step_size` and `minimum_scaling_step_size` define by how many EC2 Instances the capacity provider may simultaneously increase or decrease the number of Container Instances during a scale-out or scale-in. `managed_termination_protection` prevents EC2 Instances on which other tasks are running from being terminated.
```terraform
####################################################
# Create an ECS cluster
####################################################
resource "aws_ecs_cluster" "ecs_cluster" {
  name = var.ecs_cluster_name

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-ecs-cluster"
  })
}

####################################################
# Create an ECS capacity Provider
####################################################
resource "aws_ecs_capacity_provider" "ecs_capacity_provider" {
  name = "capacity_provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = var.auto_scaling_group_arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      maximum_scaling_step_size = 5
      minimum_scaling_step_size = 1
      status                    = "ENABLED"
      target_capacity           = 100
    }
  }
}

####################################################
# Create an ECS Cluster capacity Provider
####################################################
resource "aws_ecs_cluster_capacity_providers" "ecs_cluster_capacity_provider" {
  cluster_name       = aws_ecs_cluster.ecs_cluster.name
  capacity_providers = [aws_ecs_capacity_provider.ecs_capacity_provider.name]
}
```

Create cloudwatch log group for logging purposes:
```terraform
####################################################
# Create cloudWatch Log Group
####################################################
resource "aws_cloudwatch_log_group" "log" {
  name              = "/${var.ecs_cluster_name}/simplenodejsapp"
  retention_in_days = 14
}
```

Create a task definition which specifies the docker image to use from private ECR repository (Refer resources section to understand how to push image to private ECR repo). Container port is the port where container service is listenening and host port is the port on the host (EC2 instance) that maps to the container port. We also define `cpu` and `memory` required for each container along with log configuration for cloudwatch logs.

We have used `bridge` networking mode so that the task uses Docker's built-in virtual network on Linux, which runs inside each Amazon EC2 instance that hosts the task. Other networking mode is `awsvpc` where the task is allocated its own elastic network interface (ENI) and a primary private IPv4 address. This gives the task the same networking properties as Amazon EC2 instances but limits to the numer of ENIs that can be attached to host EC2 instance. Other modes are `host` and `none`.

```terraform
####################################################
# Create an ECS Task Definition
####################################################
resource "aws_ecs_task_definition" "ecs_task_definition" {
  family             = "my-ecs-task"
  network_mode       = "bridge"
  execution_role_arn = aws_iam_role.ecsTaskExecutionRole.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "simple-nodejs-app"
      image     = "197317184204.dkr.ecr.us-east-1.amazonaws.com/simple-nodejs-app"
      cpu       = 200
      memory    = 200
      essential = true
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 0
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.log.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "simplenodejsapp"
        }
      }
    }
  ])
}
```

Now we create an ECS services which will run the above task. `desired_count` defines the number of containers running. Placement Strategy defines how tasks are distributed across cluster, we have used `spread` to spread tasks across AZs and then `binpack` to place task on host with least available memory. Task placement constraints allow you to control task placement by specifying rules that the tasks must satisfy to be placed on an instance. Use `DistinctInstance` constraint which ensures that each task is placed on a separate instance and `MemberOf` which ensures placement to instances that meet specific criteria like attribute or AZ or isntance type etc.

```terraform
####################################################
# Define the ECS service that will run the task
####################################################
resource "aws_ecs_service" "ecs_service" {
  name                               = "my-ecs-service"
  cluster                            = aws_ecs_cluster.ecs_cluster.id
  task_definition                    = aws_ecs_task_definition.ecs_task_definition.arn
  desired_count                      = 4
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 100

  ## Spread tasks evenly accross all Availability Zones for High Availability
  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  ## Make use of all available space on the Container Instances
  ordered_placement_strategy {
    type  = "binpack"
    field = "memory"
  }

  triggers = {
    redeployment = timestamp()
  }

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ecs_capacity_provider.name
    weight            = 100
  }

  load_balancer {
    target_group_arn = var.alb_target_group_arn
    container_name   = "simple-nodejs-app"
    container_port   = 8080
  }
}
```

Service Autoscaling handles elastic scaling of containers (ECS Tasks) and also works in our setup using Target Tracking for CPU and memory usage. We define the minimum and maximum number of tasks that may run simultaneously to keep costs under control despite scalability. `min_capacity` is set to at least 2 in our setup for ensuring High Availability. Since we configured aws_ecs_service with the spread Placement Strategy, this ensures that each of the two tasks runs in a different AZs. We use `ECSServiceAverageCPUUtilization` and `ECSServiceAverageMemoryUtilization` as metrics, whose data decides whether a scale-out or scale-in should be triggered.

```terraform
####################################################
# Define the ECS service auto scaling
####################################################
resource "aws_appautoscaling_target" "ecs_target" {
  max_capacity       = 50
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.ecs_cluster.name}/${aws_ecs_service.ecs_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_policy_memory" {
  name               = "${var.naming_prefix}-memory-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }

    target_value = 80
  }
}

resource "aws_appautoscaling_policy" "ecs_policy_cpu" {
  name               = "${var.naming_prefix}-cpu-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value = 80
  }
}
```

## Step 6: Create an Application Load Balancer:
Finally, we'll set up an Application Load Balancer (ALB) to distribute traffic to the ECS tasks.

```terraform
####################################################
# Define the security group for the Load Balancer
####################################################
resource "aws_security_group" "aws-sg-load-balancer" {
  description = "Allow incoming connections for load balancer"
  vpc_id      = var.vpc_id
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow incoming HTTP connections"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-sg-alb"
  })
}

####################################################
# create application load balancer
####################################################
resource "aws_lb" "aws-application_load_balancer" {
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.aws-sg-load-balancer.id]
  subnets                    = tolist(var.public_subnets)
  enable_deletion_protection = false

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-alb"
  })
}
####################################################
# create target group for ALB
####################################################
resource "aws_alb_target_group" "alb_target_group" {
  target_type = "instance"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id

  health_check {
    healthy_threshold   = "2"
    unhealthy_threshold = "2"
    interval            = "60"
    path                = "/"
    timeout             = 30
    matcher             = 200
    protocol            = "HTTP"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-alb-tg"
  })
}

####################################################
# create a listener on port 80 with redirect action
####################################################
resource "aws_lb_listener" "alb_http_listener" {
  load_balancer_arn = aws_lb.aws-application_load_balancer.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_alb_target_group.alb_target_group.arn

  }
}
```
## Steps to Run Terraform
Follow these steps to execute the Terraform configuration:
```terraform
terraform init
terraform plan 
terraform apply -auto-approve
```
Upon successful completion, Terraform will provide relevant outputs.
```terraform
Apply complete! Resources: 43 added, 0 changed, 0 destroyed.

Outputs:

alb_dns_name = "http://tf-lb-2024081215564351970000000c-1465428058.us-east-1.elb.amazonaws.com"
bastion_host_public_ip = "http://44.206.238.212"
```
## Testing
ECS cluster with desired tasks
![alt text](/images/ecs_cluster.png)

ECS Cluster tasks
![alt text](/images/ecs_cluster_tasks.png)

ECS Capacity Provider as ASG
![alt text](/images/ecs_capacity_provider.png)

ECS Service
![alt text](/images/ecs_service.png)

EC2 Hosts running containers
![alt text](/images/ec2_hosts.png)

Running container service
![alt text](/images/running_container.png)

Service updated to run 40 containers to see service autoscaling:

![alt text](/images/update_service_scaleout.png)

Scaling out EC2 Hosts running containers
![alt text](/images/ec2_hosts_scaleout.png)

ECS Service Health and Metrics
![alt text](/images/ecs_service_health.png)

Accessing EC2 host from bastion host to see running containers
![alt text](/images/containers_list.png)


## Cleanup
Remember to stop AWS components to avoid large bills. You might need to stop the EC2 instances manually because we have enabled terminal protection.
```terraform
terraform destroy -auto-approve
```
## Conclusion
In this post, we've successfully implemented an ECS cluster with the EC2 launch type using Terraform. This setup provides a flexible and scalable environment for running containerized applications. By following these steps, you can take advantage of the control and customization offered by the EC2 launch type.

## Resources
AWS ECS Developer Guide: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/Welcome.html

AWS ECS Task Networking Mode: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-networking.html

AWS ECS task placement strategy: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-placement-strategies.html

AWS ECS task placement constraints: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-placement-constraints.html

Pushing Docker Image to private ECR: https://dev.to/chinmay13/how-to-push-docker-image-to-public-and-private-aws-ecr-repository-56k5

Accessing ECR via VPC Endpoints: https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html

Github Repo: https://github.com/chinmayto/terraform-aws-ecs-cluster-on-ec2