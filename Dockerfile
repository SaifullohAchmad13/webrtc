FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && \
    apt-get install -y git && \
    apt-get install -y wget && \
    apt-get install -y libglib2.0-0 && \
    apt-get install -y libsm6 && \
    apt-get install -y libxrender1 && \
    apt-get install -y libxext6 && \
    apt-get install -y libgl1 && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

RUN pip install -r requirements.txt

RUN  wget -O cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
RUN  dpkg -i cloudflared.deb


COPY . .

RUN chmod +x run.sh

EXPOSE 8005

CMD ["./run.sh", "start"]
