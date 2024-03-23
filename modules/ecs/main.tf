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

####################################################
# Create cloudWatch Log Group
####################################################
resource "aws_cloudwatch_log_group" "log" {
  name              = "/${var.ecs_cluster_name}/simplenodejsapp"
  retention_in_days = 14
}

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
    auto_scaling_group_arn = var.auto_scaling_group_arn

    managed_scaling {
      maximum_scaling_step_size = 1000
      minimum_scaling_step_size = 1
      status                    = "ENABLED"
      target_capacity           = 3
    }
  }
}


####################################################
# Create an ECS Cluster capacity Provider
####################################################
resource "aws_ecs_cluster_capacity_providers" "ecs_cluster_capacity_provider" {
  cluster_name = aws_ecs_cluster.ecs_cluster.name

  capacity_providers = [aws_ecs_capacity_provider.ecs_capacity_provider.name]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = aws_ecs_capacity_provider.ecs_capacity_provider.name
  }
}


####################################################
# Create an ECS Task Definition
####################################################
resource "aws_ecs_task_definition" "ecs_task_definition" {
  family       = "my-ecs-task"
  network_mode = "awsvpc"
  execution_role_arn = aws_iam_role.ecsTaskExecutionRole.arn
  cpu                = 256
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([
    {
      name      = "simple-nodejs-app"
      image     = "197317184204.dkr.ecr.us-east-1.amazonaws.com/simple-nodejs-app"
      cpu       = 256
      memory    = 256
      essential = true
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "simplenodejsapp"
          awslogs-group         = aws_cloudwatch_log_group.log.name
        }
      }
    }
  ])
}


####################################################
# Define the ECS service that will run the task
####################################################
resource "aws_ecs_service" "ecs_service" {
  name            = "my-ecs-service"
  cluster         = aws_ecs_cluster.ecs_cluster.id
  task_definition = aws_ecs_task_definition.ecs_task_definition.arn
  desired_count   = 4

  network_configuration {
    subnets         = tolist(var.private_subnets)
    security_groups = [var.security_group_ec2]
  }

  ordered_placement_strategy {
    type  = "spread"
    field = "instanceId"
  }

  force_new_deployment = true
  /*placement_constraints {
    type = "distinctInstance"
  }
  */
  placement_constraints {
    type       = "memberOf"
    expression = "attribute:ecs.instance-type =~ t3.*"
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

