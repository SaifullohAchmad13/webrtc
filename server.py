import asyncio
import sys
import os
import json
from datetime import datetime
from pathlib import Path
from contextlib import asynccontextmanager
from typing import Dict, List, Optional
import platform
import uvicorn
from bot import run_bot
from dotenv import load_dotenv
from fastapi import BackgroundTasks, FastAPI, HTTPException, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel
from loguru import logger
from pipecat_ai_small_webrtc_prebuilt.frontend import SmallWebRTCPrebuiltUI
from pipecat.transports.network.webrtc_connection import IceServer, SmallWebRTCConnection

# Load environment variables
load_dotenv(override=True)

# Define the records directory
RECORDS_DIR = Path("records")
RECORDS_DIR.mkdir(exist_ok=True)


app = FastAPI()

# Configure CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Allows all origins
    allow_credentials=True,
    allow_methods=["*"],  # Allows all methods
    allow_headers=["*"],  # Allows all headers
)

# Store connections by pc_id
pcs_map: Dict[str, SmallWebRTCConnection] = {}


ice_servers = [
    IceServer(urls=os.getenv("STUN_SERVER")),
    IceServer(
        urls=os.getenv("TURN_SERVER"),
        username=os.getenv("TURN_USERNAME"),
        credential=os.getenv("TURN_CREDENTIAL")
    )
]


@app.get("/api/transcripts")
async def list_transcripts():
    """List all available transcript files"""
    try:
        files = []
        for file_path in RECORDS_DIR.glob("*.log"):
            filename = file_path.name
            try:
                timestamp_str = filename.replace(".log", "")
                timestamp_date = datetime.strptime(timestamp_str, "%Y%m%d_%H%M%S")
                formatted_timestamp = timestamp_date.strftime("%Y-%m-%d %H:%M:%S")
            except (ValueError, IndexError):
                formatted_timestamp = "Unknown"

            files.append({
                'filename': filename,
                'timestamp': formatted_timestamp,
            })
        
        return {"files": files}
    except Exception as e:
        logger.error(f"Error listing transcripts: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/transcripts/{filename}")
async def get_transcript(filename: str):
    try:
        file_path = RECORDS_DIR / filename
        if not file_path.exists():
            raise HTTPException(status_code=404, detail="Transcript file not found")
        
        with open(file_path, "r") as f:
            content = f.read()
        return {"content": content}
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error downloading transcript: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/status")
async def status():
    return {"pcs": list(pcs_map.keys())}

@app.post("/api/offer")
async def offer(request: dict, background_tasks: BackgroundTasks):
    pc_id = request.get("pc_id")

    if pc_id and pc_id in pcs_map:
        pipecat_connection = pcs_map[pc_id]
        logger.info(f"Reusing existing connection for pc_id: {pc_id}")
        await pipecat_connection.renegotiate(sdp=request["sdp"], type=request["type"])
    else:
        pipecat_connection = SmallWebRTCConnection(ice_servers)
        await pipecat_connection.initialize(sdp=request["sdp"], type=request["type"])

        @pipecat_connection.event_handler("closed")
        async def handle_disconnected(webrtc_connection: SmallWebRTCConnection):
            logger.info(f"Discarding peer connection for pc_id: {webrtc_connection.pc_id}")
            pcs_map.pop(webrtc_connection.pc_id, None)

        background_tasks.add_task(run_bot, pipecat_connection)

    answer = pipecat_connection.get_answer()
    # Updating the peer connection inside the map
    pcs_map[answer["pc_id"]] = pipecat_connection

    return answer


app.mount("/", SmallWebRTCPrebuiltUI)


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield  # Run app
    coros = [pc.disconnect() for pc in pcs_map.values()]
    await asyncio.gather(*coros)
    pcs_map.clear()


if __name__ == "__main__":
    logger.remove(0)
    logger.add(sys.stderr, level="DEBUG")
    
    if platform.system() == "Darwin":
        host = "localhost"
    else:
        host = "0.0.0.0"
    
    port = int(os.getenv("PORT_WEBRTC"))
    try:
        # More robust port checking and process killing
        import socket
        import signal
        import subprocess
        import time
        
        # Check if port is in use
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        result = sock.connect_ex((host, port))
        if result == 0:
            # Port is in use, find PID
            cmd = f"lsof -i tcp:{port} | grep LISTEN | awk '{{print $2}}'"
            pid_output = subprocess.check_output(cmd, shell=True).decode().strip()
            if pid_output:
                # Kill all matching processes
                for pid in pid_output.split('\n'):
                    if pid:
                        logger.info(f"Port {port} is in use by PID {pid}, attempting to kill")
                        try:
                            # Try SIGTERM first
                            os.kill(int(pid), signal.SIGTERM)
                            # Wait and check if process is still running
                            time.sleep(1)
                            try:
                                os.kill(int(pid), 0)  # Check if process exists
                                # If we get here, process still exists, use SIGKILL
                                logger.info(f"Process {pid} still running, using SIGKILL")
                                os.kill(int(pid), signal.SIGKILL)
                            except OSError:
                                pass  # Process already terminated
                        except OSError as e:
                            logger.warning(f"Failed to kill PID {pid}: {e}")
                
                # Wait to ensure port is freed
                time.sleep(2)
        sock.close()
    except Exception as e:
        logger.warning(f"Failed to check/kill port: {e}")
    
    uvicorn.run(app, host=host, port=port)
