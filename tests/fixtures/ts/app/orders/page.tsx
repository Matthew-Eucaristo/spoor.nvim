import { OrderList } from "../../components/OrderList";
import { memoryStore } from "../../lib/orders";

export default async function OrdersPage() {
  const orders = await memoryStore.list();
  return (
    <main>
      <h1>Orders</h1>
      <OrderList orders={orders} />
    </main>
  );
}
