FROM postgres:17-alpine
RUN apk add --no-cache python3
COPY observer.py /opt/echo-security/observer.py
USER 65532:65532
ENTRYPOINT ["python3", "-B", "/opt/echo-security/observer.py"]
