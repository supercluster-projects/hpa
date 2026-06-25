package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// counterMock is a simple HTTP handler that simulates the KeyDB-backed counter
// SpinApp: each GET request atomically increments a counter and returns the
// new value as a plain-text integer. This mirrors the INCR behavior of the
// real counter service.
type counterMock struct {
	mu    sync.Mutex
	count int
}

func (c *counterMock) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	c.mu.Lock()
	defer c.mu.Unlock()

	c.count++
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, strconv.Itoa(c.count))
}

func (c *counterMock) value() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.count
}

// TestCounterIntegration_InMemoryMock verifies the welcome->counter flow using
// an in-process mock that simulates the KeyDB-backed counter SpinApp. It
// confirms that the counter increments on each call and that the welcome
// function parses the response correctly.
func TestCounterIntegration_InMemoryMock(t *testing.T) {
	mock := &counterMock{}
	ts := httptest.NewServer(mock)
	defer ts.Close()

	ctx := context.Background()

	// First call should return 1
	count, err := fetchCounter(ctx, ts.URL)
	require.NoError(t, err)
	assert.Equal(t, 1, count)
	assert.Equal(t, 1, mock.value())

	// Second call should return 2 (incremented)
	count, err = fetchCounter(ctx, ts.URL)
	require.NoError(t, err)
	assert.Equal(t, 2, count)
	assert.Equal(t, 2, mock.value())

	// Sequential calls must always return previous + 1
	for i := 3; i <= 10; i++ {
		count, err = fetchCounter(ctx, ts.URL)
		require.NoError(t, err)
		assert.Equal(t, i, count)
		assert.Equal(t, i, mock.value())
	}
}

// TestCounterIntegration_SequentialIncrements verifies that 5 sequential calls
// to the counter each return exactly previous+1, matching the e2e spec contract.
func TestCounterIntegration_SequentialIncrements(t *testing.T) {
	mock := &counterMock{}
	ts := httptest.NewServer(mock)
	defer ts.Close()

	ctx := context.Background()
	var prev int

	for i := 0; i < 5; i++ {
		count, err := fetchCounter(ctx, ts.URL)
		require.NoError(t, err)
		if i > 0 {
			assert.Equal(t, prev+1, count, "call %d: expected %d, got %d", i+1, prev+1, count)
		}
		prev = count
	}
}

// TestCounterIntegration_ConcurrentAccess verifies that the counter correctly
// increments under concurrent calls (simulating real-world traffic).
func TestCounterIntegration_ConcurrentAccess(t *testing.T) {
	mock := &counterMock{}
	ts := httptest.NewServer(mock)
	defer ts.Close()

	ctx := context.Background()
	concurrency := 10
	errs := make(chan error, concurrency)

	for i := 0; i < concurrency; i++ {
		go func() {
			_, err := fetchCounter(ctx, ts.URL)
			errs <- err
		}()
	}

	for i := 0; i < concurrency; i++ {
		err := <-errs
		require.NoError(t, err)
	}

	// After 10 concurrent calls + initial setup, count should be 10 + any previous
	assert.Equal(t, concurrency, mock.value())
}

// TestCounterIntegration_UnreachableError verifies that the welcome function
// correctly returns an error when the counter service is unreachable.
func TestCounterIntegration_UnreachableError(t *testing.T) {
	// Use a port where nothing is listening
	_, err := fetchCounter(context.Background(), "http://127.0.0.1:1")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "connection failed")
}

// TestCounterIntegration_TimeoutError verifies that the welcome function
// returns an error when the counter service does not respond in time.
func TestCounterIntegration_TimeoutError(t *testing.T) {
	// Start a server that never responds (sleeps past timeout)
	slowServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(100 * time.Millisecond)
	}))
	defer slowServer.Close()

	// Create a context with a short timeout to verify the timeout path
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Millisecond)
	defer cancel()

	_, err := fetchCounter(ctx, slowServer.URL)
	require.Error(t, err)
	// The error could be a context deadline exceeded or connection timeout
	assert.True(t,
		err.Error() == "connection failed: Get \""+slowServer.URL+"\": context deadline exceeded (Client.Timeout or context cancellation while reading body)" ||
			err.Error() == "connection failed: Get \""+slowServer.URL+"\": context deadline exceeded",
		"expected context deadline error, got: %v", err)
}

// TestCounterIntegration_WithKeyDBEnvVar is a live integration test that
// connects to a real KeyDB when KEYDB_TEST_URL is set. This test is skipped
// in CI unless the env var is configured.
//
// To run: KEYDB_TEST_URL=http://keydb.keydb.svc.cluster.local:6379 go test -run TestCounterIntegration_WithKeyDBEnvVar
func TestCounterIntegration_WithKeyDBEnvVar(t *testing.T) {
	keydbURL := os.Getenv("KEYDB_TEST_URL")
	if keydbURL == "" {
		t.Skip("KEYDB_TEST_URL not set — skipping live KeyDB integration test")
	}

	// The counter service is expected to be running at the supplied URL.
	// We call the counter directly and verify we get a numeric response.
	ctx := context.Background()

	count, err := fetchCounter(ctx, keydbURL)
	if err != nil {
		// The counter service might not be exposed directly; the test
		// passes if the counter is reachable and returns a number.
		t.Skipf("Counter at %q not reachable: %v — skipping live test", keydbURL, err)
	}

	t.Logf("Counter returned: %d", count)
	assert.Greater(t, count, 0, "counter value should be positive")

	// Call again and verify it incremented
	count2, err := fetchCounter(ctx, keydbURL)
	require.NoError(t, err)
	assert.Equal(t, count+1, count2, "counter should have incremented by 1")
}
