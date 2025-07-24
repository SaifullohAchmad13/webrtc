#!/bin/bash

# Function to start all servers
start_servers() {
  # Load environment variables from .env if it exists
  # Redirects stderr to /dev/null to suppress "No such file or directory" if .env is missing
  source .env 2>/dev/null

  echo "Starting WebRTC server..."
  # Start WebRTC server in the background, redirecting its stdout and stderr to a log file
  python3 server.py -t webrtc > log_webrtc.log 2>&1 &
  WEBRTC_PID=$! # Capture the PID of the background process
  echo $WEBRTC_PID > webrtc.pid # Store PID in a file for later stopping

  echo "IS_LOCAL: $IS_LOCAL"
  # Check if IS_LOCAL environment variable is set to 0 (indicating not local, likely on ECS)
  if [[ "$IS_LOCAL" -eq 0 ]]; then

    # Check if cloudflared command exists
    if ! command -v cloudflared &> /dev/null; then
      echo "Installing Cloudflared..."
      # Install cloudflared if not found. Requires sudo for apt-get and dpkg.
      # In ECS, ensure your task definition has appropriate permissions or run as root/privileged if necessary.
      # For many ECS setups, it's better to install cloudflared as part of your Dockerfile build.
      sudo apt-get update && sudo apt-get install -y wget
      wget -O cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
      sudo dpkg -i cloudflared.deb
      # Clean up the .deb file after installation
      rm cloudflared.deb
    else
      echo "Cloudflared already installed"
    fi

    echo "Starting Cloudflare Tunnel..."
    # Start Cloudflare Tunnel in the background, redirecting its output to a log file
    cloudflared tunnel --url http://0.0.0.0:$PORT_WEBRTC > log_cloudflared.log 2>&1 &
    CLOUDFLARED_PID=$! # Capture the PID of the background process
    echo $CLOUDFLARED_PID > cloudflared.pid # Store PID in a file

    # Stream log_cloudflared.log to console (stdout) so ECS/CloudWatch can see it
    # This process will now run for the duration of the cloudflared tunnel
    tail -f log_cloudflared.log &
    TAIL_PID=$! # Capture the PID of the tail process
    echo $TAIL_PID > tail.pid # Store PID in a file

    echo "Waiting for Cloudflare Tunnel URL..."
    # Loop until the Cloudflare Tunnel URL appears in the log file
    while ! grep -q "https://.*trycloudflare.com" log_cloudflared.log; do
      sleep 1 # Wait 1 second before retrying
    done

    # Extract and display the URL from the log file
    TUNNEL_URL=$(grep -o "https://.*trycloudflare.com" log_cloudflared.log | head -1)
    echo "========================================================"
    echo "Cloudflare Tunnel URL: $TUNNEL_URL"
    echo "========================================================"

    # IMPORTANT: Do NOT kill $TAIL_PID here. It needs to continue streaming the logs.
    # The TAIL_PID will be killed in the stop_servers function when the container exits or is stopped.
  fi

  # Wait for the WebRTC server process to finish.
  # In an ECS context, this means the script will keep running as long as WEBRTC_PID is alive.
  # This is usually desired so the container stays "running".
  wait $WEBRTC_PID
}

# Function to stop all servers and clean up PID files
stop_servers() {
  echo "Stopping all services..."

  # Stop WebRTC server
  if [ -f webrtc.pid ]; then
    WEBRTC_PID=$(cat webrtc.pid)
    echo "Stopping WebRTC server (PID: $WEBRTC_PID)..."
    kill "$WEBRTC_PID" # Use double quotes for robustness
    rm webrtc.pid
  else
    echo "No WebRTC server PID file found."
  fi

  # Stop Cloudflared tunnel
  if [ -f cloudflared.pid ]; then
    CLOUDFLARED_PID=$(cat cloudflared.pid)
    echo "Stopping Cloudflared (PID: $CLOUDFLARED_PID)..."
    kill "$CLOUDFLARED_PID"
    rm cloudflared.pid
  else
    echo "No Cloudflared PID file found."
  fi

  # Stop the background log streamer (tail -f)
  if [ -f tail.pid ]; then
    TAIL_PID=$(cat tail.pid)
    echo "Stopping log streamer (PID: $TAIL_PID)..."
    kill "$TAIL_PID"
    rm tail.pid
  else
    echo "No log streamer PID file found."
  fi

  echo "All services stopped."
}

# Main script execution logic
# This part determines whether to start or stop services based on the first argument.
if [ "$1" == "start" ]; then
  # Trap SIGTERM (signal 15) and SIGINT (signal 2) to ensure graceful shutdown
  # When ECS stops a task, it typically sends a SIGTERM.
  trap 'stop_servers; exit 0' SIGTERM SIGINT
  start_servers
elif [ "$1" == "stop" ]; then
  stop_servers
else
  echo "Usage: $0 [start|stop]"
  exit 1 # Exit with an error code if no valid argument is provided
fi