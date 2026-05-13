# Build context is the repo root so we can pull in shared/.
# Build with: docker build -f azure/services/device-service/Dockerfile <repo-root>
FROM python:3.11-slim
WORKDIR /srv
COPY azure/services/device-service/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY shared/ ./shared/
COPY azure/services/device-service/app/ ./app/
ENV PYTHONPATH=/srv
EXPOSE 8001
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8001"]
