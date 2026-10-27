import type { Order } from "../lib/orders";

export function OrderRow({ order }: { order: Order }) {
  return (
    <li>
      {order.id}: {formatTotal(order.total)}
    </li>
  );
}

export function OrderList({ orders }: { orders: Order[] }) {
  return <ul>{orders.map((o) => <OrderRow key={o.id} order={o} />)}</ul>;
}

function formatTotal(total: number) {
  return `$${(total / 100).toFixed(2)}`;
}
