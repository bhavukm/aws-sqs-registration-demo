## 11. Grafana dashboards and alerts (local Docker; no Terraform changes)

This section adds a lightweight Grafana dashboard on your laptop. Grafana reads the AWS metrics that SQS and Lambda already publish to CloudWatch. **It does not create any new AWS infrastructure**, and it does not change the Terraform configuration for this demo. CloudWatch API calls and log queries may still incur AWS charges, so use a modest dashboard refresh interval and remove unused resources when finished.

### 11.1 Start Grafana locally with Docker

Make sure Docker Desktop or Docker Engine is running. Start Grafana with a persistent local volume and bind the web interface to your own computer only:

```bash
docker volume create grafana-sqs-data
docker run -d \
  --name grafana-sqs \
  -p 127.0.0.1:3000:3000 \
  -v grafana-sqs-data:/var/lib/grafana \
  grafana/grafana
```

On Windows PowerShell, use the same commands without the line-continuation backslashes:

```powershell
docker volume create grafana-sqs-data
docker run -d --name grafana-sqs -p 127.0.0.1:3000:3000 -v grafana-sqs-data:/var/lib/grafana grafana/grafana
```

Open `http://localhost:3000`. Sign in with `admin` / `admin` if prompted for the initial default login, and immediately set a new password. Keep the port bound to `127.0.0.1`; do not expose this demo Grafana instance to the public internet.

Check the container if it does not start:

```bash
docker ps
docker logs grafana-sqs
```

### 11.2 Give Grafana read-only AWS access

Grafana needs permission to read CloudWatch metrics. For this local demo, create a **dedicated IAM user with programmatic credentials** and attach a narrowly scoped read-only policy. Do not use your AWS root credentials or your Terraform administrator credentials. In a production deployment, prefer short-lived credentials or an IAM role wherever possible.

In the AWS Console:

1. Open **IAM → Policies → Create policy → JSON**.
2. Paste the policy below and name it `GrafanaCloudWatchReadOnlyForSQSDemo`.
3. Create a dedicated IAM user such as `grafana-sqs-readonly`, attach this policy, and create an access key for local development.
4. Keep the access key and secret key private. They are only for reading metrics and logs, not changing AWS resources.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadCloudWatchMetricsAndAlarms",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:ListMetrics",
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:DescribeAlarms",
        "cloudwatch:DescribeAlarmsForMetric",
        "cloudwatch:DescribeAlarmHistory"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ReadCloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:DescribeLogGroups",
        "logs:GetLogGroupFields",
        "logs:StartQuery",
        "logs:StopQuery",
        "logs:GetQueryResults",
        "logs:GetLogEvents",
        "logs:FilterLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
