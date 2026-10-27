package order

import "context"

// Repo stores orders.
type Repo interface {
	Save(ctx context.Context, o Order) error
}
