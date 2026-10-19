# Hands-on AWS SQS Project: Reliable Conference Registration Processing

A beginner-friendly, low-cost AWS project using **Amazon SQS, two Python Lambda functions, a dead-letter queue (DLQ), CloudWatch Logs, and Terraform**.

This demo is inspired by a common enterprise pattern: accept work quickly, put it in a queue, and let a separate worker process it asynchronously. It does not create EC2 instances, a VPC, NAT Gateway, API Gateway, or a database.

> **Cost note:** This is a small demo, not a promise of zero cost. AWS pricing, Free Tier eligibility, CloudWatch Logs usage, and regional prices can change. Check the current pricing and your account before deploying. Destroy the stack when you finish.

## 1. What are we building?

Imagine an organization runs **DevOps Conference 2026** and people register online. Each registration needs to be validated and processed. Later, the organization may send confirmation emails, update a registration database, or notify another service.

If the registration application had to do every step itself before responding to the user, it could become slow when many people register at the same time. If the processing service is temporarily unavailable, the application could also struggle to handle the work.

Our simple solution is:

1. A **Producer Lambda** receives one registration request.
2. The producer puts the registration message into an **Amazon SQS queue** and returns quickly.
3. SQS stores the message until a consumer is ready to process it.
4. An SQS event source mapping invokes the **Worker Lambda** automatically.
5. The worker processes the message and writes a safe summary to CloudWatch Logs.
6. If processing repeatedly fails, SQS moves the message to a **dead-letter queue (DLQ)** so it can be investigated.

The worker in this demo logs the successful processing of a registration. In a real application, that processing step could save the registration to a database, send a confirmation, or call another service.

## 2. SQS fundamentals in plain English

**Amazon SQS (Simple Queue Service)** is a managed message queue. Think of it like a waiting line for work. One part of an application places a message in the line, and another part processes it when it has capacity.

- **Producer:** The component that sends work into the queue. Here, it is the Producer Lambda.
- **Queue:** The buffer that holds messages until they are processed.
- **Consumer:** The component that processes messages. Here, it is the Worker Lambda.
- **Decoupling:** The producer and consumer do not have to run at the same time or be directly connected. The queue sits between them.
- **Buffering traffic spikes:** If 1,000 registrations arrive quickly, SQS can hold messages while the worker processes them at its own pace.
- **Retries:** If a message is not processed successfully, it can become available for another attempt after its visibility timeout.
- **Dead-letter queue:** A separate queue for messages that repeatedly fail, helping prevent a problematic message from endlessly blocking normal work.

### Why not just call the worker directly?

Without a queue, the application might need to wait for processing to finish, or it would need to implement its own retry and buffering logic. With SQS, the producer can hand off the work quickly, and the worker can scale independently. SQS is useful when a system needs to absorb bursts, isolate temporary failures, and keep the producer independent from the downstream processor.

## 3. Architecture

```text
Registration request (AWS CLI for this demo)
                  |
                  v
         Producer Lambda
                  |
          SendMessage to SQS
                  |
                  v
         Registration SQS Queue
                  |
       SQS event source mapping
        invokes Worker Lambda
                  |
       +----------+-----------+
       |                      |
       v                      v
 Successful processing   Repeated failure
       |                      |
 SQS removes message           v
                        Dead-letter queue
                              |
                     Inspect and troubleshoot
```
<img width="727" height="600" alt="image" src="https://github.com/user-attachments/assets/c6b45d67-2d80-4d31-96c6-428beaaa8741" />


For simplicity, we invoke the Producer Lambda using the AWS CLI. This avoids adding an API Gateway or website to the demo. The SQS-to-Lambda integration is real: AWS polls the queue and invokes the Worker Lambda automatically.

## 4. What Terraform creates

- One standard SQS queue for registration messages.
- One SQS dead-letter queue.
- One Producer Lambda written in Python 3.12.
- One Worker Lambda written in Python 3.12.
- An SQS event source mapping that triggers the worker automatically.
- Separate IAM roles for the producer and worker.
- CloudWatch log groups with seven-day retention.
- SQS-managed encryption at rest and long polling.

The demo's main queue uses a 30-second visibility timeout because the worker timeout is five seconds. Its redrive policy moves a message to the DLQ after three unsuccessful receives so the behavior is reasonably quick to demonstrate. For production, follow your workload's retry requirements; AWS recommends setting `maxReceiveCount` to at least five as a common starting point for SQS-triggered Lambda functions.

## 5. Prerequisites

Install:

- Terraform 1.5 or later.
- AWS CLI v2.
- An AWS account with permission to create SQS queues, Lambda functions, IAM roles/policies, CloudWatch log groups, and Lambda event source mappings.

The commands below use **Bash** (Linux, macOS, or Windows WSL). Configure AWS credentials before you start.

Check your identity and region:

```bash
aws sts get-caller-identity
aws configure get region
```

Make sure `get-caller-identity` shows your intended personal demo account. Do not deploy into a work or production account without approval.

## 6. Deploy with Terraform

Open a terminal in this project directory and run:

```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

Review the plan. Type `yes` only if the resources and account are correct.

View the deployed resource names:

```bash
terraform output
terraform output -raw registration_queue_url
terraform output -raw producer_lambda_name
terraform output -raw worker_lambda_name
terraform output -raw dead_letter_queue_url
```

## 7. Test a successful registration

The sample uses fictional registration information. Send a message by invoking the Producer Lambda:

```bash
aws lambda invoke \
  --function-name "$(terraform output -raw producer_lambda_name)" \
  --cli-binary-format raw-in-base64-out \
  --payload fileb://samples/registration-valid.json \
  producer-response.json
