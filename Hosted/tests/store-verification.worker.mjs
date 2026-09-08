// Isolated Miniflare fixture only. Not a production HTTP endpoint.
import { verifyStorePurchase } from "../store-verification.mjs";
export default {
  async fetch(request) {
    const input = await request.json();
    try {
      await verifyStorePurchase(input.jws, { environment: input.environment, accountToken: input.accountToken });
      return Response.json({ accepted: true });
    } catch (error) {
      return Response.json({ error: error.code ?? "unexpected_error" }, { status: 400 });
    }
  },
};
