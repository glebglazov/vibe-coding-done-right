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
        # Get most recently active client session
        result = subprocess.run(['tmux', 'list-clients', '-F', '#{client_activity} #{client_session}'],
                              capture_output=True, text=True, check=True)

        clients = result.stdout.strip().split('\n')
        if not clients or not clients[0]:
            print("ERROR: No tmux clients found")
            return None

        # Sort by activity (most recent first) and get the session
        clients.sort(key=lambda x: int(x.split()[0]) if x.split() else 0, reverse=True)
        current_session = clients[0].split()[1] if clients[0].split() else None

        if not current_session:
            print("ERROR: Could not determine active session")
            return None

        print(f"Using most recently active session: {current_session}")

        # Step 1: Get active pane info from target session
        result = subprocess.run(['tmux', 'display-message', '-t', current_session, '-p', '#{session_name}:#{window_index}.#{pane_index} #{pane_title}'],
                              capture_output=True, text=True, check=True)

        active_pane_info = result.stdout.strip()
        active_pane_target = active_pane_info.split()[0]

        if 'Claude' in active_pane_info or 'claude' in active_pane_info:
            print(f"Found Claude in active pane by title: {active_pane_target}")
            return active_pane_target

        # Step 2: Check if active pane runs claude process
        active_pane_pid = get_pane_pid(active_pane_target)
        if active_pane_pid and has_claude_process(active_pane_pid):
            print(f"Found Claude in active pane by process: {active_pane_target}")
            return active_pane_target

        # Step 3: Search only current session for Claude processes
        result = subprocess.run(['tmux', 'list-panes', '-t', current_session, '-F', '#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{pane_pid} #{pane_active}'],
                              capture_output=True, text=True, check=True)

        claude_panes = []
        focused_claude_pane = None

        for line in result.stdout.strip().split('\n'):
            parts = line.split()
            if len(parts) >= 4:
                pane_target = parts[0]
                pane_pid = parts[-2]  # Second to last is PID
                pane_active = parts[-1]  # Last is active status (1 or 0)

                is_claude = False

                # Check title first (legacy method)
                if 'Claude' in line or 'claude' in line:
                    is_claude = True
                    claude_type = "title"
                # Check process tree
                elif has_claude_process(pane_pid):
                    is_claude = True
                    claude_type = "process"

                if is_claude:
                    pane_info = {
                        'target': pane_target,
                        'type': claude_type,
                        'active': pane_active == '1'
                    }
                    claude_panes.append(pane_info)

                    # If this is the focused/active pane, remember it
                    if pane_active == '1':
                        focused_claude_pane = pane_info

        # Step 4: Choose the best Claude pane
        if focused_claude_pane:
            print(f"Found focused Claude pane by {focused_claude_pane['type']} in session {current_session}: {focused_claude_pane['target']}")
            return focused_claude_pane['target']
        elif claude_panes:
            # If no focused Claude pane, return the first one found
            chosen = claude_panes[0]
            print(f"Found Claude pane by {chosen['type']} in session {current_session}: {chosen['target']} (not focused)")
            return chosen['target']

        # No Claude found in current session
        print(f"ERROR: No Claude Code session found in current tmux session '{current_session}'")
        return None

    except subprocess.CalledProcessError:
        print("ERROR: Failed to detect tmux session or panes")
        return None

def get_pane_pid(pane_target):
    try:
        result = subprocess.run(['tmux', 'display-message', '-t', pane_target, '-p', '#{pane_pid}'],
                              capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError:
        return None

def has_claude_process(pane_pid):
    try:
        result = subprocess.run(['ps', '-ef'], capture_output=True, text=True, check=True)
        for line in result.stdout.split('\n'):
            parts = line.split()
            if len(parts) >= 8 and parts[2] == str(pane_pid) and 'claude' in parts[7]:
                return True
        return False
    except subprocess.CalledProcessError:
        return False

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
                return {"transcription": transcription, "sent_to_claude": True, "session": claude_session}
            else:
                print(f"Failed to auto-send to Claude session {claude_session}")
                return {"transcription": transcription, "sent_to_claude": False, "error": f"Failed to send to Claude session {claude_session}"}
        else:
            print("Claude session not found for auto-send")
            return {"transcription": transcription, "sent_to_claude": False, "error": "No Claude Code session found in current tmux session"}

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
