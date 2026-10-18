variable "aws_region" {
  description = "AWS Region for the demo. Choose a region you already use, if possible."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix used to name demo resources. Keep it lowercase and short."
  type        = string
  default     = "sre-sqs-registration-demo"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.project_name))
    error_message = "project_name must be 3-31 characters, start with a lowercase letter, and contain only lowercase letters, numbers, and hyphens."
  }
}
