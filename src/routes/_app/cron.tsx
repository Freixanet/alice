import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { Pencil, Play, Plus, Trash2 } from "lucide-react";
import { useState } from "react";
import { PageHeader } from "@/components/catalog-page";
import { CronJobDialog, type CronJobDraft } from "@/components/cron-job-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { listHermesLive, mutateHermes } from "@/lib/hermes-live";
import type { HermesCronRow } from "@/lib/hermes-live-types";
import { dateLocale, localizeError, type Locale } from "@/lib/i18n";
import { HERMES_CURRENT_STABLE } from "@/lib/gateway-contracts";
import { useHermes } from "@/lib/store";
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
  const hermesVersion = useHermes(
    (state) => state.gatewayMeta?.manifest?.version,
  );
  const pantheon = hermesVersion === HERMES_CURRENT_STABLE;
  const [open, setOpen] = useState(false);
  const [creating, setCreating] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);
  const [editJob, setEditJob] = useState<HermesCronRow | null>(null);
  const [deleteJob, setDeleteJob] = useState<HermesCronRow | null>(null);
  const [actionPending, setActionPending] = useState<string | null>(null);
  const jobs = data?.cron ?? [];

  async function saveJob(draft: CronJobDraft) {
    if (creating) return;
    setCreating(true);
    setCreateError(null);
    const result = editJob
      ? await mutateHermes({
          action: "cron-update",
          jobId: editJob.id,
          updates: draft,
        })
      : await mutateHermes({ action: "cron-create", ...draft });
    if (!result.ok) {
      setCreateError(result.error || t("cron.createError"));
      setCreating(false);
      return;
    }
    const fresh = await listHermesLive();
    if (fresh.ok) setData(fresh);
    setCreating(false);
    setOpen(false);
    setEditJob(null);
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
              onClick={() => {
                if (!data?.writable) {
                  void navigate({ to: "/connect" });
                  return;
                }
                setEditJob(null);
                setOpen(true);
              }}
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
                      <Badge variant="mute">
                        {job.noAgent
                          ? t("cron.modeScript")
                          : t("cron.modeAgent")}
                      </Badge>
                      {job.continuity ? (
                        <Badge variant="mute">{t("cron.continuity")}</Badge>
                      ) : null}
                      {job.monitorScript || job.monitorUrl ? (
                        <Badge variant="mute">{t("cron.monitor")}</Badge>
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
                    <div className="flex items-center gap-1">
                      <Button
                        variant="ghost"
                        size="icon"
                        aria-label={t("cron.run")}
                        disabled={actionPending === job.id}
                        onClick={() => {
                          setActionPending(job.id);
                          void mutateHermes({
                            action: "cron-run",
                            jobId: job.id,
                          }).then((result) => {
                            setActionPending(null);
                            if (!result.ok)
                              setCreateError(t("cron.actionError"));
                          });
                        }}
                      >
                        <Play />
                      </Button>
                      <Button
                        variant="ghost"
                        size="icon"
                        aria-label={t("cron.edit")}
                        disabled={actionPending === job.id}
                        onClick={() => {
                          setCreateError(null);
                          setEditJob(job);
                          setOpen(true);
                        }}
                      >
                        <Pencil />
                      </Button>
                      <Button
                        variant="ghost"
                        disabled={actionPending === job.id}
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
                      <Button
                        variant="ghost"
                        size="icon"
                        aria-label={t("cron.delete")}
                        onClick={() => setDeleteJob(job)}
                      >
                        <Trash2 />
                      </Button>
                    </div>
                  ) : null}
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
      <CronJobDialog
        open={open}
        job={editJob}
        skills={data?.skills ?? []}
        toolsets={data?.toolsets ?? []}
        deliveryTargets={data?.cronDeliveryTargets ?? []}
        pantheon={pantheon}
        pending={creating}
        error={createError ? localizeError(locale, createError) : null}
        onOpenChange={(next) => {
          setOpen(next);
          if (!next) setEditJob(null);
          if (next) setCreateError(null);
        }}
        onSave={saveJob}
      />
      <Dialog
        open={Boolean(deleteJob)}
        onOpenChange={(next) => {
          if (!next && !actionPending) setDeleteJob(null);
        }}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{t("cron.deleteTitle")}</DialogTitle>
            <DialogDescription>
              {t("cron.deleteHint", { name: deleteJob?.name ?? "" })}
            </DialogDescription>
          </DialogHeader>
          <div className="flex justify-end gap-2">
            <Button
              variant="ghost"
              disabled={Boolean(actionPending)}
              onClick={() => setDeleteJob(null)}
            >
              {t("cron.cancel")}
            </Button>
            <Button
              variant="destructive"
              disabled={!deleteJob || Boolean(actionPending)}
              onClick={() => {
                if (!deleteJob) return;
                const selected = deleteJob;
                setActionPending(selected.id);
                void mutateHermes({
                  action: "cron-delete",
                  jobId: selected.id,
                  confirm: true,
                }).then((result) => {
                  setActionPending(null);
                  if (!result.ok) {
                    setCreateError(t("cron.actionError"));
                    return;
                  }
                  if (data)
                    setData({
                      ...data,
                      cron: data.cron.filter((job) => job.id !== selected.id),
                    });
                  setDeleteJob(null);
                });
              }}
            >
              {t("cron.delete")}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
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
