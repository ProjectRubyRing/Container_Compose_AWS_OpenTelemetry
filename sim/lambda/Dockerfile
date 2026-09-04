# SQS -> ALB -> back を中継する Lambda スタブ (Compose 専用)
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5
RUN microdnf -y install python3 && microdnf clean all
COPY sqs_to_alb.py /opt/sqs_to_alb.py
ENTRYPOINT ["python3", "-u", "/opt/sqs_to_alb.py"]
