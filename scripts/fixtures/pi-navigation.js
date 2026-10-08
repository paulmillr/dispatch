// Test-only native command: exercise Pi's real branch navigation without
// depending on a particular terminal menu's selected row or keyboard binding.
export default function navigationFixture(pi) {
  pi.registerCommand("dispatch-test-question", {
    description: "Open a native Pi confirmation for Chat handoff tests",
    handler: async (args, ctx) => {
      const title = "Dispatch fixture permission";
      const dialogs = {
        confirm: () => ctx.ui.confirm(title, "Allow the isolated fixture action?"),
        select: () => ctx.ui.select(title, ["Allow", "Deny"]),
        input: () => ctx.ui.input(title),
        editor: () => ctx.ui.editor(title, "Keep the native draft"),
      };
      await dialogs[args.trim() || "confirm"]();
    },
  });
  pi.registerCommand("dispatch-test-branch", {
    description: "Select an exact existing branch entry in the isolated Chat fixture",
    handler: async (args, ctx) => {
      const entry = args.trim();
      if (!ctx.isIdle() || !ctx.sessionManager.getEntries().some(value => value.id === entry)) {
        throw new Error("The fixture branch entry is unavailable");
      }
      await ctx.navigateTree(entry, { summarize: false });
    },
  });
}
