import { createFileRoute } from "@tanstack/react-router";
import { ChatView } from "@/components/chat";

export const Route = createFileRoute("/_app/")({
  component: ChatView,
});
