export type SlashCommand = {
  cmd: string;
  hint: string;
};

export const SLASH_COMMANDS: SlashCommand[] = [
  { cmd: "/new", hint: "Empieza un chat nuevo" },
  { cmd: "/model", hint: "Cambia el modelo" },
  { cmd: "/help", hint: "Lista los comandos" },
  { cmd: "/status", hint: "Estado de esta sesión" },
  { cmd: "/tools", hint: "Herramientas disponibles" },
  { cmd: "/skills", hint: "Habilidades" },
  { cmd: "/memory", hint: "Memoria" },
  { cmd: "/save", hint: "Guarda la conversación" },
  { cmd: "/retry", hint: "Reintenta el último mensaje" },
  { cmd: "/undo", hint: "Quita el último intercambio" },
  { cmd: "/title", hint: "Pone título al chat" },
  { cmd: "/stop", hint: "Para lo que está en marcha" },
  { cmd: "/plan", hint: "Entra en modo plan" },
  { cmd: "/personality", hint: "Cambia el tono" },
  { cmd: "/compress", hint: "Resume el contexto" },
  { cmd: "/clear", hint: "Limpia y empieza de nuevo" },
  { cmd: "/config", hint: "Ver la configuración" },
  { cmd: "/reasoning", hint: "Nivel de razonamiento" },
  { cmd: "/fast", hint: "Respuestas más rápidas" },
  { cmd: "/focus", hint: "Menos ruido en la respuesta" },
  { cmd: "/yolo", hint: "Actúa sin pedir permiso" },
  { cmd: "/approvals", hint: "Cómo pedir permiso" },
  { cmd: "/browser", hint: "El navegador" },
  { cmd: "/cron", hint: "Tareas programadas" },
  { cmd: "/learn", hint: "Aprende una habilidad" },
  { cmd: "/resume", hint: "Sigue un chat anterior" },
  { cmd: "/sessions", hint: "Tus sesiones" },
  { cmd: "/history", hint: "Historial de este chat" },
  { cmd: "/context", hint: "Cuánto contexto se está usando" },
  { cmd: "/agents", hint: "Agentes en marcha" },
  { cmd: "/background", hint: "Lanza una tarea aparte" },
  { cmd: "/branch", hint: "Bifurca este chat" },
  { cmd: "/review", hint: "Revisa el trabajo reciente" },
  { cmd: "/goal", hint: "Objetivo de la sesión" },
  { cmd: "/steer", hint: "Nota a mitad de respuesta" },
  { cmd: "/queue", hint: "Encola el siguiente mensaje" },
  { cmd: "/bundles", hint: "Paquetes de habilidades" },
  { cmd: "/init", hint: "Prepara el proyecto" },
  { cmd: "/verbose", hint: "Más detalle de las herramientas" },
  { cmd: "/reset", hint: "Igual que /new" },
];

export function slashQuery(draft: string): string | null {
  if (!draft.startsWith("/")) return null;
  if (draft.includes("\n")) return null;
  const space = draft.indexOf(" ");
  if (space !== -1) return null;
  return draft.toLowerCase();
}

export function matchSlash(
  draft: string,
  extra: SlashCommand[] = [],
): SlashCommand[] {
  const q = slashQuery(draft);
  if (q === null) return [];
  const all = [...SLASH_COMMANDS, ...extra];
  const seen = new Set<string>();
  const hits: SlashCommand[] = [];
  for (const item of all) {
    if (seen.has(item.cmd)) continue;
    if (q === "/" || item.cmd.startsWith(q) || item.cmd.slice(1).includes(q.slice(1))) {
      seen.add(item.cmd);
      hits.push(item);
    }
    if (hits.length >= 14) break;
  }
  return hits;
}
