package order

// applyDiscount takes a percentage off, never below zero.
func applyDiscount(total, percent int) int {
	off := total * percent / 100
	if off > total {
		return 0
	}
	return total - off
}
