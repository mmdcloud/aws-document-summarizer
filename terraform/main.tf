# Registering vault provider
data "vault_generic_secret" "opensearch" {
  path = "secret/opensearch"
}

# Opensearch Secrets Manager module
module "opensearch_secrets" {
  source                  = "./modules/secrets-manager"
  name                    = "opensearch-secrets"
  description             = "opensearch-secrets"
  recovery_window_in_days = 0
  secret_string = jsonencode({
    username = tostring(data.vault_generic_secret.opensearch.data["username"])
    password = tostring(data.vault_generic_secret.opensearch.data["password"])
  })
}

# SQS Config
resource "aws_lambda_event_source_mapping" "sqs_event_trigger" {
  event_source_arn                   = module.document_upload_event_queue.arn
  function_name                      = module.lambda_function.arn
  enabled                            = true
  batch_size                         = 10
  maximum_batching_window_in_seconds = 60
}

# SQS Queue for buffering S3 events
module "document_upload_event_queue" {
  source                        = "./modules/sqs"
  queue_name                    = "document-upload-events-queue"
  delay_seconds                 = 0
  maxReceiveCount               = 3
  dlq_message_retention_seconds = 86400
  dlq_name                      = "document-upload-events-dlq"
  max_message_size              = 262144
  message_retention_seconds     = 345600
  visibility_timeout_seconds    = 180
  receive_wait_time_seconds     = 20
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = "arn:aws:sqs:${var.region}:*:document-upload-events-queue"
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = "${module.documents_bucket.arn}"
          }
        }
      }
    ]
  })
}

module "documents_bucket" {
  source             = "./modules/s3"
  bucket_name        = "documents-bucket"
  objects            = []
  versioning_enabled = "Enabled"
  cors = [
    {
      allowed_headers = ["*"]
      allowed_methods = ["GET", "PUT"]
      allowed_origins = ["*"]
      max_age_seconds = 3000
    }
  ]
  bucket_policy = ""
  force_destroy = false
  bucket_notification = {
    queue = [
      {
        queue_arn = module.document_upload_event_queue.arn
        events    = ["s3:ObjectCreated:*"]
      }
    ]
    lambda_function = []
  }
}

# Lambda IAM  Role
module "lambda_function_iam_role" {
  source             = "./modules/iam"
  role_name          = "lambda-function-iam-role"
  role_description   = "lambda-function-iam-role"
  policy_name        = "lambda-function-iam-policy"
  policy_description = "lambda-function-iam-policy"
  assume_role_policy = <<EOF
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Action": "sts:AssumeRole",
                "Principal": {
                  "Service": "lambda.amazonaws.com"
                },
                "Effect": "Allow",
                "Sid": ""
            }
        ]
    }
    EOF
  policy             = <<EOF
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Action": [
                  "logs:CreateLogGroup",
                  "logs:CreateLogStream",
                  "logs:PutLogEvents"
                ],
                "Resource": "arn:aws:logs:*:*:*",
                "Effect": "Allow"
            }
        ]
    }
    EOF
}

# S3 bucket for storing lambda function code
module "lambda_function_code" {
  source      = "./modules/s3"
  bucket_name = "lambda-function-code"
  objects = [
    {
      key    = "lambda.zip"
      source = "./files/lambda.zip"
    }
  ]
  versioning_enabled = "Enabled"
  force_destroy      = true
}

# Lambda function
module "lambda_function" {
  source        = "./modules/lambda"
  function_name = "lambda-function"
  role_arn      = module.lambda_function_iam_role.arn
  permissions   = []
  env_variables = {
    OPENSEARCH_ENDPOINT = module.opensearch.endpoint
  }
  handler   = "main.lambda_handler"
  runtime   = "python3.12"
  s3_bucket = module.lambda_function_code.bucket
  s3_key    = "lambda.zip"
}

# Opensearch module
module "opensearch" {
  source                          = "./modules/opensearch"
  domain_name                     = "opensearchdestination"
  engine_version                  = "OpenSearch_2.17"
  instance_type                   = "t3.small.search"
  instance_count                  = 1
  ebs_enabled                     = true
  volume_size                     = 10
  encrypt_at_rest_enabled         = true
  security_options_enabled        = true
  anonymous_auth_enabled          = true
  internal_user_database_enabled  = true
  master_user_name                = tostring(data.vault_generic_secret.opensearch.data["username"])
  master_user_password            = tostring(data.vault_generic_secret.opensearch.data["password"])
  node_to_node_encryption_enabled = true
}
