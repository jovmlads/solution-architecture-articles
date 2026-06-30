# File storage service — infrastructure for the architecture in README.md.
# Provider: AWS. Single region (cross-region replication is deferred; see S3 note).
# Component mapping:
#   API Gateway (routing / auth / rate limiting / TLS) -> aws_apigatewayv2_api + JWT authorizer + stage throttling
#   Load balancer                                       -> internal ALB behind a VPC link
#   File Service (control plane)                        -> ECS Fargate, scaled on request count
#   File metadata + shares                              -> DynamoDB (FileMetadata + SharedFiles)
#   Blob storage                                        -> S3 (multipart, encrypted, versioned)
#   Upload-complete events                              -> S3 event notifications -> File Service
#   Content delivery                                    -> CloudFront with signed URLs
#   Real-time sync channel                              -> API Gateway WebSocket API
# The defining decision — clients transfer bytes directly to/from S3 via presigned/signed
# URLs — is why there is no large compute or bandwidth provisioned for the data path.
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
  description = "Private subnets for the ALB and ECS tasks."
}

variable "service_image" {
  type        = string
  description = "Container image for the File Service (control plane)."
}

variable "file_service_desired_count" {
  type        = number
  default     = 3
  description = "File Service tasks. Scales with request count, not data volume — bytes never pass through it."
}

variable "cognito_user_pool_id" {
  type        = string
  description = "Existing Cognito user pool issuing the JWTs the API gateway validates."
}

variable "cognito_app_client_id" {
  type        = string
  description = "Cognito app client ID used as the JWT audience."
}

locals {
  name = "file-storage-${var.environment}"
}

# ---------------------------------------------------------------------------
# Blob storage — the file bytes live here, never in the app tier.
# Multipart upload (chunking), SSE encryption at rest, and versioning for the
# "recover lost or corrupted files" requirement.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "files" {
  bucket = "${local.name}-blobs"
}

