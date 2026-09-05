import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  RADAR_IA_DEFAULT_TIME,
  RADAR_IA_DEFAULT_ZONE,
  radarSetupPrompt,
  validRadarSchedule,
} from "@/lib/radar-ia";
import { useT } from "@/lib/use-i18n";

export function RadarIASetup({
  onPrepare,
}: {
  onPrepare: (prompt: string) => void;
}) {
  const t = useT();
  const [time, setTime] = useState(RADAR_IA_DEFAULT_TIME);
  const [zone, setZone] = useState(RADAR_IA_DEFAULT_ZONE);
  const valid = validRadarSchedule(time, zone.trim());
  return (
    <section className="rounded-xl border border-border bg-card p-4">
      <h2 className="font-medium">Radar IA</h2>
      <p className="mt-1 text-sm text-muted-foreground">
        {t("radar.description")}
      </p>
      <form
        className="mt-4 flex flex-col gap-3"
        onSubmit={(event) => {
          event.preventDefault();
          if (valid) onPrepare(radarSetupPrompt(time, zone));
        }}
      >
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <label className="flex flex-col gap-1.5 text-sm">
            {t("radar.time")}
            <Input
              type="time"
              required
              value={time}
              onChange={(event) => setTime(event.target.value)}
            />
          </label>
          <label className="flex flex-col gap-1.5 text-sm">
            {t("radar.zone")}
            <Input
              required
              value={zone}
              onChange={(event) => setZone(event.target.value)}
              aria-invalid={!validRadarSchedule("10:00", zone.trim())}
              aria-describedby="radar-zone-hint"
            />
          </label>
        </div>
        <p id="radar-zone-hint" className="text-xs text-muted-foreground">
          {t("radar.zoneHint")}
        </p>
        <p className="text-sm text-muted-foreground">{t("radar.setupHint")}</p>
        <Button type="submit" disabled={!valid} className="self-start">
          {t("radar.prepare")}
        </Button>
      </form>
    </section>
  );
}
