data "archive_file" "producer" {
  type        = "zip"
  source_file = "${path.module}/lambda/producer.py"
  output_path = "${path.module}/build/producer.zip"
}

data "archive_file" "worker" {
  type        = "zip"
  source_file = "${path.module}/lambda/worker.py"
  output_path = "${path.module}/build/worker.zip"
}

resource "aws_lambda_function" "producer" {
  function_name    = local.producer_function_name
  role             = aws_iam_role.producer.arn
  runtime          = "python3.12"
  handler          = "producer.handler"
  filename         = data.archive_file.producer.output_path
  source_code_hash = data.archive_file.producer.output_base64sha256
  timeout          = 5
  memory_size      = 128

  environment {
    variables = {
      QUEUE_URL = aws_sqs_queue.registration.url
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.producer_logs,
    aws_iam_role_policy.producer_send_message,
    aws_cloudwatch_log_group.producer
  ]
}

resource "aws_lambda_function" "worker" {
  function_name    = local.worker_function_name
  role             = aws_iam_role.worker.arn
  runtime          = "python3.12"
  handler          = "worker.handler"
  filename         = data.archive_file.worker.output_path
  source_code_hash = data.archive_file.worker.output_base64sha256
  timeout          = 5
  memory_size      = 128

  depends_on = [
    aws_iam_role_policy_attachment.worker_logs,
    aws_iam_role_policy.worker_read_queue,
    aws_cloudwatch_log_group.worker
  ]
}

# SQS polls for messages and invokes the worker automatically. Partial batch
# responses mean successful messages need not be retried when another fails.
resource "aws_lambda_event_source_mapping" "registration_queue" {
  event_source_arn = aws_sqs_queue.registration.arn
  function_name    = aws_lambda_function.worker.arn
  batch_size       = 5
  enabled          = true

  function_response_types = ["ReportBatchItemFailures"]

  depends_on = [aws_iam_role_policy.worker_read_queue]
}
