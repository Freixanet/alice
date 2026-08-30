export type CronFrequency =
  "daily" | "weekdays" | "weekly" | "hourly" | "custom";

export function cronScheduleFor(
  frequency: CronFrequency,
  time: string,
  custom: string,
): string {
  if (frequency === "custom") return custom.trim();
  if (frequency === "hourly") return "0 * * * *";
  const [hours = "9", minutes = "0"] = time.split(":");
  const minute = boundedNumber(minutes, 0, 59, 0);
  const hour = boundedNumber(hours, 0, 23, 9);
  if (frequency === "weekdays") return `${minute} ${hour} * * 1-5`;
  if (frequency === "weekly") return `${minute} ${hour} * * 1`;
  return `${minute} ${hour} * * *`;
}

export function cronScheduleFields(schedule: string): {
  frequency: CronFrequency;
  time: string;
  custom: string;
} {
  const value = schedule.trim();
  if (value === "0 * * * *") {
    return { frequency: "hourly", time: "09:00", custom: "" };
  }
  const match = /^(\d{1,2}) (\d{1,2}) \* \* (\*|1|1-5)$/.exec(value);
  if (!match) {
    return { frequency: "custom", time: "09:00", custom: value };
  }
  const minutes = boundedNumber(match[1] ?? "0", 0, 59, 0);
  const hours = boundedNumber(match[2] ?? "9", 0, 23, 9);
  const day = match[3];
  return {
    frequency: day === "1-5" ? "weekdays" : day === "1" ? "weekly" : "daily",
    time: `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}`,
    custom: "",
  };
}

function boundedNumber(
  value: string,
  min: number,
  max: number,
  fallback: number,
): number {
  const parsed = Number.parseInt(value, 10);
  return Number.isInteger(parsed) && parsed >= min && parsed <= max
    ? parsed
    : fallback;
}
