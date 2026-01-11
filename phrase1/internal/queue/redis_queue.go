package queue

import (
	"context"
	"errors"
	"time"

	"github.com/redis/go-redis/v9"
)

type RedisQueue struct {
	client *redis.Client
	name   string
}

func NewRedisQueue(client *redis.Client, name string) *RedisQueue {
	return &RedisQueue{client: client, name: name}
}

func (q *RedisQueue) Enqueue(ctx context.Context, payload string) error {
	return q.client.LPush(ctx, q.name, payload).Err()
}

// Dequeue blocks until a message is available or ctx is canceled.
func (q *RedisQueue) Dequeue(ctx context.Context) (string, error) {
	for {
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		default:
		}

		// Use a finite timeout so we can react to ctx cancellation.
		res, err := q.client.BRPop(ctx, 5*time.Second, q.name).Result()
		if err == nil {
			// BRPOP returns [queueName, payload]
			if len(res) == 2 {
				return res[1], nil
			}
			return "", errors.New("unexpected BRPOP response")
		}
		if errors.Is(err, redis.Nil) {
			continue
		}
		return "", err
	}
}
