from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from pydantic import BaseModel
import whisper
import tempfile
import os
import subprocess
import re

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

model = whisper.load_model("small")

class TextRequest(BaseModel):
    text: str

def find_claude_session():
    try:
        # Step 1: Get the currently active pane
        result = subprocess.run(['tmux', 'display-message', '-p', '#{session_name}:#{window_index}.#{pane_index} #{pane_title}'],
                              capture_output=True, text=True, check=True)

        active_pane_info = result.stdout.strip()
        active_pane_target = active_pane_info.split()[0]

        # Step 2: Check if active pane has Claude in title (highest priority)
        if 'Claude' in active_pane_info or 'claude' in active_pane_info:
            print(f"Smart detection: Active pane IS Claude: {active_pane_target}")
            return active_pane_target

        # Step 3: Active pane is not Claude, search for any Claude pane
        result = subprocess.run(['tmux', 'list-panes', '-a', '-F', '#{session_name}:#{window_index}.#{pane_index} #{pane_title}'],
                              capture_output=True, text=True, check=True)

        for line in result.stdout.strip().split('\n'):
            if 'Claude' in line or 'claude' in line:
                claude_pane_target = line.split()[0]
                print(f"Smart detection: Found Claude pane: {claude_pane_target} (active pane: {active_pane_target})")
                return claude_pane_target

        # Step 4: No Claude pane found anywhere, use active pane as fallback
        print(f"Smart detection: No Claude pane found, using active pane: {active_pane_target}")
        return active_pane_target

    except subprocess.CalledProcessError:
        return None

def send_to_tmux(session_target: str, text: str):
    try:
        subprocess.run(['tmux', 'send-keys', '-t', session_target, text], check=True)
        return True
    except subprocess.CalledProcessError:
        return False

@app.post("/transcribe")
async def transcribe_audio(file: UploadFile = File(...)):
    if not file.content_type.startswith("audio/"):
        raise HTTPException(status_code=400, detail="File must be an audio file")

    with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as temp_file:
        content = await file.read()
        temp_file.write(content)
        temp_file_path = temp_file.name

    try:
        result = model.transcribe(temp_file_path)
        transcription = result["text"]

        print(f"Transcription: {transcription}")

        # Auto-send to Claude
        claude_session = find_claude_session()
        if claude_session:
            success = send_to_tmux(claude_session, transcription)
            if success:
                print(f"Auto-sent to Claude session {claude_session}: {transcription}")
            else:
                print(f"Failed to auto-send to Claude session {claude_session}")
        else:
            print("Claude session not found for auto-send")

        return {"transcription": transcription}

    finally:
        os.unlink(temp_file_path)

@app.get("/", response_class=HTMLResponse)
async def frontend():
    with open("index.html", "r") as f:
        html_content = f.read()
    return html_content

@app.post("/send-to-claude")
async def send_to_claude(request: TextRequest):
    claude_session = find_claude_session()

    if not claude_session:
        raise HTTPException(status_code=404, detail="Claude Code session not found")

    success = send_to_tmux(claude_session, request.text)

    if not success:
        raise HTTPException(status_code=500, detail="Failed to send text to Claude session")

    print(f"Sent to Claude session {claude_session}: {request.text}")
    return {"success": True, "session": claude_session, "message": "Text sent to Claude Code"}

@app.get("/api")
async def root():
    return {"message": "Voice Transcription API is running"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
