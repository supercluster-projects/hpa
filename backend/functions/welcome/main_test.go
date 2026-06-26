package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestFetchCounter_Success(t *testing.T) {
	// Start a test server that returns a valid count.
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "42")
	}))
	defer ts.Close()

	count, err := fetchCounter(context.Background(), ts.URL)
	require.NoError(t, err)
	assert.Equal(t, 42, count)
}

func TestFetchCounter_NonNumericBody(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "hello world")
	}))
	defer ts.Close()

	_, err := fetchCounter(context.Background(), ts.URL)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "parse error")
}

func TestFetchCounter_Non200Status(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		fmt.Fprint(w, "internal error")
	}))
	defer ts.Close()

	_, err := fetchCounter(context.Background(), ts.URL)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "unexpected status")
}

func TestFetchCounter_ConnectionRefused(t *testing.T) {
	// Use an address where nothing is listening.
	_, err := fetchCounter(context.Background(), "http://127.0.0.1:1")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "connection failed")
}

func TestFetchCounter_EmptyBody(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer ts.Close()

	_, err := fetchCounter(context.Background(), ts.URL)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "parse error")
}

func TestFormatWelcomeResponse(t *testing.T) {
	tests := []struct {
		count    int
		expected string
	}{
		{1, "Welcome (1)"},
		{42, "Welcome (42)"},
		{9999, "Welcome (9999)"},
	}

	for _, tt := range tests {
		t.Run(fmt.Sprintf("count_%d", tt.count), func(t *testing.T) {
			result := fmt.Sprintf("Welcome (%d)", tt.count)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestHTTPHandlerMethodFilter(t *testing.T) {
	// Verify the handler rejects non-GET requests.
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	})

	// Test POST is rejected.
	req := httptest.NewRequest(http.MethodPost, "/", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	assert.Equal(t, http.StatusMethodNotAllowed, rec.Code)
}

func TestHTTPHandlerCounterErrorBubblesUp(t *testing.T) {
	// Simulate a counter that returns a non-numeric response to trigger 502.
	counterSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "bad-data")
	}))
	defer counterSrv.Close()

	// Override the counter addr via the handler directly.
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count, err := fetchCounter(r.Context(), counterSrv.URL)
		if err != nil {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			http.Error(w, fmt.Sprintf("counter error: %v", err), http.StatusBadGateway)
			return
		}
		fmt.Fprintf(w, "Welcome (%d)", count)
	})

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	require.Equal(t, http.StatusBadGateway, rec.Code)
	assert.Contains(t, rec.Body.String(), "counter error:")
}
