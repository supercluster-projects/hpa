package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	// Default counter service address (overridden by COUNTER_ADDR env var).
	defaultCounterAddr = "http://counter.hpa-workloads.svc.cluster.local:8080"
	// Read timeout for the counter HTTP request.
	counterTimeout = 5 * time.Second
)

func main() {
	counterAddr := os.Getenv("COUNTER_ADDR")
	if counterAddr == "" {
		counterAddr = defaultCounterAddr
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		count, err := fetchCounter(r.Context(), counterAddr)
		if err != nil {
			log.Printf("ERROR: counter fetch failed: %v", err)
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			http.Error(w, fmt.Sprintf("counter error: %v", err), http.StatusBadGateway)
			return
		}

		response := fmt.Sprintf("Welcome (%d)", count)
		log.Printf("INFO: returning welcome response: %q", response)

		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, response)
	})

	addr := ":8080"
	log.Printf("INFO: welcome function starting on %s, counter addr: %s", addr, counterAddr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("FATAL: server failed: %v", err)
	}
}

// fetchCounter calls the counter service and parses the response body as an integer.
// The counter service is expected to return a plain-text integer (e.g. "42").
func fetchCounter(ctx context.Context, addr string) (int, error) {
	client := &http.Client{Timeout: counterTimeout}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, addr, nil)
	if err != nil {
		return 0, fmt.Errorf("request creation failed: %w", err)
	}

	resp, err := client.Do(req)
	if err != nil {
		return 0, fmt.Errorf("connection failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("unexpected status: %d %s", resp.StatusCode, resp.Status)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, fmt.Errorf("read failed: %w", err)
	}

	raw := strings.TrimSpace(string(body))
	count, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fmt.Errorf("parse error: body=%q: %w", raw, err)
	}

	return count, nil
}
