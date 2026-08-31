import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import {
  cronScheduleFields,
  cronScheduleFor,
  type CronFrequency,
} from "@/lib/cron";
import type {
  HermesCronDeliveryTarget,
  HermesCronRow,
  HermesSkillRow,
  HermesToolsetRow,
} from "@/lib/hermes-live-types";
import { useT } from "@/lib/use-i18n";

const reasoningEfforts = [
  "none",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
  "ultra",
] as const;
type ReasoningEffort = (typeof reasoningEfforts)[number];

export type CronJobDraft = {
  name: string;
  prompt: string;
  schedule: string;
  deliver: string;
  skills: string[];
  model?: string;
  provider?: string;
  script?: string;
  workdir?: string;
  enabledToolsets: string[];
  noAgent: boolean;
  continuity: boolean;
  monitorScript?: string;
  monitorUrl?: string;
  reasoningEffort?: ReasoningEffort;
};

export function CronJobDialog({
  open,
  job,
  skills,
  toolsets,
  deliveryTargets,
  pantheon,
  pending,
  error,
  onOpenChange,
  onSave,
}: {
  open: boolean;
  job: HermesCronRow | null;
  skills: HermesSkillRow[];
  toolsets: HermesToolsetRow[];
  deliveryTargets: HermesCronDeliveryTarget[];
  pantheon: boolean;
  pending: boolean;
  error: string | null;
  onOpenChange: (open: boolean) => void;
  onSave: (draft: CronJobDraft) => Promise<void>;
}) {
  const t = useT();
  const [name, setName] = useState("");
  const [prompt, setPrompt] = useState("");
  const [frequency, setFrequency] = useState<CronFrequency>("daily");
  const [time, setTime] = useState("09:00");
  const [customSchedule, setCustomSchedule] = useState("");
  const [deliver, setDeliver] = useState("local");
  const [selectedSkills, setSelectedSkills] = useState<string[]>([]);
  const [selectedToolsets, setSelectedToolsets] = useState<string[]>([]);
  const [model, setModel] = useState("");
  const [provider, setProvider] = useState("");
  const [workdir, setWorkdir] = useState("");
  const [script, setScript] = useState("");
  const [noAgent, setNoAgent] = useState(false);
  const [continuity, setContinuity] = useState(false);
  const [reasoningEffort, setReasoningEffort] = useState<ReasoningEffort | "">(
    reasoningEfforts.includes(job?.reasoningEffort as ReasoningEffort)
      ? (job?.reasoningEffort as ReasoningEffort)
      : "",
  );
  const [monitorKind, setMonitorKind] = useState<"none" | "script" | "url">(
    "none",
  );
  const [monitorValue, setMonitorValue] = useState("");

  useEffect(() => {
    if (!open) return;
    const schedule = cronScheduleFields(job?.schedule ?? "0 9 * * *");
    setName(job?.name ?? "");
    setPrompt(job?.prompt ?? "");
    setFrequency(schedule.frequency);
    setTime(schedule.time);
    setCustomSchedule(schedule.custom);
    setDeliver(job?.deliver ?? "local");
    setSelectedSkills(job?.skills ?? []);
    setSelectedToolsets(job?.enabledToolsets ?? []);
    setModel(job?.model ?? "");
    setProvider(job?.provider ?? "");
    setWorkdir(job?.workdir ?? "");
    setScript(job?.script ?? "");
    setNoAgent(job?.noAgent ?? false);
    setContinuity(job?.continuity ?? false);
    setReasoningEffort(
      reasoningEfforts.includes(job?.reasoningEffort as ReasoningEffort)
        ? (job?.reasoningEffort as ReasoningEffort)
        : "",
    );
    setMonitorKind(
      job?.monitorScript ? "script" : job?.monitorUrl ? "url" : "none",
    );
    setMonitorValue(job?.monitorScript ?? job?.monitorUrl ?? "");
  }, [job, open]);

  const schedule = cronScheduleFor(frequency, time, customSchedule);
  const monitorValid =
    !pantheon ||
    noAgent ||
    monitorKind === "none" ||
    (monitorKind === "script"
      ? Boolean(monitorValue.trim())
      : /^https?:\/\//i.test(monitorValue.trim()));
  const valid = Boolean(
    name.trim() &&
    schedule &&
    (noAgent ? script.trim() : prompt.trim()) &&
    monitorValid,
  );

  return (
    <Dialog open={open} onOpenChange={(next) => !pending && onOpenChange(next)}>
      <DialogContent className="max-h-[min(92dvh,760px)] max-w-xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {job ? t("cron.editTitle") : t("cron.createTitle")}
          </DialogTitle>
          <DialogDescription>
            {job ? t("cron.editDescription") : t("cron.createDescription")}
          </DialogDescription>
        </DialogHeader>
        <form
          className="flex flex-col gap-4"
          onSubmit={(event) => {
            event.preventDefault();
            if (!valid || pending) return;
            void onSave({
              name: name.trim(),
              prompt: noAgent ? "" : prompt.trim(),
              schedule,
              deliver,
              skills: noAgent ? [] : selectedSkills,
              model: noAgent ? undefined : model.trim() || undefined,
              provider: noAgent ? undefined : provider.trim() || undefined,
              script: script.trim() || undefined,
              workdir: workdir.trim() || undefined,
              enabledToolsets: noAgent ? [] : selectedToolsets,
              noAgent,
              continuity: pantheon && !noAgent ? continuity : false,
              monitorScript:
                pantheon && !noAgent && monitorKind === "script"
                  ? monitorValue.trim() || undefined
                  : undefined,
              monitorUrl:
                pantheon && !noAgent && monitorKind === "url"
                  ? monitorValue.trim() || undefined
                  : undefined,
              reasoningEffort:
                pantheon && !noAgent ? reasoningEffort || undefined : undefined,
            });
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

          <fieldset className="flex flex-col gap-2">
            <legend className="mb-1 text-sm">{t("cron.mode")}</legend>
            <div className="grid grid-cols-2 gap-2">
              <ModeButton
                active={!noAgent}
                onClick={() => setNoAgent(false)}
                label={t("cron.modeAgent")}
              />
              <ModeButton
                active={noAgent}
                onClick={() => setNoAgent(true)}
                label={t("cron.modeScript")}
              />
            </div>
          </fieldset>

          {noAgent ? (
            <label className="flex flex-col gap-1.5 text-sm">
              {t("cron.script")}
              <Input
                value={script}
                onChange={(event) => setScript(event.target.value)}
                placeholder={t("cron.scriptPlaceholder")}
              />
              <span className="text-xs text-muted-foreground">
                {t("cron.scriptHint")}
              </span>
            </label>
          ) : (
            <label className="flex flex-col gap-1.5 text-sm">
              {t("cron.instructions")}
              <textarea
                value={prompt}
                onChange={(event) => setPrompt(event.target.value)}
                placeholder={t("cron.instructionsPlaceholder")}
                className="min-h-28 resize-y rounded-md bg-muted px-3 py-2 text-base text-foreground shadow-border placeholder:text-muted-foreground/80 focus-visible:outline-none md:text-sm"
              />
            </label>
          )}

          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <label className="flex flex-col gap-1.5 text-sm">
              {t("cron.frequency")}
              <select
                value={frequency}
                onChange={(event) =>
                  setFrequency(event.target.value as CronFrequency)
                }
                className="h-11 w-full rounded-md bg-muted px-3 text-base text-foreground shadow-border focus-visible:outline-none md:text-sm"
              >
                <option value="daily">{t("cron.daily")}</option>
                <option value="weekdays">{t("cron.weekdays")}</option>
                <option value="weekly">{t("cron.weekly")}</option>
                <option value="hourly">{t("cron.hourly")}</option>
                <option value="custom">{t("cron.custom")}</option>
              </select>
            </label>
            {frequency === "custom" ? (
              <label className="flex flex-col gap-1.5 text-sm">
                {t("cron.schedule")}
                <Input
                  value={customSchedule}
                  onChange={(event) => setCustomSchedule(event.target.value)}
                  placeholder="every 2h"
                />
              </label>
            ) : frequency !== "hourly" ? (
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

          <label className="flex flex-col gap-1.5 text-sm">
            {t("cron.delivery")}
            <select
              value={deliver}
              onChange={(event) => setDeliver(event.target.value)}
              className="h-11 w-full rounded-md bg-muted px-3 text-base text-foreground shadow-border focus-visible:outline-none md:text-sm"
            >
              {(deliveryTargets.length
                ? deliveryTargets
                : [
                    {
                      id: "local",
                      name: t("cron.deliveryLocal"),
                      homeTargetSet: true,
                    },
                  ]
              ).map((target) => (
                <option
                  key={target.id}
                  value={target.id}
                  disabled={!target.homeTargetSet}
                >
                  {target.name}
                  {target.homeTargetSet
                    ? ""
                    : ` — ${t("cron.deliveryUnavailable")}`}
                </option>
              ))}
            </select>
          </label>

          {!noAgent && skills.length ? (
            <ChoiceList
              label={t("cron.skills")}
              rows={skills
                .filter((skill) => skill.enabled)
                .map((skill) => ({
                  id: skill.name,
                  label: skill.title,
                }))}
              selected={selectedSkills}
              onChange={setSelectedSkills}
            />
          ) : null}

          <details className="rounded-md bg-muted px-3 py-2 shadow-border">
            <summary className="min-h-10 cursor-pointer select-none py-2 text-sm font-medium">
              {t("cron.advanced")}
            </summary>
            <div className="flex flex-col gap-4 pb-2 pt-3">
              {!noAgent ? (
                <>
                  {pantheon ? (
                    <div className="flex flex-col gap-4">
                      <label className="flex min-h-11 items-center justify-between gap-4 text-sm">
                        <span className="flex min-w-0 flex-col gap-0.5">
                          <span>{t("cron.continuity")}</span>
                          <span className="text-xs text-muted-foreground">
                            {t("cron.continuityHint")}
                          </span>
                        </span>
                        <Switch
                          checked={continuity}
                          onCheckedChange={setContinuity}
                          aria-label={t("cron.continuity")}
                        />
                      </label>
                      <label className="flex flex-col gap-1.5 text-sm">
                        {t("cron.reasoningEffort")}
                        <select
                          value={reasoningEffort}
                          onChange={(event) =>
                            setReasoningEffort(
                              event.target.value as ReasoningEffort | "",
                            )
                          }
                          className="h-11 w-full rounded-md bg-muted px-3 text-base text-foreground shadow-border focus-visible:outline-none md:text-sm"
                        >
                          <option value="">{t("cron.reasoningDefault")}</option>
                          {reasoningEfforts.map((effort) => (
                            <option key={effort} value={effort}>
                              {effort}
                            </option>
                          ))}
                        </select>
                      </label>
                      <label className="flex flex-col gap-1.5 text-sm">
                        {t("cron.monitorMode")}
                        <select
                          value={monitorKind}
                          onChange={(event) => {
                            setMonitorKind(
                              event.target.value as "none" | "script" | "url",
                            );
                            setMonitorValue("");
                          }}
                          className="h-11 w-full rounded-md bg-muted px-3 text-base text-foreground shadow-border focus-visible:outline-none md:text-sm"
                        >
                          <option value="none">{t("cron.monitorOff")}</option>
                          <option value="script">
                            {t("cron.monitorScript")}
                          </option>
                          <option value="url">{t("cron.monitorUrl")}</option>
                        </select>
                      </label>
                      {monitorKind !== "none" ? (
                        <label className="flex flex-col gap-1.5 text-sm">
                          {monitorKind === "script"
                            ? t("cron.monitorScriptPath")
                            : t("cron.monitorUrlAddress")}
                          <Input
                            value={monitorValue}
                            onChange={(event) =>
                              setMonitorValue(event.target.value)
                            }
                            placeholder={
                              monitorKind === "script"
                                ? "check-updates.sh"
                                : "https://example.com/feed"
                            }
                          />
                          <span className="text-xs text-muted-foreground">
                            {t("cron.monitorHint")}
                          </span>
                        </label>
                      ) : null}
                      <p className="text-xs text-muted-foreground">
                        {t("cron.notepadHint")}
                      </p>
                    </div>
                  ) : null}
                  <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                    <label className="flex flex-col gap-1.5 text-sm">
                      {t("cron.model")}
                      <Input
                        value={model}
                        onChange={(event) => setModel(event.target.value)}
                      />
                    </label>
                    <label className="flex flex-col gap-1.5 text-sm">
                      {t("cron.provider")}
                      <Input
                        value={provider}
                        onChange={(event) => setProvider(event.target.value)}
                      />
                    </label>
                  </div>
                  {toolsets.length ? (
                    <ChoiceList
                      label={t("cron.toolsets")}
                      rows={toolsets
                        .filter((toolset) => toolset.enabled)
                        .map((toolset) => ({
                          id: toolset.name,
                          label: toolset.label,
                        }))}
                      selected={selectedToolsets}
                      onChange={setSelectedToolsets}
                    />
                  ) : null}
                  <label className="flex flex-col gap-1.5 text-sm">
                    {t("cron.preScript")}
                    <Input
                      value={script}
                      onChange={(event) => setScript(event.target.value)}
                    />
                  </label>
                </>
              ) : null}
              <label className="flex flex-col gap-1.5 text-sm">
                {t("cron.workdir")}
                <Input
                  value={workdir}
                  onChange={(event) => setWorkdir(event.target.value)}
                />
              </label>
            </div>
          </details>

          {error ? <p className="text-sm text-destructive">{error}</p> : null}
          <div className="flex justify-end gap-2">
            <Button
              type="button"
              variant="ghost"
              onClick={() => onOpenChange(false)}
              disabled={pending}
            >
              {t("cron.cancel")}
            </Button>
            <Button type="submit" disabled={pending || !valid}>
              {pending
                ? job
                  ? t("cron.saving")
                  : t("cron.creating")
                : job
                  ? t("cron.save")
                  : t("cron.create")}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function ModeButton({
  active,
  label,
  onClick,
}: {
  active: boolean;
  label: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onClick}
      className={`min-h-11 rounded-md px-3 text-sm shadow-border transition-colors ${
        active ? "bg-foreground text-background" : "bg-muted text-foreground"
      }`}
    >
      {label}
    </button>
  );
}

function ChoiceList({
  label,
  rows,
  selected,
  onChange,
}: {
  label: string;
  rows: Array<{ id: string; label: string }>;
  selected: string[];
  onChange: (value: string[]) => void;
}) {
  return (
    <fieldset className="flex flex-col gap-2">
      <legend className="mb-1 text-sm">{label}</legend>
      <div className="grid max-h-40 grid-cols-1 gap-1 overflow-y-auto sm:grid-cols-2">
        {rows.map((row) => (
          <label
            key={row.id}
            className="flex min-h-11 items-center gap-2 rounded-md px-2 text-sm hover:bg-accent"
          >
            <input
              type="checkbox"
              checked={selected.includes(row.id)}
              onChange={(event) =>
                onChange(
                  event.target.checked
                    ? [...selected, row.id]
                    : selected.filter((item) => item !== row.id),
                )
              }
              className="size-4 accent-primary"
            />
            <span className="min-w-0 truncate">{row.label}</span>
          </label>
        ))}
      </div>
    </fieldset>
  );
}
