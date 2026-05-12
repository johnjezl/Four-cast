# Build context is the repo root so we can pull in shared/.
# Build with: docker build -f aws/services/tuya-bridge/Dockerfile <repo-root>
FROM python:3.11-slim
WORKDIR /srv
COPY aws/services/tuya-bridge/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY shared/ ./shared/
COPY aws/services/tuya-bridge/app/ ./app/
ENV PYTHONPATH=/srv
EXPOSE 8005
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8005"]
