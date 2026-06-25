# url-shortener — Terraform for the throwaway PoC we built by hand.
#
# Matches the stack deployed in us-east-1 on 2026-06-25: production-SHAPED
# (private data tier, tier-scoped security groups, edge auth, secrets in a vault)
# but throwaway-SIZED (t4g.micro, single-node Redis, 1 task each, public-subnet
# Fargate, no NAT). Unlike the article's production main.tf, this is self-contained:
# it creates its own VPC, Cognito issuer, and Secrets Manager secret.
#
# Apply order (the ECS tasks need the image to exist in ECR first):
#   1. terraform apply -target=aws_ecr_repository.this
#   2. build & push your image to that repo as :v1
#   3. terraform apply
#
# To go to production, this is where you turn the knobs: instance classes,
# multi_az, replica/desired counts, num_cache_clusters + failover, private-subnet
# tasks + a NAT gateway.

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

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "RDS master password. No / ' \" @ characters (kept simple for the connection URL)."
}

locals {
  name  = "url-shortener"
  azs   = ["${var.region}a", "${var.region}b"]
  image = "${aws_ecr_repository.this.repository_url}:v1"
  secrets = [
    { name = "DATABASE_URL", valueFrom = "${aws_secretsmanager_secret.app.arn}:DATABASE_URL::" },
    { name = "REDIS_CACHE_URL", valueFrom = "${aws_secretsmanager_secret.app.arn}:REDIS_CACHE_URL::" },
    { name = "REDIS_COUNTER_URL", valueFrom = "${aws_secretsmanager_secret.app.arn}:REDIS_COUNTER_URL::" },
  ]
}

# ---------------------------------------------------------------------------
# Networking: VPC, 2 public + 2 private subnets, IGW. No NAT (public-subnet tasks).
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = local.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  cidr_block              = ["10.0.0.0/20", "10.0.16.0/20"][count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.name}-public-${count.index}" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = ["10.0.128.0/20", "10.0.144.0/20"][count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.name}-private-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private subnets keep the default (local-only) route table — no internet path,
# which is fine because the data tier never needs egress.

# ---------------------------------------------------------------------------
# Security groups — one-way chain: vpc-link -> alb -> service -> data.
# ---------------------------------------------------------------------------

resource "aws_security_group" "vpc_link" {
  name   = "${local.name}-vpc-link"
  vpc_id = aws_vpc.this.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "alb" {
  name   = "${local.name}-alb"
  vpc_id = aws_vpc.this.id
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

resource "aws_security_group" "service" {
  name   = "${local.name}-service"
  vpc_id = aws_vpc.this.id
  # Inbound only from the ALB (this is the rule that, done as OUTBOUND by hand,
  # broke the deploy). Egress is open so tasks can reach ECR/Secrets Manager/data.
  ingress {
    description     = "app port from ALB"
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

resource "aws_security_group" "data" {
  name   = "${local.name}-data"
  vpc_id = aws_vpc.this.id
  ingress {
    description     = "Postgres from services"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.service.id]
  }
  ingress {
    description     = "Redis from services"
    from_port       = 6379
    to_port         = 6379
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
# Data: RDS Postgres + two ElastiCache Redis (cache, counter). Private subnets.
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-db"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "this" {
  identifier              = "${local.name}-db"
  engine                  = "postgres"
  instance_class          = "db.t4g.micro" # prod: db.r6g.large
  allocated_storage       = 20
  db_name                 = "shortener"
  username                = "shortener"
  password                = var.db_password
  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [aws_security_group.data.id]
  multi_az                = false # prod: true
  publicly_accessible     = false
  backup_retention_period = 0
  skip_final_snapshot     = true
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.name}-redis"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_elasticache_replication_group" "cache" {
  replication_group_id       = "${local.name}-cache"
  description                = "short_code -> long_url lookup cache"
  engine                     = "redis"
  node_type                  = "cache.t4g.micro" # prod: cache.r6g.large
  num_cache_clusters         = 1                 # prod: 2
  automatic_failover_enabled = false             # prod: true
  transit_encryption_enabled = false             # app uses redis:// (no TLS)
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [aws_security_group.data.id]
}

resource "aws_elasticache_replication_group" "counter" {
  replication_group_id       = "${local.name}-counter"
  description                = "global short-code counter"
  engine                     = "redis"
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 1
  automatic_failover_enabled = false
  transit_encryption_enabled = false
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [aws_security_group.data.id]
}

# ---------------------------------------------------------------------------
# Secret: connection strings the tasks read at startup (never plaintext env).
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "app" {
  name                    = "${local.name}/app"
  recovery_window_in_days = 0 # throwaway: allow immediate delete/recreate
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    DATABASE_URL      = "postgresql://shortener:${var.db_password}@${aws_db_instance.this.address}:5432/shortener"
    REDIS_CACHE_URL   = "redis://${aws_elasticache_replication_group.cache.primary_endpoint_address}:6379"
    REDIS_COUNTER_URL = "redis://${aws_elasticache_replication_group.counter.primary_endpoint_address}:6379"
  })
}

# ---------------------------------------------------------------------------
# Image registry + ECS execution role.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "this" {
  name         = local.name
  force_delete = true
}

resource "aws_iam_role" "task_exec" {
  name = "${local.name}-task-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_exec" {
  role       = aws_iam_role.task_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "read_secret" {
  name = "read-secret"
  role = aws_iam_role.task_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.app.arn
    }]
  })
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.name}"
  retention_in_days = 7
}