# Versioning gives recoverability: a corrupt or deleted object can be restored.
resource "aws_s3_bucket_versioning" "files" {
  bucket = aws_s3_bucket.files.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encryption at rest — part of the security requirement.
resource "aws_s3_bucket_server_side_encryption_configuration" "files" {
  bucket = aws_s3_bucket.files.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

# Bytes are reached only through presigned/CloudFront-signed URLs — never public.
resource "aws_s3_bucket_public_access_block" "files" {
  bucket                  = aws_s3_bucket.files.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CORS so browser clients can PUT chunks directly to S3 with presigned URLs.
resource "aws_s3_bucket_cors_configuration" "files" {
  bucket = aws_s3_bucket.files.id
  cors_rule {
    allowed_methods = ["PUT", "GET", "HEAD"]
    allowed_origins = ["*"] # tighten to the app origin in a real deployment
    allowed_headers = ["*"]
    expose_headers  = ["ETag"] # client needs the ETag to report each uploaded part
    max_age_seconds = 3000
  }
}

# Abort orphaned multipart uploads so half-finished 50GB uploads don't accrue cost.
resource "aws_s3_bucket_lifecycle_configuration" "files" {
  bucket = aws_s3_bucket.files.id
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---------------------------------------------------------------------------
# Metadata store — control-plane state the File Service operates on.
# DynamoDB: loosely structured, queried by user; availability over consistency.
# ---------------------------------------------------------------------------

# FileMetadata: status, chunks[], fingerprint. GSI on fingerprint powers
# dedup and resume ("have I uploaded this content before?").
resource "aws_dynamodb_table" "file_metadata" {
  name         = "${local.name}-file-metadata"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "fileId"

  attribute {
    name = "fileId"
    type = "S"
  }
  attribute {
    name = "fingerprint"
    type = "S"
  }

  global_secondary_index {
    name            = "by-fingerprint"
    hash_key        = "fingerprint"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }
}

# SharedFiles: separate table so "files shared with me" is one query and isn't
# bounded by a row-size limit (the reason a sharelist-in-metadata was rejected).
resource "aws_dynamodb_table" "shared_files" {
  name         = "${local.name}-shared-files"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "userId"
  range_key    = "fileId"

  attribute {
    name = "userId"
    type = "S"
  }
  attribute {
    name = "fileId"
    type = "S"
  }
}

# ---------------------------------------------------------------------------
# File Service — stateless control plane on Fargate.
# Authorizes, generates presigned/signed URLs, writes metadata, verifies chunks.
# It never carries file bytes, so it is sized for request count, not data volume.
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = local.name
}

resource "aws_security_group" "file_service" {
  name   = "${local.name}-file-service"
  vpc_id = var.vpc_id

  ingress {
    description     = "From the internal ALB only."
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # to S3 / DynamoDB / Secrets Manager (or via VPC endpoints)
  }
}

resource "aws_ecs_task_definition" "file_service" {
  family                   = "${local.name}-file-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.file_service_task.arn

  container_definitions = jsonencode([
    {
      name         = "file-service"
      image        = var.service_image
      essential    = true
      portMappings = [{ containerPort = 8080 }]
      environment = [
        { name = "S3_BUCKET", value = aws_s3_bucket.files.bucket },
        { name = "METADATA_TABLE", value = aws_dynamodb_table.file_metadata.name },
        { name = "SHARES_TABLE", value = aws_dynamodb_table.shared_files.name },
        { name = "CDN_DOMAIN", value = aws_cloudfront_distribution.downloads.domain_name },
      ]
      # CloudFront signing private key is pulled from Secrets Manager, never baked in.
      secrets = [
        { name = "CF_SIGNING_KEY", valueFrom = aws_secretsmanager_secret.cf_signing_key.arn },
      ]
    }
  ])
}

resource "aws_ecs_service" "file_service" {
  name            = "${local.name}-file-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.file_service.arn
  desired_count   = var.file_service_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.file_service.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.file_service.arn
    container_name   = "file-service"
    container_port   = 8080
  }
}

# ---------------------------------------------------------------------------
# Internal ALB — sits behind the API gateway via a VPC link, not internet-facing.
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name   = "${local.name}-alb"
  vpc_id = var.vpc_id
  ingress {
    description = "From the API Gateway VPC link."
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

resource "aws_lb" "internal" {
  name               = "${local.name}-alb"
  internal           = true
  load_balancer_type = "application"
  subnets            = var.private_subnet_ids
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "file_service" {
  name        = "${local.name}-fs"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"
  health_check {
    path = "/health"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.file_service.arn
  }
}

# ---------------------------------------------------------------------------
# API Gateway (HTTP API) — public edge: routing, JWT auth, rate limiting, TLS.
# Forwards to the internal ALB over a VPC link.
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "http" {
  name          = "${local.name}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_vpc_link" "alb" {
  name               = "${local.name}-vpclink"
  subnet_ids         = var.private_subnet_ids
  security_group_ids = [aws_security_group.alb.id]
}

# JWT authorizer — user identity comes from a validated token, never the body.
resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id           = aws_apigatewayv2_api.http.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${local.name}-jwt"
  jwt_configuration {
    audience = [var.cognito_app_client_id]
    issuer   = "https://cognito-idp.${var.region}.amazonaws.com/${var.cognito_user_pool_id}"
  }
}

resource "aws_apigatewayv2_integration" "alb" {
  api_id             = aws_apigatewayv2_api.http.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri    = aws_lb_listener.http.arn
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.alb.id
}

# All control-plane routes are authenticated; the byte transfer is not here — it
# goes straight to S3/CloudFront with signed URLs.
resource "aws_apigatewayv2_route" "proxy" {
  api_id             = aws_apigatewayv2_api.http.id
  route_key          = "ANY /{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
  authorization_type = "JWT"
}

# Stage throttling — basic rate limiting at the edge.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
  default_route_settings {
    throttling_burst_limit = 2000
    throttling_rate_limit  = 1000
  }
}

# ---------------------------------------------------------------------------
# CloudFront — download path. Serves bytes from the edge via signed URLs so a
# leaked link expires; origin is the private S3 bucket.
# ---------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "${local.name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "downloads" {
  enabled = true

  origin {
    domain_name              = aws_s3_bucket.files.bucket_regional_domain_name
    origin_id                = "s3-files"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-files"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    # Signed URLs: only the File Service can mint a valid, short-lived download link.
    trusted_key_groups = [aws_cloudfront_key_group.signing.id]
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Public half of the signing key pair; the private half lives in Secrets Manager.
resource "aws_cloudfront_public_key" "signing" {
  name        = "${local.name}-signing-pubkey"
  encoded_key = file("${path.module}/cf_signing_public_key.pem")
}

resource "aws_cloudfront_key_group" "signing" {
  name  = "${local.name}-signing"
  items = [aws_cloudfront_public_key.signing.id]
}

# ---------------------------------------------------------------------------
# Real-time sync channel — one WebSocket per device for change pushes.
# Polling (GET /files/changes) is the fallback and rides the HTTP API above.
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "sync_ws" {
  name                       = "${local.name}-sync"
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"
}

# ---------------------------------------------------------------------------
# Upload-complete events — S3 notifies the File Service so it can verify
# assembly and flip FileMetadata.status to "uploaded".
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "upload_complete" {
  name = "${local.name}-upload-complete"
}

resource "aws_s3_bucket_notification" "complete" {
  bucket = aws_s3_bucket.files.id
  topic {
    topic_arn = aws_sns_topic.upload_complete.arn
    events    = ["s3:ObjectCreated:CompleteMultipartUpload"]
  }
}

# ---------------------------------------------------------------------------
# Secrets — CloudFront signing private key. Never plaintext.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "cf_signing_key" {
  name = "${local.name}-cf-signing-key"
}

# ---------------------------------------------------------------------------
# IAM — least privilege for the File Service task: sign URLs, read/write
# metadata, initiate/verify/complete multipart uploads. It does not stream bytes.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_ecs" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${local.name}-task-exec"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs.json
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "file_service_task" {
  name               = "${local.name}-fs-task"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs.json
}

data "aws_iam_policy_document" "file_service" {
  # Initiate, verify (ListParts), and complete multipart uploads; generate
  # presigned PUT/GET URLs. Object-level only, on this bucket.
  statement {
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:AbortMultipartUpload",
    ]
    resources = ["${aws_s3_bucket.files.arn}/*"]
  }
  # Metadata + shares.
  statement {
    actions = [
      "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem",
      "dynamodb:Query", "dynamodb:DeleteItem",
    ]
    resources = [
      aws_dynamodb_table.file_metadata.arn,
      "${aws_dynamodb_table.file_metadata.arn}/index/*",
      aws_dynamodb_table.shared_files.arn,
    ]
  }
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.cf_signing_key.arn]
  }
}

resource "aws_iam_role_policy" "file_service" {
  name   = "${local.name}-fs-policy"
  role   = aws_iam_role.file_service_task.id
  policy = data.aws_iam_policy_document.file_service.json
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "api_endpoint" {
  value = aws_apigatewayv2_api.http.api_endpoint
}

output "sync_ws_endpoint" {
  value = aws_apigatewayv2_api.sync_ws.api_endpoint
}

output "cdn_domain" {
  value = aws_cloudfront_distribution.downloads.domain_name
}

output "blob_bucket" {
  value = aws_s3_bucket.files.bucket
}
