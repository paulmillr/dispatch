#if DEBUG
import Foundation

/// Debug builds only: the M5d and M5e mockups' content, for previews, rendering tests and screenshots. The changes are
/// Codex file changes (`ChatPatch.item`, the shape the helper's records carry) with numbered hunks, as the mockup
/// shows them; the whole file is what the patch left.
enum CodeDemo {
    static let directory = "/Users/paul/src/app"

    static let idempotentDiff = """
        @@ -12,8 +12,11 @@ export async function seen(
         export async function seen(eventId: string) {
        -  const n = await redis.incr(`evt:${n}`);
        +  const key = `evt:${eventId}`;
        +  const n = await redis.incr(key);
        +  if (n === 1) await redis.expire(key, TTL);
           return n > 1;
         }
         
         // Shared by billing and invoice routes
        +export const idempotent = middleware(seen);

        """

    static let invoicesDiff = """
        @@ -1,7 +1,6 @@
         import { Router } from "express";
        -import { seen } from "../lib/idempotent";
        +import { idempotent } from "../lib/idempotent";
         
        -router.post("/invoices", async (req, res) => {
        -  if (await seen(req.body.id)) return res.sendStatus(200);
        +router.post("/invoices", idempotent, async (req, res) => {
           res.sendStatus(204);
         });

        """

    /// `src/lib/idempotent.ts` as the patch left it.
    static let idempotentFile = """
        import { redis } from "./redis";
        import { middleware } from "./middleware";

        /** Seconds a Stripe event id is remembered. */
        export const TTL = 60 * 60 * 24;

        /**
         * True when this event was handled before.
         * Stripe retries with a new attempt counter, so the
         * event id is the only stable key.
         */
        export async function seen(eventId: string) {
          const key = `evt:${eventId}`;
          const n = await redis.incr(key);
          if (n === 1) await redis.expire(key, TTL);
          return n > 1;
        }

        // Shared by billing and invoice routes
        export const idempotent = middleware(seen);

        """

    static var items: [ChatItem] {
        [ChatPatch.item(id: "patch-1", changes: [["path": "src/lib/idempotent.ts", "kind": ["type": "update"], "diff": idempotentDiff]],
                        state: .completed),
         ChatPatch.item(id: "patch-2", changes: [["path": "src/routes/invoices.ts", "kind": ["type": "update"], "diff": invoicesDiff]],
                        state: .completed)].compactMap { item in
            var item = item
            item?.directory = directory
            return item
        }
    }

    /// M5d: the first file open; its whole file is read from memory.
    @MainActor static func model(fonts: CodeFontStore? = nil, whole: Bool = false) -> DiffViewModel {
        let items = items
        let model = DiffViewModel(items: items, opening: items.first, directory: directory, host: "mba2", fonts: fonts ?? .memory()) { path in
            guard path.hasSuffix("idempotent.ts") else { throw HelperFailure(code: "not_found", message: "") }
            return idempotentFile
        }
        if whole { model.toggleWhole() }
        return model
    }

    /// M5e's draft: an inline span and a fenced TypeScript block.
    static let draft = """
        Use `redis.set` with NX instead, so the first writer wins:
        ```ts
        const ok = await redis.set(key, 1, {
          NX: true,
          EX: TTL,
        });
        return ok === 'OK';
        """
}
#endif
