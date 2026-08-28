import { createFileRoute } from "@tanstack/react-router";
import { PageHeader } from "@/components/catalog-page";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { mutateHermes } from "@/lib/hermes-live";
import { dateLocale, localizeError, type Locale } from "@/lib/i18n";
import { useHermesLive } from "@/lib/use-hermes-live";
import { useLocale, useT } from "@/lib/use-i18n";

export const Route = createFileRoute("/_app/cron")({
  component: CronPage,
});

function CronPage() {
  const t = useT();
  const locale = useLocale();
  const { data, error, loading, setData } = useHermesLive();
  const jobs = data?.cron ?? [];

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      <div className="mx-auto flex w-full max-w-3xl flex-col gap-6 px-4 py-8 pb-20 sm:px-6">
        <PageHeader
          kicker={t("cron.kicker")}
          title={t("cron.title")}
          description={t("cron.description")}
        />
        {loading ? (
          <p className="text-sm text-muted-foreground">{t("cron.loading")}</p>
        ) : error ? (
          <p className="text-sm text-muted-foreground">{localizeError(locale, error)}</p>
        ) : jobs.length === 0 ? (
          <div className="rounded-xl bg-card px-4 py-12 text-center text-sm text-muted-foreground shadow-border">
            {t("cron.empty")}
          </div>
        ) : (
          <ul className="flex flex-col gap-2">
            {jobs.map((job) => (
              <li key={job.id} className="rounded-xl bg-card px-4 py-4 shadow-border">
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <h2 className="font-medium">{job.name}</h2>
                      <Badge variant={job.enabled ? "live" : "outline"}>
                        {job.enabled ? t("cron.active") : t("cron.paused")}
                      </Badge>
                      {job.origin ? <Badge variant="mute">{job.origin}</Badge> : null}
                    </div>
                    <p className="mt-1 text-sm text-muted-foreground">{job.schedule}</p>
                    <p className="mt-2 text-2xs text-muted-foreground">
                      {job.lastStatus ? t("cron.last", { status: job.lastStatus }) : t("cron.none")}
                      {job.nextRunAt ? ` · ${t("cron.next", { when: formatStamp(locale, job.nextRunAt) })}` : ""}
                    </p>
                  </div>
                  {data?.writable ? (
                    <Button
                      variant="ghost"
                      onClick={() => {
                        const enabled = !job.enabled;
                        setData({
                          ...data,
                          cron: data.cron.map((j) =>
                            j.id === job.id
                              ? { ...j, enabled, state: enabled ? "scheduled" : "paused" }
                              : j,
                          ),
                        });
                        void mutateHermes({
                          action: enabled ? "cron-resume" : "cron-pause",
                          jobId: job.id,
                        }).then((r) => {
                          if (r.ok) return;
                          setData({
                            ...data,
                            cron: data.cron.map((j) => (j.id === job.id ? job : j)),
                          });
                        });
                      }}
                    >
                      {job.enabled ? t("cron.pause") : t("cron.resume")}
                    </Button>
                  ) : null}
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}

function formatStamp(locale: Locale, value: string) {
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return value;
  return new Intl.DateTimeFormat(dateLocale(locale), {
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  }).format(d);
}
