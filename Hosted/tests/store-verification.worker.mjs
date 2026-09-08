// Isolated Miniflare fixture only. Not a production HTTP endpoint.
import { verifyStorePurchase, reconcileStorePurchase } from "../store-verification.mjs";
import { ownershipKey } from "../store-ownership.mjs";
export { StoreOwnership } from "../store-ownership.mjs";
export default {
  async fetch(request, env) {
    const input = await request.json();
    try {
      // Test-only direct claim input. Never expose this fixture as a real route.
      if (input.claim) {
        const key = ownershipKey(input.environment, input.originalTransactionID);
        return Response.json(await env.OWNERSHIP.getByName(key).claim(
          input.environment, input.originalTransactionID, input.accountToken,
        ));
      }
      const operation = input.reconcile ? reconcileStorePurchase : verifyStorePurchase;
      await operation(input.jws, { environment: input.environment, accountToken: input.accountToken });
      return Response.json({ accepted: true });
    } catch (error) {
      return Response.json({ error: error.code ?? "unexpected_error" }, { status: 400 });
    }
  },
};
