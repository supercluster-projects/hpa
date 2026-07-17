package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/hpa/backend/internal/config"
)

const (
	// Default counter service address (overridden by COUNTER_ADDR env var).
	defaultCounterAddr = "http://counter.hpa-workloads.svc.cluster.local:8080"
	// Read timeout for the counter HTTP request.
	counterTimeout = 5 * time.Second
)

func main() {
	// Use config package for defaults
	addr := config.GetEnvOrDefault(config.EnvVarPort, config.PortWelcomeService)
	counterAddr := config.GetEnvOrDefault("COUNTER_ADDR", defaultCounterAddr)

	mux := http.NewServeMux()

	// Health check endpoint
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(config.HeaderContentType, config.ContentTypePlainText)
		w.WriteHeader(config.StatusOK)
		fmt.Fprint(w, "OK")
	})

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", config.StatusMethodNotAllowed)
			return
		}

		count, err := fetchCounter(r.Context(), counterAddr)
		if err != nil {
			slog.Error("counter fetch failed", "error", err, "counter_addr", counterAddr)
			w.Header().Set(config.HeaderContentType, config.ContentTypePlainText)
			http.Error(w, fmt.Sprintf("counter error: %v", err), config.StatusBadGateway)
			return
		}

		response := fmt.Sprintf("Welcome (%d)", count)
		slog.Info("returning welcome response", "response", response, "counter_addr", counterAddr)

		w.Header().Set(config.HeaderContentType, config.ContentTypePlainText)
		w.WriteHeader(config.StatusOK)
		fmt.Fprint(w, response)
	})

	srv := &http.Server{
		Addr:              ":" + addr,
		Handler:           mux,
		ReadTimeout:       15 * time.Second,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// Setup graceful shutdown
	done := make(chan os.Signal, 1)
	signal.Notify(done, os.Interrupt, syscall.SIGTERM)

	go func() {
		slog.Info("welcome function starting", "addr", ":"+addr, "counter_addr", counterAddr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("server error", "error", err)
			os.Exit(1)
		}
	}()

	<-done
	slog.Info("shutting down gracefully")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		slog.Error("server shutdown failed", "error", err)
		os.Exit(1)
	}

	slog.Info("server stopped")
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
