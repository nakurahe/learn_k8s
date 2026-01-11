package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"

	"learn_k8s/phrase1/internal/queue"
)

type enqueueRequest struct {
	Message string `json:"message"`
}

type enqueueResponse struct {
	Enqueued bool   `json:"enqueued"`
	Queue    string `json:"queue"`
	Message  string `json:"message"`
}

func env(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}

func main() {
	addr := env("HTTP_ADDR", ":8080")
	redisAddr := env("REDIS_ADDR", "redis:6379") // overridden in docker-compose
	queueName := env("QUEUE_NAME", "messages")

	logger := log.New(os.Stdout, "api ", log.LstdFlags|log.Lmicroseconds)

	rdb := redis.NewClient(&redis.Options{Addr: redisAddr})
	q := queue.NewRedisQueue(rdb, queueName)

	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()

		if err := rdb.Ping(ctx).Err(); err != nil {
			http.Error(w, fmt.Sprintf("redis ping failed: %v", err), http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	mux.HandleFunc("POST /enqueue", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()

		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if err != nil {
			http.Error(w, "failed to read body", http.StatusBadRequest)
			return
		}
		_ = r.Body.Close()

		msg := strings.TrimSpace(string(body))
		if strings.Contains(strings.ToLower(r.Header.Get("Content-Type")), "application/json") {
			var req enqueueRequest
			if err := json.Unmarshal(body, &req); err == nil {
				msg = strings.TrimSpace(req.Message)
			}
		}

		if msg == "" {
			http.Error(w, "message is required", http.StatusBadRequest)
			return
		}

		if err := q.Enqueue(ctx, msg); err != nil {
			logger.Printf("enqueue failed: %v", err)
			http.Error(w, "enqueue failed", http.StatusServiceUnavailable)
			return
		}

		logger.Printf("enqueued message: %q", msg)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(enqueueResponse{Enqueued: true, Queue: queueName, Message: msg})
	})

	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		logger.Printf("listening on %s (redis=%s queue=%s)", addr, redisAddr, queueName)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Fatalf("server error: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
	_ = rdb.Close()
	logger.Printf("shutdown complete")
}
