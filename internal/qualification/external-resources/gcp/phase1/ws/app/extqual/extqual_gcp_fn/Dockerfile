FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir google-cloud-pubsub==2.27.1 google-cloud-storage==2.18.2
COPY main.py /app/main.py
CMD ["python", "/app/main.py"]
