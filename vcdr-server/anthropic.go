package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

const (
	anthropicAPIURL     = "https://api.anthropic.com/v1/messages"
	anthropicAPIVersion = "2023-06-01"
	defaultModel        = "claude-haiku-4-5-20251001"
	defaultMaxTokens    = 1024
	httpClientTimeout   = 30 * time.Second
)

type anthropicClient struct {
	apiKey     string
	httpClient *http.Client
}

func newAnthropicClient(apiKey string) *anthropicClient {
	return &anthropicClient{
		apiKey: apiKey,
		httpClient: &http.Client{
			Timeout: httpClientTimeout,
		},
	}
}

type apiMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type apiRequest struct {
	Model     string       `json:"model"`
	MaxTokens int          `json:"max_tokens"`
	System    string       `json:"system,omitempty"`
	Messages  []apiMessage `json:"messages"`
}

type apiContentBlock struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type apiResponse struct {
	Content []apiContentBlock `json:"content"`
	Error   *apiError         `json:"error,omitempty"`
}

type apiError struct {
	Type    string `json:"type"`
	Message string `json:"message"`
}

func (c *anthropicClient) process(systemPrompt, text, model string, maxTokens int) (string, error) {
	if model == "" {
		model = defaultModel
	}
	if maxTokens <= 0 {
		maxTokens = defaultMaxTokens
	}

	reqBody := apiRequest{
		Model:     model,
		MaxTokens: maxTokens,
		System:    systemPrompt,
		Messages: []apiMessage{
			{Role: "user", Content: text},
		},
	}

	body, err := json.Marshal(reqBody)
	if err != nil {
		return "", fmt.Errorf("marshal request: %w", err)
	}

	req, err := http.NewRequest(http.MethodPost, anthropicAPIURL, bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", c.apiKey)
	req.Header.Set("anthropic-version", anthropicAPIVersion)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("send request: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read response: %w", err)
	}

	var apiResp apiResponse
	if err := json.Unmarshal(respBody, &apiResp); err != nil {
		return "", fmt.Errorf("unmarshal response: %w", err)
	}

	if apiResp.Error != nil {
		return "", fmt.Errorf("anthropic API error (%s): %s", apiResp.Error.Type, apiResp.Error.Message)
	}

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("anthropic API returned status %d: %s", resp.StatusCode, string(respBody))
	}

	if len(apiResp.Content) == 0 {
		return "", fmt.Errorf("empty response from anthropic API")
	}

	return apiResp.Content[0].Text, nil
}
