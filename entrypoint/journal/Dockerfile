FROM python:3.13-slim
# 표준 라이브러리만 쓴다(weights-api 와 같은 모양). 비루트로 돌고 /data(볼륨)에 SQLite 를 둔다.
RUN useradd --uid 1002 --user-group --no-create-home journal \
 && mkdir -p /data && chown 1002:1002 /data
COPY app.py /app/app.py
USER 1002:1002
EXPOSE 8081
HEALTHCHECK --interval=30s --timeout=3s --retries=3 --start-period=10s --start-interval=2s \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8081/health', timeout=2).status==200 else 1)"
CMD ["python", "-u", "/app/app.py"]
