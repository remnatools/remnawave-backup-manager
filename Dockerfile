FROM python:3.12-slim

RUN apt-get update && apt-get install -y rsync openssh-client sshpass cron curl && \
    curl -fsSL https://get.docker.com | sh && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN pip install --no-cache-dir fastapi uvicorn jinja2 python-multipart

COPY app/ /app/
COPY templates/ /app/templates/

RUN mkdir -p /app/data /var/log

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8090"]
