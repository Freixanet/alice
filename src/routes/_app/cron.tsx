import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { Plus } from "lucide-react";
import { useState } from "react";
import { PageHeader } from "@/components/catalog-page";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { listHermesLive, mutateHermes } from "@/lib/hermes-live";
import { dateLocale, localizeError, type Locale } from "@/lib/i18n";
import { useHermesLive } from "@/lib/use-hermes-live";
import { useLocale, useT } from "@/lib/use-i18n";

export const Route = createFileRoute("/_app/cron")({
  component: CronPage,
});

function CronPage() {
  const t = useT();
  const locale = useLocale();
  const navigate = useNavigate();
  const { data, error, loading, setData } = useHermesLive();
  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [prompt, setPrompt] = useState("");
  const [frequency, setFrequency] = useState<Frequency>("daily");
  const [time, setTime] = useState("09:00");
  const [creating, setCreating] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);
  const jobs = data?.cron ?? [];

  async function createJob() {
    const jobName = name.trim();
    const instructions = prompt.trim();
    if (!jobName || !instructions || creating) return;
    setCreating(true);
    setCreateError(null);
    const result = await mutateHermes({
      action: "cron-create",
      name: jobName,
      prompt: instructions,
      schedule: scheduleFor(frequency, time),
    });
    if (!result.ok) {
      setCreateError(result.error || t("cron.createError"));
      setCreating(false);
      return;
    }
    const fresh = await listHermesLive();
    if (fresh.ok) setData(fresh);
    setCreating(false);
    setOpen(false);
    setName("");
    setPrompt("");
    setFrequency("daily");
    setTime("09:00");
  }

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      <div className="mx-auto flex w-full max-w-3xl flex-col gap-6 px-4 py-8 pb-20 sm:px-6">
        <PageHeader
          kicker={t("cron.kicker")}
          title={t("cron.title")}
          description={t("cron.description")}
          action={
            <Button
              disabled={loading}
              onClick={() =>
                data?.writable
                  ? setOpen(true)
                  : void navigate({ to: "/connect" })
              }
            >
              <Plus />
              {t("cron.new")}
            </Button>
          }
        />
        {loading ? (
          <p className="text-sm text-muted-foreground">{t("cron.loading")}</p>
        ) : error ? (
          <p className="text-sm text-muted-foreground">
            {localizeError(locale, error)}
          </p>
        ) : jobs.length === 0 ? (
          <div className="rounded-xl bg-card px-4 py-12 text-center text-sm text-muted-foreground shadow-border">
            {t("cron.empty")}
          </div>
        ) : (
          <ul className="flex flex-col gap-2">
            {jobs.map((job) => (
              <li
                key={job.id}
                className="rounded-xl bg-card px-4 py-4 shadow-border"
              >
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <h2 className="font-medium">{job.name}</h2>
                      <Badge variant={job.enabled ? "live" : "outline"}>
                        {job.enabled ? t("cron.active") : t("cron.paused")}
                      </Badge>
                      {job.origin ? (
                        <Badge variant="mute">{job.origin}</Badge>
                      ) : null}
                    </div>
                    <p className="mt-1 text-sm text-muted-foreground">
                      {job.schedule}
                    </p>
                    <p className="mt-2 text-2xs text-muted-foreground">
                      {job.lastStatus
                        ? t("cron.last", { status: job.lastStatus })
                        : t("cron.none")}
                      {job.nextRunAt
                        ? ` · ${t("cron.next", { when: formatStamp(locale, job.nextRunAt) })}`
                        : ""}
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
                              ? {
                                  ...j,
                                  enabled,
                                  state: enabled ? "scheduled" : "paused",
                                }
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
                            cron: data.cron.map((j) =>
                              j.id === job.id ? job : j,
                            ),
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
      <Dialog
        open={open}
        onOpenChange={(next) => {
          if (!creating) setOpen(next);
          if (next) setCreateError(null);
        }}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{t("cron.createTitle")}</DialogTitle>
            <DialogDescription>{t("cron.createDescription")}</DialogDescription>
          </DialogHeader>
          <form
            className="flex flex-col gap-4"
            onSubmit={(event) => {
              event.preventDefault();
              void createJob();
            }}
          >
            <label className="flex flex-col gap-1.5 text-sm">
              {t("cron.name")}
              <Input
                value={name}
                onChange={(event) => setName(event.target.value)}
                placeholder={t("cron.namePlaceholder")}
                autoFocus
              />
            </label>
            <label className="flex flex-col gap-1.5 text-sm">
              {t("cron.instructions")}
              <textarea
                value={prompt}
                onChange={(event) => setPrompt(event.target.value)}
                placeholder={t("cron.instructionsPlaceholder")}
                className="min-h-28 resize-none rounded-md bg-muted px-3 py-2 text-base text-foreground shadow-border placeholder:text-muted-foreground/80 focus-visible:outline-none md:text-sm"
              />
            </label>
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <label className="flex flex-col gap-1.5 text-sm">
                {t("cron.frequency")}
                <select
                  value={frequency}
                  onChange={(event) =>
                    setFrequency(event.target.value as Frequency)
                  }
                  className="h-10 w-full rounded-md bg-muted px-3 text-base text-foreground shadow-border focus-visible:outline-none md:text-sm"
                >
                  <option value="daily">{t("cron.daily")}</option>
                  <option value="weekdays">{t("cron.weekdays")}</option>
                  <option value="weekly">{t("cron.weekly")}</option>
                  <option value="hourly">{t("cron.hourly")}</option>
                </select>
              </label>
              {frequency !== "hourly" ? (
                <label className="flex flex-col gap-1.5 text-sm">
                  {t("cron.time")}
                  <Input
                    type="time"
                    value={time}
                    onChange={(event) => setTime(event.target.value)}
                  />
                </label>
              ) : null}
            </div>
            {createError ? (
              <p className="text-sm text-destructive">
                {localizeError(locale, createError)}
              </p>
            ) : null}
            <div className="flex justify-end gap-2">
              <Button
                type="button"
                variant="ghost"
                onClick={() => setOpen(false)}
                disabled={creating}
              >
                {t("cron.cancel")}
              </Button>
              <Button
                type="submit"
                disabled={creating || !name.trim() || !prompt.trim()}
              >
                {creating ? t("cron.creating") : t("cron.create")}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>
    </div>
  );
}

type Frequency = "daily" | "weekdays" | "weekly" | "hourly";

function scheduleFor(frequency: Frequency, value: string) {
  if (frequency === "hourly") return "0 * * * *";
  const [hours = "9", minutes = "0"] = value.split(":");
  const minute = Number.parseInt(minutes, 10) || 0;
  const hour = Number.parseInt(hours, 10) || 0;
  if (frequency === "weekdays") return `${minute} ${hour} * * 1-5`;
  if (frequency === "weekly") return `${minute} ${hour} * * 1`;
  return `${minute} ${hour} * * *`;
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
