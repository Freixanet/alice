import type { LucideIcon } from "lucide-react";
import {
  Blocks,
  Cable,
  Clock,
  FolderKanban,
  Puzzle,
  Settings,
  Sparkles,
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
    to: "/memory",
    labelKey: "nav.memory",
    hintKey: "nav.memoryHint",
    icon: Blocks,
  },
  { to: "/cron", labelKey: "nav.cron", hintKey: "nav.cronHint", icon: Clock },
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
