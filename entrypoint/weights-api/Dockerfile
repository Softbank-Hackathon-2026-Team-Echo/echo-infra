FROM python:3.13-slim
# 표준 라이브러리만 쓴다. 비루트로 돌고, Envoy 와 공유하는 디렉터리를 소유한다.
RUN useradd --uid 1001 --user-group --no-create-home weights \
 && mkdir -p /etc/envoy/dynamic/state \
 && chown -R 1001:1001 /etc/envoy/dynamic
COPY app.py /app/app.py
USER 1001:1001
EXPOSE 8080
# 기동 때(compose depends_on 게이트)는 2초 간격, 그 뒤엔 30초. 매번 python 을 띄우므로 자주 돌리지 않는다.
HEALTHCHECK --interval=30s --timeout=3s --retries=3 --start-period=10s --start-interval=2s \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).status==200 else 1)"
CMD ["python", "-u", "/app/app.py"]