```

The `logs:` permissions allow Grafana to use CloudWatch Logs for troubleshooting as well as metrics. If you only want metrics, you can remove the second statement.

### 11.3 Add CloudWatch as Grafana's data source

1. In Grafana, open **Connections → Data sources → Add new data source**.
2. Select **CloudWatch**. It is built into Grafana; no plugin installation is needed.
3. Set **Authentication Provider** to **Access & secret key** for this local demo.
4. Enter the access key ID and secret access key from the dedicated read-only IAM user.
5. Set **Default Region** to the region used by Terraform, usually `us-east-1`. Confirm it with:

   ```bash
   terraform output -raw aws_region
   ```

6. Choose **Save & test**. The connection should confirm that Grafana can query CloudWatch metrics and logs.

This stores the credentials in your local Grafana data source configuration. Do not export/share a Grafana data source or dashboard with secrets. Revoke this demo access key when you no longer need it.

### 11.4 Find the exact queue and Lambda names

Use the Terraform outputs to identify the main queue and worker function:

```bash
terraform output -raw registration_queue_name
terraform output -raw worker_lambda_name
terraform output -raw dead_letter_queue_url
```

The last output is the DLQ URL; the queue name is the final part of that URL. You can also copy both queue names from the **Amazon SQS** console. In CloudWatch, SQS metrics are filtered by the `QueueName` dimension and Lambda metrics by `FunctionName`.

### 11.5 Create a simple dashboard

1. In Grafana, open **Dashboards → New → New dashboard → Add visualization**.
2. Select the **CloudWatch** data source.
3. Use the **Metrics** query editor. For SQS metrics, choose namespace `AWS/SQS`; for Lambda metrics, choose namespace `AWS/Lambda`.
4. Build the following panels. Choose **Time series** for trends or **Stat** for a large current value. Use a dashboard time range such as **Last 6 hours** or **Last 24 hours** and set refresh to **1m** during the demo or **5m** for lower query volume.

| Panel | Namespace and metric | Dimension / statistic | What it tells us |
|---|---|---|---|
| Main queue backlog | `AWS/SQS` → `ApproximateNumberOfMessagesVisible` | `QueueName` = main queue; `Maximum`; period `60` seconds | Messages waiting to be processed |
| Queue message flow | `AWS/SQS` → `NumberOfMessagesSent`, `NumberOfMessagesReceived`, `NumberOfMessagesDeleted` | `QueueName` = main queue; `Sum`; period `300` seconds | Messages entering, being received, and being removed |
| Dead-letter queue backlog | `AWS/SQS` → `ApproximateNumberOfMessagesVisible` | `QueueName` = DLQ; `Maximum`; period `60` seconds | Messages that repeatedly failed and need investigation |
| Oldest message age | `AWS/SQS` → `ApproximateAgeOfOldestMessage` | `QueueName` = main queue; `Maximum`; period `60` seconds | How long the oldest unprocessed message has been waiting, in seconds |
| Worker Lambda health | `AWS/Lambda` → `Invocations`, `Errors`, `Throttles` | `FunctionName` = worker Lambda; `Sum`; period `300` seconds | Worker invocation count and function-level errors/throttling |

In the CloudWatch query editor, choose the exact metric name, then set its dimension and statistic. Give every panel a clear title and click **Apply**. Save the dashboard as `SQS Registration - Operations`.

Optional: add another Lambda panel for `Duration` using statistic `Average` and period `300` seconds; this metric is in milliseconds, so give it a separate panel rather than mixing it with message counts.

**Metric note:** SQS queue metrics are approximate. Some queue metrics may not emit points while the queue is inactive, so a blank panel does not always mean a failure. Send the valid sample message from Section 7 and run the failure demo from Section 8 to populate the charts. SQS metric names and meanings are documented in the [AWS SQS metrics reference](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-available-cloudwatch-metrics.html).

### 11.6 Create Grafana alerts

In Grafana, open **Alerting → Alert rules → New alert rule**. For each rule, create a CloudWatch metric query, then add a **Reduce** expression (use `Last`) and a **Threshold** expression. Set an evaluation interval and a pending period, then save the rule.

Create these starter alerts:

| Alert name | Metric / dimension | Condition | Suggested pending period | Why |
|---|---|---|---|---|
| `SQS-DLQ-Has-Messages` | `AWS/SQS` → `ApproximateNumberOfMessagesVisible`; `QueueName` = DLQ; `Maximum`, `60s` | Above `0` | `1m` | Any message in the DLQ needs investigation |
| `SQS-Backlog-Growing` | `AWS/SQS` → `ApproximateNumberOfMessagesVisible`; `QueueName` = main queue; `Maximum`, `60s` | Above `10` | `5m` | The consumer may not be keeping up with incoming work |
| `SQS-Oldest-Message-Age` | `AWS/SQS` → `ApproximateAgeOfOldestMessage`; `QueueName` = main queue; `Maximum`, `60s` | Above `120` seconds | `5m` | Messages are waiting too long |
| `Worker-Lambda-Errors` | `AWS/Lambda` → `Errors`; `FunctionName` = worker Lambda; `Sum`, `60s` | Above `0` | `1m` | The Lambda invocation itself returned an error |

These are **demo starting thresholds**, not universal production SLOs. Adjust them to your traffic and processing-time expectations. Set the alert's *No data* behavior thoughtfully: low-traffic queues may not publish every metric when inactive. For this demo, start by treating missing queue metrics as `No Data`/not firing rather than interpreting them automatically as a backlog.

**Important detail about this Worker Lambda:** the sample code catches individual message-processing exceptions and returns `batchItemFailures` to request a retry. That is a successful Lambda invocation from CloudWatch's `Errors` metric perspective, even though a message failed. For that reason, the **DLQ backlog alert is the key signal for repeatedly failing messages**; the Lambda `Errors` alert covers unhandled function-level failures. This distinction prevents a misleading dashboard or alert.

### 11.7 Configure alert notifications (optional)

Grafana can show a rule as `Normal`, `Pending`, or `Firing` without an external notification destination. To send messages outside Grafana:

1. Open **Alerting → Contact points → New contact point**.
2. Choose a destination you already use, such as Slack with an incoming webhook. For email, configure SMTP for the local Grafana container first.
3. Test the contact point, then choose it in the alert rule or route the alert to it through **Notification policies**.

Because this Grafana instance runs on your laptop, its alert evaluations and notifications stop when the container or laptop is stopped or asleep. For 24/7 production alerting, use an always-on monitoring service or native CloudWatch alarms in addition to dashboards.

### 11.8 Test and troubleshoot

1. Send the valid test message from Section 7. Confirm that the worker log appears and the queue charts show activity.
2. Send the intentional failure sample from Section 8. Wait for retries and redrive to finish; SQS/CloudWatch metric updates can take a few minutes. The DLQ backlog should rise and the `SQS-DLQ-Has-Messages` alert should fire.
3. If Grafana shows no data, confirm the selected AWS Region, queue name, Lambda function name, time range, and read-only IAM policy. Confirm the metrics exist in **CloudWatch → Metrics** in the AWS Console.
4. If the alert rule evaluates but no Slack/email message arrives, check the contact point test result and the notification policy routing. A firing rule alone does not send a notification unless it is routed to a contact point.

### 11.9 Stop Grafana when finished

Stop and remove the container when you are done:

```bash
docker stop grafana-sqs
docker rm grafana-sqs
```

The named volume keeps the Grafana dashboard and configuration if you want to start it again. To also delete that local Grafana data, run:

```bash
docker volume rm grafana-sqs-data
```

Revoke or delete the dedicated Grafana read-only access key after the demo if you no longer need it. No Grafana container or dashboard resource is created in AWS, but CloudWatch API calls and log queries can incur charges depending on usage.

