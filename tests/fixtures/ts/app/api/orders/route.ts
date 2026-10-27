import { createOrder, memoryStore } from "../../../lib/orders";

export async function GET() {
  return Response.json(await memoryStore.list());
}

export async function POST(request: Request) {
  const order = await request.json();
  return Response.json(await createOrder(memoryStore, order), { status: 201 });
}
