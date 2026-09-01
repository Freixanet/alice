import { cn } from "@/lib/utils";
import { useLocale, useT } from "@/lib/use-i18n";
import { localizeError } from "@/lib/i18n";
import type { HermesApprovalChoice } from "@/lib/gateway-contracts";
import type { Message } from "@/lib/types";

export function ChatRunApproval({
  approval,
  onChoose,
}: {
  approval: NonNullable<Message["approval"]>;
  onChoose: (choice: HermesApprovalChoice) => void;
}) {
  const t = useT();
  const locale = useLocale();
  const labels: Record<HermesApprovalChoice, string> = {
    once: t("chat.approveOnce"),
    session: t("chat.approveSession"),
    always: t("chat.approveAlways"),
    deny: t("chat.deny"),
  };
  return (
    <section
      className="w-full max-w-[42rem] rounded-lg border border-border bg-card p-4"
      aria-label={t("chat.approvalTitle")}
    >
      <p className="text-sm font-medium text-foreground">{approval.title}</p>
      {approval.detail ? (
        <p className="mt-1 text-sm text-muted-foreground">{approval.detail}</p>
      ) : null}
      {approval.command ? (
        <code className="mt-3 block max-h-40 overflow-auto rounded-md bg-background p-3 text-xs text-foreground">
          {approval.command}
        </code>
      ) : null}
      {approval.error ? (
        <p className="mt-2 text-sm text-destructive" role="alert">
          {localizeError(locale, approval.error)}
        </p>
      ) : null}
      <div className="mt-3 flex flex-wrap gap-2">
        {approval.choices.map((choice) => (
          <button
            key={choice}
            type="button"
            disabled={approval.resolving}
            onClick={() => onChoose(choice)}
            className={cn(
              "min-h-11 rounded-lg border px-3 text-sm font-medium disabled:opacity-50",
              choice === "deny"
                ? "border-border text-muted-foreground hover:bg-accent"
                : "border-foreground bg-foreground text-background hover:opacity-85",
            )}
          >
            {labels[choice]}
          </button>
        ))}
      </div>
    </section>
  );
}
