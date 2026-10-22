# Komodor's base image already holds komodor_agentops 0.4.9 and httpx; only the wrapper is added.
FROM ghcr.io/komodorio/agentops-agent-base:0.1.2202
COPY worker.py /app/dotai/worker.py
WORKDIR /app/dotai
ENTRYPOINT ["/app/.venv/bin/python", "/app/dotai/worker.py"]
