import { createFileRoute } from "@tanstack/react-router";
import { AppShell } from "@/components/shell";

export const Route = createFileRoute("/_app")({
  component: AppShell,
});