# ---------------------------------------------------------------------------
# Compute: ECS Fargate cluster + read/write task definitions and services.
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = local.name
}

resource "aws_ecs_task_definition" "read" {
  family                   = "${local.name}-read"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.task_exec.arn
  container_definitions = jsonencode([{
    name         = "app"
    image        = local.image
    portMappings = [{ containerPort = 8080 }]
    environment  = [{ name = "ROLE", value = "read" }]
    secrets      = local.secrets
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.this.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "read"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "write" {
  family                   = "${local.name}-write"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.task_exec.arn
  container_definitions = jsonencode([{
    name         = "app"
    image        = local.image
    portMappings = [{ containerPort = 8080 }]
    environment  = [{ name = "ROLE", value = "write" }]
    secrets      = local.secrets
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.this.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "write"
      }
    }
  }])
}

resource "aws_ecs_service" "read" {
  name            = "${local.name}-read"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.read.arn
  desired_count   = 1 # prod: autoscaled fleet
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = aws_subnet.public[*].id # prod: private subnets + NAT
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.read.arn
    container_name   = "app"
    container_port   = 8080
  }
  depends_on = [aws_lb_listener.http]
}

resource "aws_ecs_service" "write" {
  name            = "${local.name}-write"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.write.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.write.arn
    container_name   = "app"
    container_port   = 8080
  }
  depends_on = [aws_lb_listener_rule.writes]
}

# ---------------------------------------------------------------------------
# Edge: internal ALB (POST /urls -> write, else -> read).
# ---------------------------------------------------------------------------

resource "aws_lb" "this" {
  name               = "${local.name}-alb"
  internal           = true
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "read" {
  name        = "${local.name}-read"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"
  health_check {
    path = "/health"
  }
}

resource "aws_lb_target_group" "write" {
  name        = "${local.name}-write"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"
  health_check {
    path = "/health"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
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

# ---------------------------------------------------------------------------
# Edge: Cognito (JWT issuer) + API Gateway HTTP API via VPC link.
# ---------------------------------------------------------------------------

resource "aws_cognito_user_pool" "this" {
  name = local.name
}

resource "aws_cognito_user_pool_client" "this" {
  name                = local.name
  user_pool_id        = aws_cognito_user_pool.this.id
  generate_secret     = false
  explicit_auth_flows = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
}

resource "aws_apigatewayv2_api" "this" {
  name          = local.name
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${local.name}-link"
  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.vpc_link.id]
}

resource "aws_apigatewayv2_integration" "alb" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_uri        = aws_lb_listener.http.arn
  integration_method     = "ANY"
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.this.id
  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id           = aws_apigatewayv2_api.this.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${local.name}-jwt"
  jwt_configuration {
    issuer   = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.this.id}"
    audience = [aws_cognito_user_pool_client.this.id]
  }
}

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
# Outputs
# ---------------------------------------------------------------------------

output "api_endpoint" {
  value = aws_apigatewayv2_api.this.api_endpoint
}

output "ecr_repository_url" {
  value = aws_ecr_repository.this.repository_url
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.this.id
}
