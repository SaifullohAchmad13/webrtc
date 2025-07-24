#!/bin/bash

start_servers() {
  source .env 2>/dev/null

  echo "Starting WebRTC server..."
  python3 server.py -t webrtc > log_webrtc.log 2>&1 &
  WEBRTC_PID=$!
  echo $WEBRTC_PID > webrtc.pid

  echo "IS_LOCAL: $IS_LOCAL"
  if [[ "$IS_LOCAL" -eq 0 ]]; then

    if ! command -v cloudflared &> /dev/null; then
      echo "Installing Cloudflared..."
      apt-get update && apt-get install -y wget sudo
      wget -O cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
      dpkg -i cloudflared.deb
    else
      echo "Cloudflared already installed"
    fi

    echo "Starting Cloudflare Tunnel..."
    cloudflared tunnel --url http://0.0.0.0:$PORT_WEBRTC > log_cloudflared.log 2>&1 &
    CLOUDFLARED_PID=$!
    echo $CLOUDFLARED_PID > cloudflared.pid

    # Also stream log to console so ECS/CloudWatch can see it
    tail -f log_cloudflared.log &
    TAIL_PID=$!

    echo "Waiting for Cloudflare Tunnel URL..."
    while ! grep -q "https://.*trycloudflare.com" log_cloudflared.log; do
      sleep 1
    done

    # Extract and display the URL
    TUNNEL_URL=$(grep -o "https://.*trycloudflare.com" log_cloudflared.log | head -1)
    echo "========================================================"
    echo "Cloudflare Tunnel URL: $TUNNEL_URL"
    echo "========================================================"

    kill $TAIL_PID
  fi
wait $WEBRTC_PID
}
stop_servers() {
  if [ -f webrtc.pid ]; then
    WEBRTC_PID=$(cat webrtc.pid)
    echo "Stopping WebRTC server (PID: $WEBRTC_PID)..."
    kill $WEBRTC_PID
    rm webrtc.pid
  else
    echo "No WebRTC server PID file found."
  fi

  if [ -f cloudflared.pid ]; then
    CLOUDFLARED_PID=$(cat cloudflared.pid)
    echo "Stopping Cloudflared (PID: $CLOUDFLARED_PID)..."
    kill $CLOUDFLARED_PID
    rm cloudflared.pid
  else
    echo "No Cloudflared PID file found."
  fi
}

# Main script execution
if [ "$1" == "start" ]; then
  start_servers
elif [ "$1" == "stop" ]; then
  stop_servers
else
  echo "Usage: $0 [start|stop]"
  exit 1
fi

