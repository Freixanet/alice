import type { LucideIcon } from "lucide-react";
import {
  Blocks,
  Activity,
  Cable,
  Clock,
  FolderKanban,
  Paperclip,
  Puzzle,
  Settings,
  Sparkles,
  UsersRound,
  Wrench,
} from "lucide-react";
import type { MsgKey } from "./i18n";

export type NavItem = {
  to: string;
  labelKey: MsgKey;
  hintKey: MsgKey;
  icon: LucideIcon;
  shortcut?: string;
};

export const NAV: NavItem[] = [
  {
    to: "/agents",
    labelKey: "nav.agents",
    hintKey: "nav.agentsHint",
    icon: UsersRound,
  },
  {
    to: "/skills",
    labelKey: "nav.skills",
    hintKey: "nav.skillsHint",
    icon: Sparkles,
  },
  {
    to: "/tools",
    labelKey: "nav.tools",
    hintKey: "nav.toolsHint",
    icon: Wrench,
  },
  {
    to: "/addons",
    labelKey: "nav.addons",
    hintKey: "nav.addonsHint",
    icon: Puzzle,
  },
  {
    to: "/projects",
    labelKey: "nav.projects",
    hintKey: "nav.projectsHint",
    icon: FolderKanban,
  },
  {
    to: "/artifacts",
    labelKey: "nav.artifacts",
    hintKey: "nav.artifactsHint",
    icon: Paperclip,
  },
  {
    to: "/memory",
    labelKey: "nav.memory",
    hintKey: "nav.memoryHint",
    icon: Blocks,
  },
  { to: "/cron", labelKey: "nav.cron", hintKey: "nav.cronHint", icon: Clock },
  {
    to: "/insights",
    labelKey: "nav.insights",
    hintKey: "nav.insightsHint",
    icon: Activity,
  },
  {
    to: "/connect",
    labelKey: "nav.connect",
    hintKey: "nav.connectHint",
    icon: Cable,
  },
];

export const SETTINGS_NAV: NavItem = {
  to: "/settings",
  labelKey: "nav.settings",
  hintKey: "nav.settingsHint",
  icon: Settings,
};
