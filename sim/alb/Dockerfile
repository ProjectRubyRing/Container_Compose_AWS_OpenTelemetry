# ALB のトレース関連挙動を再現する簡易プロキシ (Compose 専用)
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5
RUN microdnf -y install python3 && microdnf clean all
COPY alb_sim.py /opt/alb_sim.py
EXPOSE 80
ENTRYPOINT ["python3", "-u", "/opt/alb_sim.py"]
