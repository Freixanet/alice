import { useMemo, useState, type ReactNode } from "react";
import { useNavigate } from "@tanstack/react-router";
import { MessageSquare } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import type { MsgKey } from "@/lib/i18n";
import { useHermes } from "@/lib/store";
import type { Trust } from "@/lib/types";
import { useT } from "@/lib/use-i18n";
import { cn } from "@/lib/utils";

const TRUST_LABEL: Record<Trust, MsgKey> = {
  builtin: "catalog.trust.builtin",
  official: "catalog.trust.official",
  trusted: "catalog.trust.trusted",
  community: "catalog.trust.community",
};

export function PageHeader({
  kicker,
  title,
  description,
  action,
}: {
  kicker: string;
  title: string;
  description: string;
  action?: ReactNode;
}) {
  return (
    <header className="alice-page-header flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
      <div className="space-y-1.5">
        <p className="text-2xs font-medium tracking-[0.16em] text-muted-foreground uppercase">
          {kicker}
        </p>
        <h1 className="font-serif text-3xl tracking-tight">{title}</h1>
        <p className="max-w-xl text-sm text-muted-foreground">{description}</p>
      </div>
      {action ? <div className="shrink-0">{action}</div> : null}
    </header>
  );
}

export type CatalogRow = {
  id: string;
  title: string;
  name: string;
  description: string;
  group: string;
  groupLabel: string;
  trust?: Trust;
  version?: string;
  meta?: string;
  enabled: boolean;
};

export function CatalogPage({
  kicker,
  title,
  description,
  action,
  overview,
  groups,
  rows,
  onToggle,
  chatPrompt,
  empty,
  rowActions,
}: {
  kicker: string;
  title: string;
  description: string;
  action?: ReactNode;
  overview?: ReactNode;
  groups: { id: string; label: string }[];
  rows: CatalogRow[];
  onToggle?: (id: string) => void;
  chatPrompt: (row: CatalogRow) => string;
  empty?: string;
  rowActions?: (row: CatalogRow) => ReactNode;
}) {
  const t = useT();
  const [q, setQ] = useState("");
  const [group, setGroup] = useState("all");
  const navigate = useNavigate();
  const newChat = useHermes((s) => s.newChat);
  const setDraft = useHermes((s) => s.setDraft);

  const filtered = useMemo(() => {
    const n = q.trim().toLowerCase();
    return rows.filter((row) => {
      if (group !== "all" && row.group !== group) return false;
      if (!n) return true;
      return `${row.title} ${row.name} ${row.description}`
        .toLowerCase()
        .includes(n);
    });
  }, [rows, q, group]);

  function startChatWith(row: CatalogRow) {
    newChat();
    setDraft(chatPrompt(row));
    void navigate({ to: "/" });
  }

  return (
    <div className="mx-auto flex w-full max-w-3xl flex-col gap-6 px-4 py-8 pb-20 sm:px-6">
      <PageHeader
        kicker={kicker}
        title={title}
        description={description}
        action={action}
      />
      {overview}
      <div className="flex flex-col gap-3">
        <Input
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder={t("catalog.search")}
          className="max-w-sm"
        />
        <div className="flex flex-wrap gap-1.5">
          <FilterChip active={group === "all"} onClick={() => setGroup("all")}>
            {t("catalog.all")}
          </FilterChip>
          {groups.map((g) => (
            <FilterChip
              key={g.id}
              active={group === g.id}
              onClick={() => setGroup(g.id)}
            >
              {g.label}
            </FilterChip>
          ))}
        </div>
      </div>
      <ul className="alice-record-list flex flex-col gap-2">
        {filtered.length === 0 ? (
          <li className="alice-record rounded-xl bg-card px-4 py-12 text-center text-sm text-muted-foreground">
            {rows.length === 0
              ? empty || t("catalog.empty")
              : t("catalog.noFilter")}
          </li>
        ) : (
          filtered.map((row) => (
            <li
              key={row.id}
              className="alice-record rounded-xl bg-card px-4 py-4 border border-border"
            >
              <div className="flex flex-col items-stretch gap-3 sm:flex-row sm:items-start">
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <h2 className="font-medium">{row.title}</h2>
                    {row.trust ? (
                      <Badge variant="outline">
                        {t(TRUST_LABEL[row.trust])}
                      </Badge>
                    ) : null}
                    {row.version ? (
                      <Badge variant="mute">{row.version}</Badge>
                    ) : null}
                  </div>
                  <p className="mt-1 text-sm text-muted-foreground">
                    {row.description}
                  </p>
                  <p className="mt-2 text-2xs text-muted-foreground">
                    {row.groupLabel}
                    {row.meta ? ` · ${row.meta}` : ""}
                  </p>
                </div>
                <div className="ml-auto flex shrink-0 items-center gap-1">
                  {rowActions?.(row)}
                  <Button
                    variant="ghost"
                    size="icon-sm"
                    aria-label={t("catalog.useInChat")}
                    onClick={() => startChatWith(row)}
                  >
                    <MessageSquare className="size-4" />
                  </Button>
                  <Switch
                    checked={row.enabled}
                    disabled={!onToggle}
                    onCheckedChange={() => onToggle?.(row.id)}
                    aria-label={t("catalog.enable", { title: row.title })}
                  />
                </div>
              </div>
            </li>
          ))
        )}
      </ul>
    </div>
  );
}

function FilterChip({
  active,
  onClick,
  children,
}: {
  active: boolean;
  onClick: () => void;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onClick}
      className={cn(
        "h-8 rounded-full px-3 text-xs font-medium",
        active
          ? "bg-primary text-primary-foreground"
          : "bg-muted text-muted-foreground hover:text-foreground",
      )}
    >
      {children}
    </button>
  );
}
