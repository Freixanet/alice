import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { PageHeader } from "@/components/catalog-page";
import { HermesProfilesSettings } from "@/components/hermes-profiles-settings";
import { HermesRoomsPanel } from "@/components/hermes-rooms-panel";
import { useHermes } from "@/lib/store";
import { useT } from "@/lib/use-i18n";

export const Route = createFileRoute("/_app/agents")({
  component: AgentsPage,
});

function AgentsPage() {
  const t = useT();
  const navigate = useNavigate();
  const newChat = useHermes((state) => state.newChat);
  const setProfile = useHermes((state) => state.setProfile);

  function openAgent(profile: string) {
    setProfile(profile);
    newChat(profile);
    void navigate({ to: "/" });
  }

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      <main className="mx-auto flex w-full max-w-3xl flex-col gap-6 px-4 py-8 pb-20 sm:px-6">
        <PageHeader
          kicker={t("agents.kicker")}
          title={t("agents.title")}
          description={t("agents.description")}
        />
        <HermesProfilesSettings onChatProfile={openAgent} />
        <HermesRoomsPanel />
      </main>
    </div>
  );
}
