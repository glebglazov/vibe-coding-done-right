# Claude Code Configuration

This file contains configuration and instructions for working with this project using Claude Code.

## Project Overview

Voice-to-Claude Transcription System - A FastAPI application that transcribes audio using OpenAI Whisper and automatically sends transcribed text to Claude Code sessions via tmux.

## Development Commands

### Start Development Server
```bash
uv run python main.py
```

### Install Dependencies
```bash
uv sync
```

### Lint and Type Check
```bash
# Add lint command when available
# Add typecheck command when available
```

## Project Structure

```
├── main.py              # FastAPI application with Whisper integration
├── index.html           # Web frontend for audio recording
├── pyproject.toml       # Python project configuration
├── README.md            # Project documentation
└── CLAUDE.md           # This file
```

## Key Files to Know

- `main.py:21` - Whisper model loading
- `main.py:64` - Main transcription endpoint
- `main.py:26` - tmux Claude session detection logic
- `main.py:102` - Manual text sending endpoint

## Development Notes

- Uses OpenAI Whisper `base` model by default
- Smart tmux integration with Claude Code session detection
- CORS enabled for web frontend
- Automatic cleanup of temporary audio files
- Built-in HTML frontend served at root path

## Testing

- Manual testing via web interface at http://localhost:8000
- API testing via curl commands (see README.md)
- Check tmux integration by monitoring console output

## Dependencies

- FastAPI for web framework
- OpenAI Whisper for speech recognition
- uvicorn for ASGI server
- python-multipart for file uploads

## Common Tasks

1. **Add new API endpoint**: Extend `main.py` with new route
2. **Modify transcription**: Update Whisper model or parameters in `main.py:21`
3. **Frontend changes**: Edit `index.html`
4. **tmux integration**: Modify session detection in `find_claude_session()`