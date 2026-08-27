import { useEffect, useMemo, useState } from "react";
import { Link, Outlet, useNavigate, useRouterState } from "@tanstack/react-router";
import { MoreHorizontal, PanelLeft, Pencil, Pin, PinOff, Search, Share, SquarePen, Trash2, type LucideIcon } from "lucide-react";
import { Mark, Wordmark } from "@/components/logo";
import { SettingsDialog } from "@/components/settings-panel";
import {
  Command,
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { NAV, SETTINGS_NAV } from "@/lib/nav";
import { useGatewayHealth } from "@/lib/use-gateway-health";
import { useHermes } from "@/lib/store";
import type { Conversation } from "@/lib/types";
import { cn } from "@/lib/utils";
import { useCurrentUser } from "@/lib/auth/use-current-user";

export function AppShell() {
  useGatewayHealth();
  const navigate = useNavigate();
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const theme = useHermes((s) => s.theme);
  const fontSize = useHermes((s) => s.fontSize);
  const accent = useHermes((s) => s.accent);
  const collapsed = useHermes((s) => s.sidebarCollapsed);
  const setCollapsed = useHermes((s) => s.setSidebarCollapsed);
  const conversations = useHermes((s) => s.conversations);
  const activeId = useHermes((s) => s.activeId);
  const selectChat = useHermes((s) => s.selectChat);
  const newChat = useHermes((s) => s.newChat);
  const gatewayOn = useHermes((s) => s.gatewayOn);
  const gatewayStatus = useHermes((s) => s.gatewayStatus);
  const [searchOpen, setSearchOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const settingsFromRoute = pathname === "/settings";
  const settingsVisible = settingsOpen || settingsFromRoute;

  function handleSettingsOpenChange(open: boolean) {
    setSettingsOpen(open);
    if (!open && settingsFromRoute) {
      void navigate({ to: "/" });
    }
  }

  useEffect(() => {
    const root = document.documentElement;
    root.dataset.theme = theme;
    root.dataset.font = fontSize;
    root.dataset.accent = accent;
  }, [theme, fontSize, accent]);

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      const meta = e.metaKey || e.ctrlKey;
      if (meta && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setSearchOpen((v) => !v);
      }
      if (meta && e.key.toLowerCase() === "n") {
        e.preventDefault();
        newChat();
        void navigate({ to: "/" });
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [navigate, newChat]);

  const live = gatewayOn && gatewayStatus === "live";

  function startChat() {
    newChat();
    void navigate({ to: "/" });
  }

  return (
    <TooltipProvider delayDuration={200}>
      <div className="flex h-dvh overflow-hidden bg-background">
        <aside
          className={cn(
            "flex h-full shrink-0 flex-col border-r border-border",
            collapsed ? "w-14" : "w-64",
          )}
        >
          {collapsed ? (
            <CollapsedRail
              pathname={pathname}
              live={live}
              onExpand={() => setCollapsed(false)}
              onSearch={() => setSearchOpen(true)}
              onNewChat={startChat}
              onOpenSettings={() => setSettingsOpen(true)}
            />
          ) : (
            <ExpandedSidebar
              pathname={pathname}
              live={live}
              conversations={conversations}
              activeId={activeId}
              onCollapse={() => setCollapsed(true)}
              onSearch={() => setSearchOpen(true)}
              onNewChat={startChat}
              onOpenSettings={() => setSettingsOpen(true)}
              onSelectChat={(id) => {
                selectChat(id);
                void navigate({ to: "/" });
              }}
            />
          )}
        </aside>
        <div className="flex min-w-0 flex-1 flex-col">
          <Outlet />
        </div>
        <CommandPalette
          open={searchOpen}
          onOpenChange={setSearchOpen}
          conversations={conversations}
          onPickChat={(id) => {
            selectChat(id);
            void navigate({ to: "/" });
          }}
          onOpenSettings={() => setSettingsOpen(true)}
        />
        <SettingsDialog open={settingsVisible} onOpenChange={handleSettingsOpenChange} />
      </div>
    </TooltipProvider>
  );
}

function CollapsedRail({
  pathname,
  live,
  onExpand,
  onSearch,
  onNewChat,
  onOpenSettings,
}: {
  pathname: string;
  live: boolean;
  onExpand: () => void;
  onSearch: () => void;
  onNewChat: () => void;
  onOpenSettings: () => void;
}) {
  const user = useCurrentUser();
  const mark = accountMark(user?.displayName, user?.primaryEmail);
  return (
    <div className="flex h-full w-full flex-col py-3">
      <div className="flex w-full justify-center">
        <IconBtn label="Abrir barra" onClick={onExpand}>
          <span className="relative grid size-7 place-items-center">
            <Mark className="size-7 group-hover:hidden" />
            <span className="hidden group-hover:grid">
              <RailGlyph icon={PanelLeft} />
            </span>
          </span>
        </IconBtn>
      </div>
      <nav className="mt-5 flex w-full flex-col items-center gap-1">
        <IconBtn label="Nuevo chat" onClick={onNewChat}>
          <RailGlyph icon={SquarePen} heavy />
        </IconBtn>
        <IconBtn label="Buscar" onClick={onSearch}>
          <RailGlyph icon={Search} heavy />
        </IconBtn>
        {NAV.map((item) => (
          <IconLink key={item.to} to={item.to} label={item.label} active={pathname === item.to}>
            <RailGlyph icon={item.icon} />
          </IconLink>
        ))}
      </nav>
      <div className="mt-auto flex w-full justify-center pb-2">
        <button
          type="button"
          aria-label="Ajustes"
          onClick={onOpenSettings}
          className="relative grid size-7 place-items-center rounded-full bg-foreground p-0 text-[11px] font-medium text-background"
        >
          {mark}
          {live ? (
            <span
              className="absolute -right-px -bottom-px size-2 rounded-full bg-live ring-2 ring-background"
              title="Tu agente"
            />
          ) : null}
        </button>
      </div>
    </div>
  );
}

function ExpandedSidebar({
  pathname,
  live,
  conversations,
  activeId,
  onCollapse,
  onSearch,
  onNewChat,
  onOpenSettings,
  onSelectChat,
}: {
  pathname: string;
  live: boolean;
  conversations: Conversation[];
  activeId: string;
  onCollapse: () => void;
  onSearch: () => void;
  onNewChat: () => void;
  onOpenSettings: () => void;
  onSelectChat: (id: string) => void;
}) {
  const renameChat = useHermes((s) => s.renameChat);
  const pinChat = useHermes((s) => s.pinChat);
  const deleteChat = useHermes((s) => s.deleteChat);
  const [renameId, setRenameId] = useState<string | null>(null);
  const [renameValue, setRenameValue] = useState("");
  const [deleteId, setDeleteId] = useState<string | null>(null);
  const pinned = useMemo(
    () => conversations.filter((c) => c.pinned).sort((a, b) => b.updatedAt - a.updatedAt),
    [conversations],
  );
  const rest = useMemo(
    () => conversations.filter((c) => !c.pinned).sort((a, b) => b.updatedAt - a.updatedAt),
    [conversations],
  );
  const deleting = conversations.find((c) => c.id === deleteId);
  const user = useCurrentUser();
  const mark = accountMark(user?.displayName, user?.primaryEmail);
  const label = user?.displayName || user?.primaryEmail?.split("@")[0] || "Tú";

  function saveRename() {
    if (!renameId) return;
    renameChat(renameId, renameValue);
    setRenameId(null);
  }

  function row(c: Conversation) {
    return (
      <ChatRow
        key={c.id}
        chat={c}
        active={c.id === activeId}
        onSelect={() => onSelectChat(c.id)}
        onShare={() => void shareChat(c)}
        onRename={() => {
          setRenameValue(c.title);
          setRenameId(c.id);
        }}
        onPin={() => pinChat(c.id)}
        onDelete={() => setDeleteId(c.id)}
      />
    );
  }

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="flex items-center gap-1 px-3 py-3">
        <Link to="/" className="flex min-w-0 items-center gap-2 text-foreground">
          <Mark className="size-7 shrink-0" />
          <Wordmark className="text-3xl" />
        </Link>
        <div className="ml-auto flex items-center">
          <IconBtn label="Buscar" onClick={onSearch}>
            <RailGlyph icon={Search} heavy />
          </IconBtn>
          <IconBtn label="Cerrar barra" onClick={onCollapse}>
            <RailGlyph icon={PanelLeft} />
          </IconBtn>
        </div>
      </div>
      <nav className="mt-3 flex flex-col gap-0.5 px-2">
        {NAV.map((item) => (
          <Link
            key={item.to}
            to={item.to}
            className={cn(
              "flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm",
              pathname === item.to
                ? "bg-accent text-foreground"
                : "text-foreground/80 hover:bg-accent hover:text-foreground",
            )}
          >
            <RailGlyph icon={item.icon} />
            {item.label}
          </Link>
        ))}
      </nav>
      <ScrollArea className="min-h-0 flex-1 px-2 py-1">
        {pinned.length > 0 ? (
          <>
            <p className="mt-8 px-2 pb-1 text-2xs font-medium text-muted-foreground">Fijados</p>
            <ul className="flex flex-col gap-0.5">{pinned.map(row)}</ul>
          </>
        ) : null}
        <p
          className={cn(
            "px-2 pb-1 text-2xs font-medium text-muted-foreground",
            pinned.length > 0 ? "mt-5" : "mt-8",
          )}
        >
          Chats
        </p>
        <ul className="flex flex-col gap-0.5">{rest.map(row)}</ul>
      </ScrollArea>
      <div className="mt-auto border-t border-border px-3 py-3">
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={onOpenSettings}
            className="flex min-w-0 flex-1 items-center gap-2 text-left text-foreground"
          >
            <span className="relative grid size-7 shrink-0 place-items-center rounded-full bg-foreground text-[11px] font-medium text-background">
              {mark}
              {live ? (
                <span
                  className="absolute -right-px -bottom-px size-2 rounded-full bg-live ring-2 ring-background"
                  title="Tu agente"
                />
              ) : null}
            </span>
            <span className="truncate text-sm">{label}</span>
          </button>
          <IconBtn label="Nuevo chat" onClick={onNewChat}>
            <RailGlyph icon={SquarePen} heavy />
          </IconBtn>
        </div>
      </div>
      <Dialog open={Boolean(renameId)} onOpenChange={(open) => !open && setRenameId(null)}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Renombrar</DialogTitle>
            <DialogDescription>El nombre aparece en el historial.</DialogDescription>
          </DialogHeader>
          <Input
            value={renameValue}
            onChange={(e) => setRenameValue(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                saveRename();
              }
            }}
            autoFocus
          />
          <div className="flex justify-end gap-2">
            <button
              type="button"
              className="rounded-lg px-3 py-2 text-sm text-muted-foreground hover:bg-accent hover:text-foreground"
              onClick={() => setRenameId(null)}
            >
              Cancelar
            </button>
            <button
              type="button"
              className="rounded-lg bg-foreground px-3 py-2 text-sm text-background"
              onClick={saveRename}
            >
              Guardar
            </button>
          </div>
        </DialogContent>
      </Dialog>
      <Dialog open={Boolean(deleteId)} onOpenChange={(open) => !open && setDeleteId(null)}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Eliminar chat</DialogTitle>
            <DialogDescription>
              Se borrará «{deleting?.title}». No se puede deshacer.
            </DialogDescription>
          </DialogHeader>
          <div className="flex justify-end gap-2">
            <button
              type="button"
              className="rounded-lg px-3 py-2 text-sm text-muted-foreground hover:bg-accent hover:text-foreground"
              onClick={() => setDeleteId(null)}
            >
              Cancelar
            </button>
            <button
              type="button"
              className="rounded-lg bg-destructive px-3 py-2 text-sm text-white"
              onClick={() => {
                if (deleteId) deleteChat(deleteId);
                setDeleteId(null);
              }}
            >
              Eliminar
            </button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}

function ChatRow({
  chat,
  active,
  onSelect,
  onShare,
  onRename,
  onPin,
  onDelete,
}: {
  chat: Conversation;
  active: boolean;
  onSelect: () => void;
  onShare: () => void;
  onRename: () => void;
  onPin: () => void;
  onDelete: () => void;
}) {
  const [menuOpen, setMenuOpen] = useState(false);
  return (
    <li className="group relative">
      <button
        type="button"
        onClick={onSelect}
        className={cn(
          "w-full truncate rounded-lg py-2 pr-8 pl-2.5 text-left text-sm",
          active
            ? "bg-accent text-foreground"
            : "text-muted-foreground hover:bg-accent hover:text-foreground",
        )}
      >
        {chat.title}
      </button>
      <DropdownMenu open={menuOpen} onOpenChange={setMenuOpen}>
        <DropdownMenuTrigger asChild>
          <button
            type="button"
            aria-label="Opciones del chat"
            className={cn(
              "absolute top-1/2 right-1 grid size-7 -translate-y-1/2 place-items-center rounded-md text-muted-foreground hover:bg-background hover:text-foreground",
              menuOpen ? "opacity-100" : "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100",
            )}
          >
            <MoreHorizontal className="size-4" />
          </button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="min-w-40">
          <DropdownMenuItem onSelect={onShare}>
            <Share className="size-4" />
            Compartir
          </DropdownMenuItem>
          <DropdownMenuItem onSelect={onRename}>
            <Pencil className="size-4" />
            Renombrar
          </DropdownMenuItem>
          <DropdownMenuItem onSelect={onPin}>
            {chat.pinned ? <PinOff className="size-4" /> : <Pin className="size-4" />}
            {chat.pinned ? "Desfijar" : "Fijar"}
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            onSelect={onDelete}
            className="text-destructive focus:bg-destructive/10 focus:text-destructive"
          >
            <Trash2 className="size-4" />
            Eliminar
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </li>
  );
}

async function shareChat(chat: Conversation) {
  const url = window.location.origin + "/";
  const payload = { title: chat.title, text: `Chat en Alice: ${chat.title}`, url };
  try {
    if (navigator.share) {
      await navigator.share(payload);
      return;
    }
  } catch {
    // fall through to clipboard
  }
  try {
    await navigator.clipboard.writeText(`${chat.title}\n${url}`);
  } catch {
    // ignore
  }
}

function accountMark(name?: string | null, email?: string | null) {
  const src = (name || email || "Tú").trim();
  return src.charAt(0).toUpperCase() || "T";
}

function RailGlyph({ icon: Icon, heavy = false }: { icon: LucideIcon; heavy?: boolean }) {
  return (
    <Icon
      size={16}
      strokeWidth={2}
      className={cn(
        "shrink-0",
        heavy &&
          "[&_circle]:[stroke-width:1.5px] [&_circle]:[vector-effect:non-scaling-stroke] [&_path]:[stroke-width:1.5px] [&_path]:[vector-effect:non-scaling-stroke]",
      )}
    />
  );
}

function IconBtn({
  label,
  onClick,
  children,
}: {
  label: string;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <button
          type="button"
          aria-label={label}
          onClick={onClick}
          className="group grid size-8 place-items-center rounded-md p-0 text-foreground/80 hover:bg-accent hover:text-foreground"
        >
          {children}
        </button>
      </TooltipTrigger>
      <TooltipContent side="right">{label}</TooltipContent>
    </Tooltip>
  );
}

function IconLink({
  to,
  label,
  active,
  children,
}: {
  to: string;
  label: string;
  active: boolean;
  children: React.ReactNode;
}) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Link
          to={to}
          aria-label={label}
          className={cn(
            "grid size-8 place-items-center rounded-md p-0",
            active ? "bg-accent text-foreground" : "text-foreground/80 hover:bg-accent hover:text-foreground",
          )}
        >
          {children}
        </Link>
      </TooltipTrigger>
      <TooltipContent side="right">{label}</TooltipContent>
    </Tooltip>
  );
}

