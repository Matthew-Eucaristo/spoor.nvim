// Package order prices and stores orders.
package order

import (
	"context"

	"example.com/shop/internal/events"
)

// Order is what a customer buys.
type Order struct {
	ID    string
	Items []Item
	Total int
}

// Item is one line of an order.
type Item struct {
	SKU   string
	Price int
	Qty   int
}

// Process validates, prices and stores an order, then announces it.
func Process(ctx context.Context, repo Repo, o Order, discount int) error {
	if err := validate(o); err != nil {
		return err
	}
	o.Total = applyDiscount(subtotal(o), discount)
	if err := repo.Save(ctx, o); err != nil {
		return err
	}
	events.Emit("order.created", o.ID)
	return nil
}

func subtotal(o Order) int {
	total := 0
	for _, it := range o.Items {
		total += it.Price * it.Qty
	}
	return total
}
