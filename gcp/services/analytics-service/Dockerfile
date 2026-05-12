# Build context is the repo root so we can pull in shared/.
# Build with: docker build -f gcp/services/analytics-service/Dockerfile <repo-root>
FROM python:3.11-slim
WORKDIR /srv
COPY gcp/services/analytics-service/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY shared/ ./shared/
COPY gcp/services/analytics-service/app/ ./app/
ENV PYTHONPATH=/srv
EXPOSE 8004
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8004"]