function CommandPalette({
  open,
  onOpenChange,
  conversations,
  onPickChat,
  onOpenSettings,
}: {
  open: boolean;
  onOpenChange: (v: boolean) => void;
  conversations: { id: string; title: string }[];
  onPickChat: (id: string) => void;
  onOpenSettings: () => void;
}) {
  const navigate = useNavigate();
  const items = useMemo(() => NAV, []);
  return (
    <CommandDialog open={open} onOpenChange={onOpenChange}>
      <Command>
        <CommandInput placeholder="Buscar en Alice…" />
        <CommandList>
          <CommandEmpty>Nada coincide.</CommandEmpty>
          <CommandGroup heading="Ir">
            {items.map((item) => (
              <CommandItem
                key={item.to}
                onSelect={() => {
                  onOpenChange(false);
                  void navigate({ to: item.to });
                }}
              >
                <item.icon className="size-4" />
                {item.label}
              </CommandItem>
            ))}
            <CommandItem
              onSelect={() => {
                onOpenChange(false);
                onOpenSettings();
              }}
            >
              <SETTINGS_NAV.icon className="size-4" />
              {SETTINGS_NAV.label}
            </CommandItem>
          </CommandGroup>
          <CommandGroup heading="Chats">
            {conversations.map((c) => (
              <CommandItem
                key={c.id}
                onSelect={() => {
                  onOpenChange(false);
                  onPickChat(c.id);
                }}
              >
                {c.title}
              </CommandItem>
            ))}
          </CommandGroup>
        </CommandList>
      </Command>
    </CommandDialog>
  );
}
