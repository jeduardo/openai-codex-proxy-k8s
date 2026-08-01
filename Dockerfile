FROM python:3.12-slim

ARG APP_VERSION=0.1.3

RUN groupadd --gid 10001 codex \
    && useradd --no-log-init --uid 10001 --gid codex --home-dir /home/codex --create-home codex \
    && pip install --no-cache-dir "openai-api-server-via-codex==${APP_VERSION}"

USER 10001:10001
WORKDIR /home/codex
EXPOSE 18080

ENTRYPOINT ["openai-api-server-via-codex"]
CMD ["--host", "0.0.0.0", "--port", "18080"]
