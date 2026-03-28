package main

import (
	"encoding/json"
	"log"
	"net/http"
	"time"
)

type processRequest struct {
	IntegrationMode string `json:"integration_mode"`
	Text            string `json:"text"`
	// Future: custom mode fields
	Model     string `json:"model,omitempty"`
	MaxTokens int    `json:"max_tokens,omitempty"`
	System    string `json:"system,omitempty"` // Only used when integration_mode == "custom"
}

type processResponse struct {
	Text string `json:"text"`
}

type errorResponse struct {
	Error string `json:"error"`
}

func processHandler(client *anthropicClient) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, errorResponse{Error: "method not allowed"})
			return
		}

		var req processRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse{Error: "invalid JSON: " + err.Error()})
			return
		}

		if req.Text == "" {
			writeJSON(w, http.StatusBadRequest, errorResponse{Error: "text is required"})
			return
		}

		if req.IntegrationMode == "" {
			writeJSON(w, http.StatusBadRequest, errorResponse{Error: "integration_mode is required"})
			return
		}

		var systemPrompt string

		if req.IntegrationMode == "custom" {
			systemPrompt = req.System
		} else {
			prompt, ok := integrationModePrompts[req.IntegrationMode]
			if !ok {
				writeJSON(w, http.StatusBadRequest, errorResponse{
					Error: "unknown integration_mode: " + req.IntegrationMode,
				})
				return
			}
			systemPrompt = prompt
		}

		start := time.Now()
		result, err := client.process(systemPrompt, req.Text, req.Model, req.MaxTokens)
		llmDuration := time.Since(start)

		if err != nil {
			log.Printf("ERROR processing request (LLM took %s): %v", llmDuration, err)
			writeJSON(w, http.StatusBadGateway, errorResponse{Error: "LLM processing failed"})
			return
		}

		log.Printf("Processed %s in %s (input: %d chars, output: %d chars)",
			req.IntegrationMode, llmDuration, len(req.Text), len(result))
		writeJSON(w, http.StatusOK, processResponse{Text: result})
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}
