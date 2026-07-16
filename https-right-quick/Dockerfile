FROM python:3.9-slim

RUN apt-get update && apt-get install -y \
    openssl \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /cert && mkdir -p /app

WORKDIR /app

COPY ./web-server.py .

RUN openssl req -x509 -newkey rsa:2048 \
    -keyout /cert/key.pem -out /cert/cert.pem \
    -days 365 -nodes \
    -subj "/C=US/ST=VA/L=VaBeach/O=DojoLabs/OU=Training/CN=dojolabs"  # Edit to your liking

RUN ls /cert
RUN cat /cert/cert.pem
RUN cat /cert/key.pem

RUN pip install python-dotenv

EXPOSE 443
WORKDIR /app/www-data

CMD ["python3", "/app/web-server.py"]
