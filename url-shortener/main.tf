# URL shortener — infrastructure for the architecture in README.md.
# Provider: AWS. Single region (multi-region is deferred; see the counter note below).
# Component mapping:
#   API Gateway (routing / auth / rate limiting)  -> aws_apigatewayv2_api + JWT authorizer + stage throttling
#   Load balancer                                  -> internal ALB behind a VPC link
#   Read / write services                          -> ECS Fargate services (read scales independently)
#   Lookup cache + ID counter                      -> two ElastiCache Redis replication groups
#   URL store                                      -> RDS Postgres primary + read replicas
# Networking (VPC, subnets) is assumed to exist and is passed in as variables.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------------------
# Variables — everything environment-specific is injected, no hardcoded infra.
# ---------------------------------------------------------------------------

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "vpc_id" {
  type        = string
  description = "Existing VPC to deploy into."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets for the ALB, ECS tasks, cache, and database."
}

variable "service_image" {
  type        = string
  description = "Container image used by both the read and write services (ROLE env var selects behaviour)."
}

variable "read_replica_count" {
  type        = number
  default     = 2
  description = "Postgres read replicas. Reads dominate ~1000:1, so these carry redirect cache-misses."
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "jwt_issuer" {
  type        = string
  description = "OIDC issuer URL for API Gateway JWT auth."
}

variable "jwt_audience" {
  type = list(string)
}

locals {
  name = "url-shortener-${var.environment}"
}

# ---------------------------------------------------------------------------
# Security groups — each tier only accepts traffic from the tier in front of it.
# ---------------------------------------------------------------------------

# ALB is internal; only the API Gateway VPC link reaches it.
resource "aws_security_group" "alb" {
  name   = "${local.name}-alb"
  vpc_id = var.vpc_id

  ingress {
    description     = "HTTP from API Gateway VPC link"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.vpc_link.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "vpc_link" {
  name   = "${local.name}-vpc-link"
  vpc_id = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Services accept traffic only from the ALB.
resource "aws_security_group" "service" {
  name   = "${local.name}-service"
  vpc_id = var.vpc_id

  ingress {
    description     = "App port from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Data stores accept traffic only from the services.
resource "aws_security_group" "data" {
  name   = "${local.name}-data"
  vpc_id = var.vpc_id

  ingress {
    description     = "Redis"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.service.id]
  }

  ingress {
    description     = "Postgres"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.service.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------
# Edge: API Gateway (routing, auth, rate limiting) -> VPC link -> internal ALB
# ---------------------------------------------------------------------------

resource "aws_lb" "internal" {
  name               = "${local.name}-alb"
  internal           = true
  load_balancer_type = "application"
  subnets            = var.private_subnet_ids
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "read" {
  name        = "${local.name}-read"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path = "/health"
  }
}

resource "aws_lb_target_group" "write" {
  name        = "${local.name}-write"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path = "/health"
  }
}

# Default to the read service (redirects are the bulk of traffic);
# route creation (POST /urls) to the write service.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.read.arn
  }
}

resource "aws_lb_listener_rule" "writes" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.write.arn
  }

  condition {
    path_pattern {
      values = ["/urls", "/urls/*"]
    }
  }

  condition {
    http_request_method {
      values = ["POST"]
    }
  }
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${local.name}-link"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = var.private_subnet_ids
}

resource "aws_apigatewayv2_api" "this" {
  name          = local.name
  protocol_type = "HTTP"
}

# JWT auth at the edge — applied to creation only (see routes below).
resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id           = aws_apigatewayv2_api.this.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${local.name}-jwt"

  jwt_configuration {
    issuer   = var.jwt_issuer
    audience = var.jwt_audience
  }
}

resource "aws_apigatewayv2_integration" "alb" {
  api_id             = aws_apigatewayv2_api.this.id
  integration_type   = "HTTP_PROXY"
  integration_uri    = aws_lb_listener.http.arn
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.this.id
}

# Redirects are public; creating a short URL requires auth.
resource "aws_apigatewayv2_route" "redirect" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /{short_code}"
  target    = "integrations/${aws_apigatewayv2_integration.alb.id}"
}

resource "aws_apigatewayv2_route" "create" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "POST /urls"
  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
}

# Stage-level throttling = the gateway's rate limiting.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 5000
    throttling_rate_limit  = 10000
  }
}

