package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"

	"learn_k8s/phrase1/internal/queue"
)

func env(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}

func ensureParentDir(path string) error {
	dir := filepath.Dir(path)
	return os.MkdirAll(dir, 0o755)
}

func appendLine(path string, line string) error {
	if err := ensureParentDir(path); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = fmt.Fprintln(f, line)
	return err
}

func main() {
	redisAddr := env("REDIS_ADDR", "redis:6379")
	queueName := env("QUEUE_NAME", "messages")
	outputPath := env("OUTPUT_PATH", "/data/processed.log")

	logger := log.New(os.Stdout, "worker ", log.LstdFlags|log.Lmicroseconds)

	rdb := redis.NewClient(&redis.Options{Addr: redisAddr})
	q := queue.NewRedisQueue(rdb, queueName)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stop
		cancel()
	}()

	logger.Printf("starting (redis=%s queue=%s output=%s)", redisAddr, queueName, outputPath)

	for {
		msg, err := q.Dequeue(ctx)
		if err != nil {
			if ctx.Err() != nil {
				break
			}
			logger.Printf("dequeue error: %v", err)
			time.Sleep(1 * time.Second)
			continue
		}

		processed := fmt.Sprintf("%s | %s", time.Now().Format(time.RFC3339Nano), msg)
		logger.Printf("processed message: %q", msg)
		if err := appendLine(outputPath, processed); err != nil {
			logger.Printf("write output error: %v", err)
		}
	}

	_ = rdb.Close()
	logger.Printf("shutdown complete")
}
