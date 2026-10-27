// Package store keeps orders.
package store

import (
	"context"
	"sync"

	"example.com/shop/internal/order"
)

// Memory keeps orders in memory.
type Memory struct {
	mu     sync.Mutex
	orders map[string]order.Order
}

// NewMemory returns an empty in-memory store.
func NewMemory() *Memory {
	return &Memory{orders: map[string]order.Order{}}
}

// Save stores an order.
func (m *Memory) Save(_ context.Context, o order.Order) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.orders[o.ID] = o
	return nil
}
