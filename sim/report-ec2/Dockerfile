# 帳票 EC2 / 外部 SLB 先のスタブ (Compose 専用 / 計装しない)
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5
RUN microdnf -y install python3 && microdnf clean all
COPY stub.py /opt/stub.py
ENTRYPOINT ["python3", "-u", "/opt/stub.py"]
