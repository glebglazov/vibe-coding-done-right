package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
)

// A client learns the version from the server and hands it straight back, so the
// round trip is what has to hold: whatever a 200 carries must produce a 304.
func TestAClientThatEchoesTheVersionItWasGivenIsToldNothingChanged(t *testing.T) {
	body := promptsResponse{}
	first := httptest.NewRecorder()
	promptsHandler(first, httptest.NewRequest(http.MethodGet, "/v1/prompts", nil))
	if first.Code != http.StatusOK {
		t.Fatalf("a client with no cache got %d, wanted 200", first.Code)
	}
	if err := json.Unmarshal(first.Body.Bytes(), &body); err != nil {
		t.Fatalf("the response did not parse: %v", err)
	}
	if body.Version <= 0 {
		t.Fatalf("the version was %d; a client sends ?since= only when it is above zero", body.Version)
	}

	echoed := httptest.NewRecorder()
	promptsHandler(echoed, httptest.NewRequest(http.MethodGet, "/v1/prompts?since="+strconv.FormatInt(body.Version, 10), nil))
	if echoed.Code != http.StatusNotModified {
		t.Fatalf("echoing the served version got %d, wanted 304", echoed.Code)
	}
}

// The version a hand-maintained date could not keep: one that no prompt edit can
// leave behind.
func TestEditingAPromptChangesTheVersion(t *testing.T) {
	before := fingerprint(integrationModePrompts)

	edited := map[string]string{}
	for mode, prompt := range integrationModePrompts {
		edited[mode] = prompt
	}
	edited["dictation"] += "\n"

	if after := fingerprint(edited); after == before {
		t.Fatalf("a changed prompt kept version %d, so every cached client would stay on the old text", after)
	}
}

// Two identical maps must fingerprint alike however Go happens to walk them, or
// a restart would hand every client a fresh version and a pointless refetch.
func TestTheVersionDoesNotDependOnMapOrder(t *testing.T) {
	shuffled := map[string]string{}
	for mode, prompt := range integrationModePrompts {
		shuffled[mode] = prompt
	}
	for i := 0; i < 20; i++ {
		if fingerprint(shuffled) != fingerprint(integrationModePrompts) {
			t.Fatal("the same prompts fingerprinted two ways")
		}
	}
}

// Clients decode this field as a JSON number. Past 2^53 it comes back rounded
// and stops matching itself, and the 304 never fires again.
func TestTheVersionSurvivesAJSONReaderIntact(t *testing.T) {
	if promptsVersion >= 1<<53 {
		t.Fatalf("version %d is past the exact-integer range of a JSON number", promptsVersion)
	}
}

// A version older than the one served is still a version the client does not
// have, and it gets the prompts.
func TestAStaleVersionIsServedTheCurrentPrompts(t *testing.T) {
	recorder := httptest.NewRecorder()
	promptsHandler(recorder, httptest.NewRequest(http.MethodGet, "/v1/prompts?since=1777015728", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("a client on the old hand-maintained date got %d, wanted 200", recorder.Code)
	}
}
