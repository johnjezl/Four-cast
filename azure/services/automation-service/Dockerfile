# Build context is the repo root so we can pull in shared/.
# Build with: docker build -f azure/services/automation-service/Dockerfile <repo-root>
FROM python:3.11-slim
WORKDIR /srv
COPY azure/services/automation-service/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY shared/ ./shared/
COPY azure/services/automation-service/app/ ./app/
ENV PYTHONPATH=/srv
EXPOSE 8002
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8002"]
