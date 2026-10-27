export interface Order {
  id: string;
  items: { sku: string; price: number; qty: number }[];
  total: number;
}

export interface OrderStore {
  save(order: Order): Promise<void>;
  list(): Promise<Order[]>;
}

const orders: Order[] = [];

export const memoryStore: OrderStore = {
  async save(order) {
    orders.push(order);
  },
  async list() {
    return orders;
  },
};

export function priceOrder(order: Order): Order {
  const subtotal = order.items.reduce((sum, it) => sum + it.price * it.qty, 0);
  return { ...order, total: applyDiscount(subtotal, 10) };
}

export function applyDiscount(total: number, percent: number): number {
  return Math.max(total - (total * percent) / 100, 0);
}

export async function createOrder(store: OrderStore, order: Order): Promise<Order> {
  const priced = priceOrder(order);
  await store.save(priced);
  return priced;
}
