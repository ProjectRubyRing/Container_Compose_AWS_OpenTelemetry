# EC2 バッチサーバのスタブ (Compose 専用 / 計装しない)
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5
RUN microdnf -y install shadow-utils tar gzip && microdnf clean all \
 && (microdnf -y install curl-minimal || microdnf -y install curl) && microdnf clean all
COPY batch.sh /opt/batch.sh
RUN sed -i 's/\r$//' /opt/batch.sh && chmod 0755 /opt/batch.sh
ENTRYPOINT ["/opt/batch.sh"]
