# Ollama Setup Guide

## Quick Start

### 1. Install Ollama

```bash
# Install Ollama
brew install ollama

# Or download from: https://ollama.com
```

### 2. Start Ollama Service

```bash
# Start Ollama server (runs on http://localhost:11434)
ollama serve
```

### 3. Pull a Model

```bash
# Recommended for vcdr (fast, good quality, low memory ~4GB)
ollama pull llama3.2:3b

# OR for better quality (slower, ~12GB memory)
ollama pull gemma2:9b

# OR for code/technical content
ollama pull qwen2.5-coder:7b
```

### 4. Run vcdr

vcdr will automatically detect and use Ollama if it's running. Otherwise, it falls back to Apple Foundation Models.

## Available Models

### Fast & Lightweight (Recommended for M1/M2)
- `llama3.2:3b` - Best balance of speed/quality (~4GB)
- `qwen2.5:3b` - Good for general tasks

### High Quality (M2 Pro/Max, M3+)
- `gemma2:9b` - Excellent reasoning (~12GB)
- `qwen2.5-coder:7b` - Best for code (~8GB)
- `llama3.1:8b` - Strong all-rounder (~8GB)

### Maximum Quality (M3 Max/Ultra with 64GB+)
- `gemma2:27b` - Top-tier quality (~24GB)
- `qwen2.5:32b` - Excellent for complex tasks (~32GB)

## Changing Models

Edit `ModeManager.swift` line 52:

```swift
let ollamaProvider = OllamaProvider(modelName: "llama3.2:3b")
```

Change to your preferred model:
```swift
let ollamaProvider = OllamaProvider(modelName: "gemma2:9b")
```

## Testing

```bash
# Test Ollama is running
curl http://localhost:11434/api/tags

# Test a model directly
curl http://localhost:11434/api/generate -d '{
  "model": "llama3.2:3b",
  "prompt": "Why is the sky blue?",
  "stream": false
}'
```

## Troubleshooting

### "Ollama is not running"
```bash
# Start Ollama in terminal
ollama serve
```

### "Model not found"
```bash
# Pull the model first
ollama pull llama3.2:3b
```

### Check available models
```bash
ollama list
```

### Performance Tips
- Use smaller models (3B-7B) for fast responses
- Use larger models (9B-27B) for better quality
- Monitor memory usage with Activity Monitor
- On M1/M2 with 8-16GB RAM: stick to 3B models
- On M2 Pro/Max with 32GB+: 7B-9B models work great
- On M3 Max with 64GB+: 27B models are usable

## Integration Details

vcdr uses the Ollama REST API:
- **Endpoint**: `POST http://localhost:11434/api/generate`
- **Timeout**: None (waits for full response)
- **Streaming**: Disabled (for simplicity)
- **Temperature**: 0.7
- **Top-p**: 0.9

See `vcdr/Services/OllamaProvider.swift` for implementation.
