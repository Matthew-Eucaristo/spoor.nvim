package store

import (
	"context"
	"database/sql"

	"example.com/shop/internal/order"
)

// Postgres stores orders in a SQL database.
type Postgres struct{ db *sql.DB }

// Save inserts an order.
func (p *Postgres) Save(ctx context.Context, o order.Order) error {
	_, err := p.db.ExecContext(ctx, "INSERT INTO orders (id, total) VALUES ($1, $2)", o.ID, o.Total)
	return err
}
