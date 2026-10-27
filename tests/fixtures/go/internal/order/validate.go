package order

import "errors"

var errEmpty = errors.New("order has no items")

func validate(o Order) error {
	if len(o.Items) == 0 {
		return errEmpty
	}
	return nil
}