# ---------------------------------------------------------------------------
# Compute: ECS Fargate, separate read and write services
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = local.name
}

resource "aws_iam_role" "task_execution" {
  name = "${local.name}-task-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Same image, two task definitions: the ROLE env var selects read vs write behaviour.
resource "aws_ecs_task_definition" "read" {
  family                   = "${local.name}-read"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.task_execution.arn

  container_definitions = jsonencode([{
    name         = "app"
    image        = var.service_image
    portMappings = [{ containerPort = 8080 }]
    environment  = [{ name = "ROLE", value = "read" }]
  }])
}

resource "aws_ecs_task_definition" "write" {
  family                   = "${local.name}-write"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.task_execution.arn

  container_definitions = jsonencode([{
    name         = "app"
    image        = var.service_image
    portMappings = [{ containerPort = 8080 }]
    environment  = [{ name = "ROLE", value = "write" }]
  }])
}

# Read service is large and autoscaled — it absorbs redirect traffic.
resource "aws_ecs_service" "read" {
  name            = "${local.name}-read"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.read.arn
  desired_count   = 4
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.service.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.read.arn
    container_name   = "app"
    container_port   = 8080
  }
}

# Write service stays small — creation traffic is ~1/sec.
resource "aws_ecs_service" "write" {
  name            = "${local.name}-write"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.write.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.service.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.write.arn
    container_name   = "app"
    container_port   = 8080
  }
}

# Only the read fleet autoscales — that's the side that grows with redirect volume.
resource "aws_appautoscaling_target" "read" {
  max_capacity       = 50
  min_capacity       = 4
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.read.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "read_cpu" {
  name               = "${local.name}-read-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.read.resource_id
  scalable_dimension = aws_appautoscaling_target.read.scalable_dimension
  service_namespace  = aws_appautoscaling_target.read.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = 60
  }
}

# ---------------------------------------------------------------------------
# Data: Redis cache, Redis counter, Postgres primary + replicas
# ---------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.name}-redis"
  subnet_ids = var.private_subnet_ids
}

# Lookup cache for the redirect path. Failover on, so a node loss doesn't stop reads.
resource "aws_elasticache_replication_group" "cache" {
  replication_group_id       = "${local.name}-cache"
  description                = "short_code -> long_url lookup cache"
  engine                     = "redis"
  node_type                  = "cache.r6g.large"
  num_cache_clusters         = 2
  automatic_failover_enabled = true
  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [aws_security_group.data.id]
}

# Global ID counter (atomic INCR, leased in batches by the write service).
# Failover protects uniqueness; a lost batch only leaves gaps, never duplicates.
# Multi-region extension point: give each region a disjoint counter range and a local cluster.
resource "aws_elasticache_replication_group" "counter" {
  replication_group_id       = "${local.name}-counter"
  description                = "global short-code counter"
  engine                     = "redis"
  node_type                  = "cache.r6g.large"
  num_cache_clusters         = 2
  automatic_failover_enabled = true
  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [aws_security_group.data.id]
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-db"
  subnet_ids = var.private_subnet_ids
}

# Primary takes the (low) write load. ~500GB at 1B rows fits one instance; no sharding yet.
resource "aws_db_instance" "primary" {
  identifier              = "${local.name}-primary"
  engine                  = "postgres"
  instance_class          = "db.r6g.large"
  allocated_storage       = 600
  username                = "shortener"
  password                = var.db_password
  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids   = [aws_security_group.data.id]
  multi_az                = true
  backup_retention_period = 7
  skip_final_snapshot     = false
}

# Read replicas serve cache misses on the redirect path.
resource "aws_db_instance" "replica" {
  count                  = var.read_replica_count
  identifier             = "${local.name}-replica-${count.index}"
  instance_class         = "db.r6g.large"
  replicate_source_db    = aws_db_instance.primary.identifier
  vpc_security_group_ids = [aws_security_group.data.id]
  skip_final_snapshot    = true
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "api_endpoint" {
  value = aws_apigatewayv2_stage.default.invoke_url
}

output "db_primary_endpoint" {
  value = aws_db_instance.primary.endpoint
}

output "cache_endpoint" {
  value = aws_elasticache_replication_group.cache.primary_endpoint_address
}
