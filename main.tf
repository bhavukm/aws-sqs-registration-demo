data "aws_caller_identity" "current" {}

locals {
  producer_function_name = "${var.project_name}-producer"
  worker_function_name   = "${var.project_name}-worker"
  account_suffix         = data.aws_caller_identity.current.account_id
}

# Main queue: producers send messages here; Lambda consumes them asynchronously.
resource "aws_sqs_queue" "registration" {
  name                       = "${var.project_name}-queue-${local.account_suffix}"
  visibility_timeout_seconds = 30 # 6 x the worker's 5-second timeout
  message_retention_seconds  = 345600 # 4 days
  receive_wait_time_seconds  = 20 # Long polling reduces empty receives
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.registration_dlq.arn
    maxReceiveCount     = 3 # Keep the demo quick; use 5+ as a common production starting point
  })
}

# Failed messages are moved here after repeated unsuccessful processing.
resource "aws_sqs_queue" "registration_dlq" {
  name                      = "${var.project_name}-dlq-${local.account_suffix}"
  message_retention_seconds = 1209600 # 14 days, longer than the source queue
  receive_wait_time_seconds = 20
  sqs_managed_sse_enabled   = true
}

# Dedicated producer role. It can send messages, but cannot consume them.
data "aws_iam_policy_document" "lambda_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "producer" {
  name               = "${var.project_name}-producer-role-${local.account_suffix}"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "producer_logs" {
  role       = aws_iam_role.producer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "producer_send_message" {
  name = "send-to-registration-queue"
  role = aws_iam_role.producer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.registration.arn
    }]
  })
}

# Dedicated worker role. The event source mapping needs these SQS permissions.
resource "aws_iam_role" "worker" {
  name               = "${var.project_name}-worker-role-${local.account_suffix}"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "worker_logs" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "worker_read_queue" {
  name = "consume-registration-queue"
  role = aws_iam_role.worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:ChangeMessageVisibility"
      ]
      Resource = aws_sqs_queue.registration.arn
    }]
  })
}

# Keep demo logs for seven days to avoid accumulating logs indefinitely.
resource "aws_cloudwatch_log_group" "producer" {
  name              = "/aws/lambda/${local.producer_function_name}"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/aws/lambda/${local.worker_function_name}"
  retention_in_days = 7
}
