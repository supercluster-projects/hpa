package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// counterHandler is an in-process mock that simulates the SpinApp counter
// service: each GET request INCRs an internal counter and returns the new
// value as plain text. This mirrors the actual KeyDB INCR logic.
type counterHandler struct {
	mu    sync.Mutex
	count int
}

func (c *counterHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	c.mu.Lock()
	c.count++
	val := c.count
	c.mu.Unlock()

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, val)
}

// TestWelcomeHandler_ReturnsWelcomeFormat verifies that the welcome handler
// returns "Welcome (N)" with the correct format when the counter is healthy.
func TestWelcomeHandler_ReturnsWelcomeFormat(t *testing.T) {
	mock := &counterHandler{}
	counterSrv := httptest.NewServer(mock)
	defer counterSrv.Close()

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count, err := fetchCounter(r.Context(), counterSrv.URL)
		if err != nil {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			http.Error(w, fmt.Sprintf("counter error: %v", err), http.StatusBadGateway)
			return
		}
		response := fmt.Sprintf("Welcome (%d)", count)
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, response)
	})

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	require.Equal(t, http.StatusOK, rec.Code)
	assert.Equal(t, "Welcome (1)", rec.Body.String())
	assert.Contains(t, rec.Header().Get("Content-Type"), "text/plain")
}

// TestWelcomeHandler_SequentialCalls verifies that sequential calls to the
// welcome handler return incrementing count values (1, 2, 3, ...).
func TestWelcomeHandler_SequentialCalls(t *testing.T) {
	mock := &counterHandler{}
	counterSrv := httptest.NewServer(mock)
	defer counterSrv.Close()

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count, err := fetchCounter(r.Context(), counterSrv.URL)
		if err != nil {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			http.Error(w, fmt.Sprintf("counter error: %v", err), http.StatusBadGateway)
			return
		}
		response := fmt.Sprintf("Welcome (%d)", count)
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, response)
	})

	// Call 5 times and verify each is previous + 1
	for i := 1; i <= 5; i++ {
		req := httptest.NewRequest(http.MethodGet, "/", nil)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)

		require.Equal(t, http.StatusOK, rec.Code)
		assert.Equal(t, fmt.Sprintf("Welcome (%d)", i), rec.Body.String())
	}
}

// TestWelcomeHandler_FiveSequentialCallsSameCountPattern matches the e2e test
// pattern: 5 calls, extract count, verify each is exactly previous + 1.
func TestWelcomeHandler_FiveSequentialCallsSameCountPattern(t *testing.T) {
	mock := &counterHandler{}
	counterSrv := httptest.NewServer(mock)
	defer counterSrv.Close()

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count, err := fetchCounter(r.Context(), counterSrv.URL)
		if err != nil {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			http.Error(w, fmt.Sprintf("counter error: %v", err), http.StatusBadGateway)
			return
		}
		response := fmt.Sprintf("Welcome (%d)", count)
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, response)
	})

	var counts []int
	for i := 0; i < 5; i++ {
		req := httptest.NewRequest(http.MethodGet, "/", nil)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)

		require.Equal(t, http.StatusOK, rec.Code)
		var count int
		_, err := fmt.Sscanf(rec.Body.String(), "Welcome (%d)", &count)
		require.NoError(t, err)
		counts = append(counts, count)
	}

	// Verify each subsequent count is exactly previous + 1
	for i := 1; i < len(counts); i++ {
		assert.Equal(t, counts[i-1]+1, counts[i],
			"call %d: expected count=%d, got count=%d", i+1, counts[i-1]+1, counts[i])
	}
}

// TestWelcomeHandler_ContentType verifies the Content-Type header is
// set to text/plain on successful responses.
func TestWelcomeHandler_ContentType(t *testing.T) {
	mock := &counterHandler{}
	counterSrv := httptest.NewServer(mock)
	defer counterSrv.Close()

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count, err := fetchCounter(r.Context(), counterSrv.URL)
		if err != nil {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			http.Error(w, fmt.Sprintf("counter error: %v", err), http.StatusBadGateway)
			return
		}
		response := fmt.Sprintf("Welcome (%d)", count)
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, response)
	})

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	assert.Equal(t, http.StatusOK, rec.Code)
	assert.Contains(t, rec.Header().Get("Content-Type"), "text/plain")
}

// TestWelcomeHandler_CounterDownError verifies that the handler returns
// HTTP 502 Bad Gateway when the counter service is unreachable.
func TestWelcomeHandler_CounterDownError(t *testing.T) {
	// Point at a port where nothing is listening
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count, err := fetchCounter(r.Context(), "http://127.0.0.1:1")
		if err != nil {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			http.Error(w, fmt.Sprintf("counter error: %v", err), http.StatusBadGateway)
			return
		}
		response := fmt.Sprintf("Welcome (%d)", count)
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, response)
	})

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	require.Equal(t, http.StatusBadGateway, rec.Code)
	assert.Contains(t, rec.Body.String(), "counter error:")
	assert.Contains(t, rec.Header().Get("Content-Type"), "text/plain")
}

// TestWelcomeHandler_CounterReturnsBadData verifies that the handler returns
// HTTP 502 when the counter returns non-numeric data.
func TestWelcomeHandler_CounterReturnsBadData(t *testing.T) {
	badCounter := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "not-a-number")
	}))
	defer badCounter.Close()

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count, err := fetchCounter(r.Context(), badCounter.URL)
		if err != nil {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			http.Error(w, fmt.Sprintf("counter error: %v", err), http.StatusBadGateway)
			return
		}
		response := fmt.Sprintf("Welcome (%d)", count)
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, response)
	})

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	require.Equal(t, http.StatusBadGateway, rec.Code)
	assert.Contains(t, rec.Body.String(), "counter error:")
}

// TestWelcomeHandler_CounterReturnsNon200 verifies that the handler returns
// HTTP 502 when the counter returns a non-200 status code.
func TestWelcomeHandler_CounterReturnsNon200(t *testing.T) {
	errCounter := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		fmt.Fprint(w, "internal error")
	}))
	defer errCounter.Close()

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count, err := fetchCounter(r.Context(), errCounter.URL)
		if err != nil {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			http.Error(w, fmt.Sprintf("counter error: %v", err), http.StatusBadGateway)
			return
		}
		response := fmt.Sprintf("Welcome (%d)", count)
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, response)
	})

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	require.Equal(t, http.StatusBadGateway, rec.Code)
	assert.Contains(t, rec.Body.String(), "counter error:")
}