```

Read the producer response:

```bash
cat producer-response.json
```

You should see a response containing `"status": "QUEUED"` and an SQS message ID. This means the message was placed in the queue; it does **not** mean the worker has completed processing yet.

Give the event source mapping a few seconds to invoke the worker, then view its logs:

```bash
aws logs tail "$(terraform output -raw worker_log_group)" --since 10m
```

Look for a message like `Processed registration_id=reg-1001 event_name=DevOps Conference 2026`.

The email address is not printed in logs, which is a good habit when handling personal information.

## 8. Demonstrate a failure and the dead-letter queue

This project includes a special sample message that intentionally fails in the Worker Lambda. It is for the demo only; a real application must never accept an untrusted user-controlled switch to force processing failures.

Send that sample:

```bash
aws lambda invoke \
  --function-name "$(terraform output -raw producer_lambda_name)" \
  --cli-binary-format raw-in-base64-out \
  --payload fileb://samples/registration-failure-demo.json \
  failure-producer-response.json
```

The worker logs a processing error and reports the failed message to the SQS event source mapping. SQS retries the message. After the configured receive limit is reached, it moves the message to the DLQ.

Check the DLQ in the AWS Console under **Amazon SQS**, or inspect its approximate visible message count:

```bash
aws sqs get-queue-attributes \
  --queue-url "$(terraform output -raw dead_letter_queue_url)" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
```

SQS metrics are approximate, and the redrive process takes time because it waits for retries and the visibility timeout. If the count has not changed, wait and check again. You can also use **CloudWatch → Log groups** to inspect the worker errors.

## 9. Important SQS behavior to understand

- **A message is not removed just because the consumer received it.** With the Lambda event source mapping, successful processing allows Lambda/SQS to delete the message from the source queue.
- **Visibility timeout:** While a message is being processed, it is temporarily hidden from other receives. If processing does not succeed, it can reappear after the timeout.
- **At-least-once delivery:** Standard queues can deliver a message more than once. Production consumers should be idempotent, meaning repeated processing of the same registration does not create duplicate business actions.
- **Partial batch response:** This demo enables `ReportBatchItemFailures`. If a batch contains both successful and failed messages, the worker can identify just the failed message for retry rather than retrying every message in that batch.
- **DLQ:** A dead-letter queue is not automatic magic; the redrive policy must be configured, and the team needs a process to inspect, fix, and replay or discard messages.
- **Ordering:** This project uses a Standard queue. Standard queues offer best-effort ordering, not strict FIFO ordering. Use an SQS FIFO queue if the application has a real strict-ordering requirement and design it accordingly.

## 10. Basic observability

You can view the queue and worker behavior without deploying Grafana or creating extra dashboards.

### In Amazon SQS

Open the main queue in the AWS Console and inspect its monitoring charts. Useful metrics include:

- `NumberOfMessagesSent`: messages added to the queue.
- `NumberOfMessagesReceived`: messages received for processing; retries can increase this count.
- `NumberOfMessagesDeleted`: messages successfully removed from the source queue.
- `ApproximateNumberOfMessagesVisible`: messages waiting to be processed.
- `ApproximateAgeOfOldestMessage`: how long the oldest visible message has been waiting.

Also look at the DLQ's `ApproximateNumberOfMessagesVisible`. If it increases, messages are repeatedly failing and need investigation.

### In AWS Lambda and CloudWatch Logs

Monitor `Invocations`, `Errors`, `Duration`, and `Throttles` for the Worker Lambda. Read the worker's CloudWatch log group to identify error messages. The log group is configured to retain logs for seven days to avoid indefinite retention for this demo.

CloudWatch provides service metrics by default. Custom dashboards and alarms are optional follow-up work and are intentionally not included in this minimal project.

## 11. Cost-conscious design choices

- No EC2 instances, NAT Gateway, VPC, API Gateway, database, or always-running compute.
- Small Lambda functions use 128 MB memory and five-second timeouts.
- SQS uses long polling (`receive_wait_time_seconds = 20`) to reduce empty polling requests.
- CloudWatch log retention is set to seven days.
- Sample workload is small and manually triggered; there is no continuous traffic generator.

AWS currently lists one million SQS requests per month in its free usage offering, but you should verify the current pricing and eligibility for your account. SQS, Lambda, CloudWatch Logs, and other services can still incur charges depending on region and usage. See [Amazon SQS pricing](https://aws.amazon.com/sqs/pricing/) and review [AWS Lambda pricing](https://aws.amazon.com/lambda/pricing/) before deploying.

## 12. Destroy resources when finished

When your demo is complete, remove the resources:

```bash
terraform destroy
```

Review the destroy plan and confirm only this demo's resources will be removed. This deletes the queues, Lambdas, IAM roles/policies, and log groups managed by this project. Do not keep a test stack running if you no longer need it.

## 13. File structure

```text
aws-sqs-registration-demo/
├── README.md
├── versions.tf
├── variables.tf
├── terraform.tfvars.example
├── main.tf
├── lambdas.tf
├── outputs.tf
├── .gitignore
├── lambda/
│   ├── producer.py
│   └── worker.py
├── samples/
│   ├── registration-valid.json
│   └── registration-failure-demo.json
└── build/
    └── .gitkeep
```

## 14. Official references

- [Amazon SQS Developer Guide](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/)
- [Amazon SQS best practices](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-best-practices.html)
- [Configuring long polling](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/best-practices-setting-up-long-polling.html)
- [Configuring an SQS event source mapping for Lambda](https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-configure.html)
- [Handling errors for SQS-triggered Lambda functions](https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-errorhandling.html)
- [Amazon SQS pricing](https://aws.amazon.com/sqs/pricing/)
