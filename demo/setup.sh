#!/usr/bin/env bash
# Builds the demo repo: the Go fixture on main, plus an "agent" branch with changes.
# Prints the repo path. Synthetic code only; no real names or paths.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
shop="/tmp/spoor-demo/shop"
rm -rf "$shop"
mkdir -p "$shop"
cp -R "$repo/tests/fixtures/go/." "$shop/"
cd "$shop"
git() { command git -c user.name=demo -c user.email=demo@example.com -c init.defaultBranch=main "$@"; }
git init -q
git add -A
git commit -qm "shop: orders API"
git checkout -qb agent/rounding
# the agent's change: round totals, plus a helper nothing calls yet
perl -0pi -e 's/\to.Total = applyDiscount\(subtotal\(o\), discount\)\n/\to.Total = applyDiscount(subtotal(o), discount)\n\to.Total = roundCents(o.Total)\n/' internal/order/order.go
cat >> internal/order/discount.go <<'GO'

// roundCents rounds a total to whole cents.
func roundCents(total int) int {
	return (total + 50) / 100 * 100
}
GO
git commit -qam "order: round totals to cents"
cat > internal/order/loyalty.go <<'GO'
package order

// loyaltyBonus gives returning customers 5% back.
func loyaltyBonus(o Order, visits int) int {
	if visits < 3 {
		return 0
	}
	return o.Total * 5 / 100
}
GO
echo "$shop"
