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

export type NavItem = {
  to: string;
  label: string;
  hint: string;
  icon: LucideIcon;
  shortcut?: string;
};

export const NAV: NavItem[] = [
  { to: "/skills", label: "Habilidades", hint: "Skills", icon: Sparkles },
  { to: "/tools", label: "Herramientas", hint: "Tools", icon: Wrench },
  { to: "/addons", label: "Complementos", hint: "MCP", icon: Puzzle },
  { to: "/projects", label: "Proyectos", hint: "Carpetas de Hermes", icon: FolderKanban },
  { to: "/memory", label: "Memoria", hint: "Lo que recuerda", icon: Blocks },
  { to: "/cron", label: "Tareas", hint: "Cron", icon: Clock },
  { to: "/connect", label: "Conectar", hint: "Tu agente, canales", icon: Cable },
];

export const SETTINGS_NAV: NavItem = {
  to: "/settings",
  label: "Ajustes",
  hint: "Perfil y opciones",
  icon: Settings,
};
