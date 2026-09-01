import { createFileRoute, useNavigate } from "@tanstack/react-router";
import {
  Check,
  Code2,
  ExternalLink,
  File,
  Image,
  MessageSquare,
} from "lucide-react";
import { useMemo, useState } from "react";
import { PageHeader } from "@/components/catalog-page";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  artifactsFromConversations,
  type AliceArtifactKind,
} from "@/lib/artifacts";
import { useHermes } from "@/lib/store";
import { useT } from "@/lib/use-i18n";

export const Route = createFileRoute("/_app/artifacts")({
  component: ArtifactsPage,
});

const ICONS = { file: File, image: Image, link: ExternalLink, code: Code2 };

function ArtifactsPage() {
  const t = useT();
  const navigate = useNavigate();
  const conversations = useHermes((state) => state.conversations);
  const selectChat = useHermes((state) => state.selectChat);
  const [query, setQuery] = useState("");
  const [kind, setKind] = useState<"all" | AliceArtifactKind>("all");
  const [copied, setCopied] = useState<string | null>(null);
  const artifacts = useMemo(
    () => artifactsFromConversations(conversations),
    [conversations],
  );
  const filtered = useMemo(() => {
    const normalized = query.trim().toLowerCase();
    return artifacts.filter(
      (artifact) =>
        (kind === "all" || artifact.kind === kind) &&
        (!normalized ||
          `${artifact.label} ${artifact.conversationTitle}`
            .toLowerCase()
            .includes(normalized)),
    );
  }, [artifacts, kind, query]);

  async function copy(id: string, value: string) {
    await navigator.clipboard.writeText(value);
    setCopied(id);
    window.setTimeout(() => setCopied(null), 1_500);
  }

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      <main className="mx-auto flex w-full max-w-3xl flex-col gap-6 px-4 py-8 pb-20 sm:px-6">
        <PageHeader
          kicker={t("artifacts.kicker")}
          title={t("artifacts.title")}
          description={t("artifacts.description")}
        />
        <div className="flex flex-col gap-3 sm:flex-row">
          <Input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={t("artifacts.search")}
            className="sm:max-w-sm"
          />
          <div className="flex flex-wrap gap-1">
            {(["all", "image", "file", "link", "code"] as const).map(
              (value) => (
                <Button
                  key={value}
                  size="sm"
                  variant={kind === value ? "secondary" : "ghost"}
                  aria-pressed={kind === value}
                  onClick={() => setKind(value)}
                >
                  {value === "all" ? t("catalog.all") : t(`artifacts.${value}`)}
                </Button>
              ),
            )}
          </div>
        </div>
        <ul className="alice-record-list flex flex-col gap-2">
          {filtered.length === 0 ? (
            <li className="alice-record rounded-xl border border-border bg-card px-4 py-12 text-center text-sm text-muted-foreground">
              {t("artifacts.empty")}
            </li>
          ) : (
            filtered.map((artifact) => {
              const Icon = ICONS[artifact.kind];
              return (
                <li
                  key={artifact.id}
                  className="alice-record flex items-start gap-3 rounded-xl border border-border bg-card px-4 py-4"
                >
                  <span className="flex size-9 shrink-0 items-center justify-center rounded-md bg-secondary">
                    <Icon aria-hidden="true" className="size-4" />
                  </span>
                  <div className="min-w-0 flex-1">
                    {artifact.kind === "link" ? (
                      <a
                        href={artifact.value}
                        target="_blank"
                        rel="noreferrer"
                        className="block truncate text-sm font-medium underline-offset-4 hover:underline"
                      >
                        {artifact.label}
                      </a>
                    ) : artifact.value.startsWith("data:") ? (
                      <a
                        href={artifact.value}
                        download={artifact.label}
                        className="block truncate text-sm font-medium underline-offset-4 hover:underline"
                      >
                        {artifact.label}
                      </a>
                    ) : (
                      <p className="truncate text-sm font-medium">
                        {artifact.label}
                      </p>
                    )}
                    <p className="mt-1 truncate text-xs text-muted-foreground">
                      {artifact.conversationTitle}
                    </p>
                  </div>
                  <div className="flex shrink-0 items-center gap-1">
                    {artifact.value ? (
                      <Button
                        variant="ghost"
                        size="icon-sm"
                        aria-label={t("artifacts.copy")}
                        onClick={() => void copy(artifact.id, artifact.value)}
                      >
                        {copied === artifact.id ? <Check /> : <Code2 />}
                      </Button>
                    ) : null}
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      aria-label={t("artifacts.openChat")}
                      onClick={() => {
                        selectChat(artifact.conversationId);
                        void navigate({ to: "/" });
                      }}
                    >
                      <MessageSquare />
                    </Button>
                  </div>
                </li>
              );
            })
          )}
        </ul>
      </main>
    </div>
  );
}
