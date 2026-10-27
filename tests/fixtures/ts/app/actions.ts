"use server";

import { createOrder, memoryStore, type Order } from "../lib/orders";

export async function placeOrder(order: Order) {
  return createOrder(memoryStore, order);
}
