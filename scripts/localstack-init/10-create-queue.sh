#!/bin/sh
# LocalStack 起動後に SQS キューを作る (compose.yaml が ready.d へマウント)
set -eu
QUEUE_NAME="${SQS_QUEUE_NAME:-app-queue}"
echo "[localstack-init] creating SQS queue: ${QUEUE_NAME}"
awslocal sqs create-queue --queue-name "${QUEUE_NAME}" >/dev/null
awslocal sqs list-queues
echo "[localstack-init] done"
