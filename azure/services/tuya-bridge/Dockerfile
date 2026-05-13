# Build context is the repo root so we can pull in shared/.
# Build with: docker build -f azure/services/tuya-bridge/Dockerfile <repo-root>
FROM python:3.11-slim
WORKDIR /srv
COPY azure/services/tuya-bridge/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY shared/ ./shared/
COPY azure/services/tuya-bridge/app/ ./app/
ENV PYTHONPATH=/srv
EXPOSE 8005
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8005"]
