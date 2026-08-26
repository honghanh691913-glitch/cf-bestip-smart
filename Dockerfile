FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Asia/Shanghai

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

COPY install_cfst.py /app/install_cfst.py
RUN python3 /app/install_cfst.py

COPY bestip_orchestrator.py scheduler.py healthcheck.py config.json worker.js VERSION.txt /app/
COPY ranges /app/ranges

RUN mkdir -p /app/generated /app/runtime \
    && chmod +x /app/bestip_orchestrator.py /app/scheduler.py /app/healthcheck.py /app/cfst

CMD ["python3", "/app/scheduler.py"]
