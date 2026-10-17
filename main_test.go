package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealth(t *testing.T) {
	old := version
	t.Cleanup(func() { version = old })
	version = "v9.9.9"
	rec := httptest.NewRecorder()
	handleHealth(rec, httptest.NewRequest(http.MethodGet, "/health", nil))

	var got map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if rec.Code != 200 || got["status"] != "ok" || got["version"] != "v9.9.9" {
		t.Fatalf("got %d %v", rec.Code, got)
	}
}
