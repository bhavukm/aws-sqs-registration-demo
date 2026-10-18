output "aws_region" {
  description = "AWS Region where this demo was deployed."
  value       = var.aws_region
}

output "registration_queue_url" {
  description = "URL of the main SQS queue."
  value       = aws_sqs_queue.registration.url
}

output "registration_queue_name" {
  description = "Name of the main SQS queue."
  value       = aws_sqs_queue.registration.name
}

output "dead_letter_queue_url" {
  description = "URL of the dead-letter queue."
  value       = aws_sqs_queue.registration_dlq.url
}

output "producer_lambda_name" {
  description = "Invoke this Lambda to send a registration message to SQS."
  value       = aws_lambda_function.producer.function_name
}

output "worker_lambda_name" {
  description = "SQS automatically invokes this Lambda to process messages."
  value       = aws_lambda_function.worker.function_name
}

output "worker_log_group" {
  description = "CloudWatch Logs group for worker messages and failures."
  value       = aws_cloudwatch_log_group.worker.name
}
