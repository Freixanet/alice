import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import {
  Link,
  Outlet,
  useNavigate,
  useRouterState,
} from "@tanstack/react-router";
import {
  MoreHorizontal,
  PanelLeft,
  Pencil,
  Pin,
  PinOff,
  Search,
  Share,
  SquarePen,
  Trash2,
  type LucideIcon,
} from "lucide-react";
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
import { displayChatTitle } from "@/lib/i18n";
import { useLocale, useT } from "@/lib/use-i18n";
import { useCloudSync } from "@/lib/use-cloud-sync";

export function AppShell() {
  useGatewayHealth();
  useCloudSync();
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
  const [mobileSidebarOpen, setMobileSidebarOpen] = useState(false);
  const [mobileSidebarWidth, setMobileSidebarWidth] = useState(320);
  const [mobileSidebarOffset, setMobileSidebarOffset] = useState(0);
  const [mobileSidebarDragging, setMobileSidebarDragging] = useState(false);
  const mobileSidebarOffsetRef = useRef(0);
  const mobileSwipeStart = useRef<{
    x: number;
    y: number;
    offset: number;
    dragging: boolean;
    cancelled: boolean;
  } | null>(null);
  const t = useT();
  const settingsFromRoute = pathname === "/settings";
  const settingsVisible = settingsOpen || settingsFromRoute;

  function handleSettingsOpenChange(open: boolean) {
    setSettingsOpen(open);
    if (!open && settingsFromRoute) {
      void navigate({ to: "/" });
    }
  }

  useLayoutEffect(() => {
    const root = document.documentElement;
    root.dataset.theme = theme;
    root.dataset.font = fontSize;
    root.dataset.accent = accent;
    const themeColor = getComputedStyle(root)
      .getPropertyValue("--background")
      .trim();
    document
      .querySelector<HTMLMetaElement>('meta[name="theme-color"]')
      ?.setAttribute("content", themeColor);
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

  useEffect(() => {
    function updateMobileSidebarWidth() {
      if (window.matchMedia("(min-width: 768px)").matches) {
        setMobileSidebarOpen(false);
        setMobileSidebarOffset(0);
        mobileSidebarOffsetRef.current = 0;
        return;
      }
      setMobileSidebarWidth(
        Math.min(320, Math.round(window.innerWidth * 0.88)),
      );
    }
    updateMobileSidebarWidth();
    window.addEventListener("resize", updateMobileSidebarWidth);
    return () => window.removeEventListener("resize", updateMobileSidebarWidth);
  }, []);

  useEffect(() => {
    if (mobileSwipeStart.current?.dragging) return;
    const offset = mobileSidebarOpen ? mobileSidebarWidth : 0;
    setMobileSidebarOffset(offset);
    mobileSidebarOffsetRef.current = offset;
  }, [mobileSidebarOpen, mobileSidebarWidth]);

  const live = gatewayOn && gatewayStatus === "live";

  function startChat() {
    newChat();
    void navigate({ to: "/" });
  }

  function updateMobileSidebarOffset(offset: number) {
    const next = Math.max(0, Math.min(mobileSidebarWidth, offset));
    mobileSidebarOffsetRef.current = next;
    setMobileSidebarOffset(next);
  }

  function startMobileSidebarSwipe(event: React.PointerEvent<HTMLDivElement>) {
    if (
      !event.isPrimary ||
      event.button !== 0 ||
      window.matchMedia("(min-width: 768px)").matches
    ) {
      mobileSwipeStart.current = null;
      return;
    }
    mobileSwipeStart.current = {
      x: event.clientX,
      y: event.clientY,
      offset: mobileSidebarOffsetRef.current,
      dragging: false,
      cancelled: false,
    };
  }

  function moveMobileSidebarSwipe(event: React.PointerEvent<HTMLDivElement>) {
    const start = mobileSwipeStart.current;
    if (!start || !event.isPrimary || start.cancelled) return;
    const horizontal = event.clientX - start.x;
    const vertical = Math.abs(event.clientY - start.y);
    if (!start.dragging) {
      if (Math.abs(horizontal) < 8) return;
      if (Math.abs(horizontal) <= vertical * 1.15) {
        start.cancelled = true;
        return;
      }
      start.dragging = true;
      setMobileSidebarDragging(true);
      event.currentTarget.setPointerCapture(event.pointerId);
    }
    updateMobileSidebarOffset(start.offset + horizontal);
  }

  function finishMobileSidebarSwipe(event: React.PointerEvent<HTMLDivElement>) {
    const start = mobileSwipeStart.current;
    mobileSwipeStart.current = null;
    if (!start || !event.isPrimary || !start.dragging) {
      return;
    }
    settleMobileSidebar();
  }

  function settleMobileSidebar() {
    const open = mobileSidebarOffsetRef.current >= mobileSidebarWidth / 2;
    setMobileSidebarDragging(false);
    setMobileSidebarOpen(open);
    updateMobileSidebarOffset(open ? mobileSidebarWidth : 0);
  }

  return (
    <TooltipProvider delayDuration={200}>
      <div
        className="alice-app flex h-dvh touch-pan-y overflow-hidden bg-background"
        onPointerDownCapture={startMobileSidebarSwipe}
        onPointerMoveCapture={moveMobileSidebarSwipe}
        onPointerUpCapture={finishMobileSidebarSwipe}
        onPointerCancelCapture={() => {
          settleMobileSidebar();
          mobileSwipeStart.current = null;
        }}
      >
        <aside
          className={cn(
            "hidden h-full shrink-0 flex-col border-r border-border md:flex",
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
        <aside
          aria-label={t("shell.openSidebar")}
          aria-hidden={mobileSidebarOffset === 0}
          inert={mobileSidebarOffset === 0}
          className={cn(
            "fixed inset-y-0 left-0 z-30 flex bg-popover text-popover-foreground md:hidden",
            mobileSidebarOffset > 0 && "border-r border-border",
            mobileSidebarOffset === 0 && "pointer-events-none",
            mobileSidebarDragging
              ? "transition-none"
              : "transition-transform duration-300 ease-out",
          )}
          style={{
            width: mobileSidebarWidth,
            transform: `translateX(${mobileSidebarOffset - mobileSidebarWidth}px)`,
          }}
        >
          <ExpandedSidebar
            mobile
            pathname={pathname}
            live={live}
            conversations={conversations}
            activeId={activeId}
            onCollapse={() => setMobileSidebarOpen(false)}
            onSearch={() => {
              setMobileSidebarOpen(false);
              setSearchOpen(true);
            }}
            onNewChat={() => {
              setMobileSidebarOpen(false);
              startChat();
            }}
            onOpenSettings={() => {
              setMobileSidebarOpen(false);
              setSettingsOpen(true);
            }}
            onNavigate={() => setMobileSidebarOpen(false)}
            onSelectChat={(id) => {
              setMobileSidebarOpen(false);
              selectChat(id);
              void navigate({ to: "/" });
            }}
          />
        </aside>
        <button
          type="button"
          aria-label={
            mobileSidebarOpen ? t("shell.closeSidebar") : t("shell.openSidebar")
          }
          onClick={() => setMobileSidebarOpen((open) => !open)}
          className={cn(
            "fixed top-[max(1rem,env(safe-area-inset-top))] left-[max(1rem,env(safe-area-inset-left))] z-40 grid size-10 place-items-center rounded-full bg-card text-foreground shadow-border transition-colors hover:bg-accent md:hidden",
            mobileSidebarDragging
              ? "transition-none"
              : "transition-transform duration-300 ease-out",
          )}
          style={{ transform: `translateX(${mobileSidebarOffset}px)` }}
        >
          <svg
            viewBox="0 0 24 24"
            aria-hidden="true"
            className="size-5 fill-none stroke-current"
          >
            <path d="M4 8h16M4 16h10" strokeWidth="2" strokeLinecap="round" />
          </svg>
        </button>
        <button
          type="button"
          aria-label={t("shell.closeSidebar")}
          aria-hidden={mobileSidebarOffset === 0}
          tabIndex={mobileSidebarOffset === 0 ? -1 : 0}
          onClick={() => setMobileSidebarOpen(false)}
          className="fixed inset-0 z-20 bg-background/35 transition-opacity duration-300 md:hidden"
          style={{
            opacity: mobileSidebarWidth
              ? mobileSidebarOffset / mobileSidebarWidth
              : 0,
            pointerEvents: mobileSidebarOffset > 0 ? "auto" : "none",
          }}
        />
        <div
          className={cn(
            "alice-main relative z-10 flex min-w-0 flex-1 flex-col",
            mobileSidebarDragging
              ? "transition-none"
              : "transition-transform duration-300 ease-out",
          )}
          style={{ transform: `translateX(${mobileSidebarOffset}px)` }}
        >
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
        <SettingsDialog
          open={settingsVisible}
          onOpenChange={handleSettingsOpenChange}
        />
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
  const t = useT();
  const mark = accountMark(
    user?.displayName,
    user?.primaryEmail,
    t("shell.you"),
  );
  return (
    <div className="flex h-full w-full flex-col py-3">
      <div className="flex w-full justify-center">
        <IconBtn label={t("shell.openSidebar")} onClick={onExpand}>
          <span className="relative grid size-8 place-items-center">
            <Mark className="size-8 group-hover:hidden" />
            <span className="hidden group-hover:grid">
              <RailGlyph icon={PanelLeft} />
            </span>
          </span>
        </IconBtn>
      </div>
      <nav className="mt-5 flex w-full flex-col items-center gap-1">
        <IconBtn label={t("shell.newChat")} onClick={onNewChat}>
          <RailGlyph icon={SquarePen} heavy />
        </IconBtn>
        <IconBtn label={t("shell.search")} onClick={onSearch}>
          <RailGlyph icon={Search} heavy />
        </IconBtn>
        {NAV.map((item) => (
          <IconLink
            key={item.to}
            to={item.to}
            label={t(item.labelKey)}
            active={pathname === item.to}
          >
            <RailGlyph icon={item.icon} />
          </IconLink>
        ))}
      </nav>
      <div className="mt-auto flex w-full justify-center pb-2">
        <button
          type="button"
          aria-label={t("shell.settings")}
          onClick={onOpenSettings}
          className="relative grid size-7 place-items-center rounded-full bg-foreground p-0 text-xs font-medium text-background"
        >
          {mark}
          {live ? (
            <span
              className="absolute -right-px -bottom-px size-2 rounded-full bg-live ring-2 ring-background"
              title={t("shell.agentLive")}
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
  mobile = false,
  onNavigate,
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
  mobile?: boolean;
  onNavigate?: () => void;
  onSelectChat: (id: string) => void;
}) {
  const renameChat = useHermes((s) => s.renameChat);
  const pinChat = useHermes((s) => s.pinChat);
  const deleteChat = useHermes((s) => s.deleteChat);
  const [renameId, setRenameId] = useState<string | null>(null);
  const [renameValue, setRenameValue] = useState("");
  const [deleteId, setDeleteId] = useState<string | null>(null);
  const pinned = useMemo(
    () =>
      conversations
        .filter((c) => c.pinned)
        .sort((a, b) => b.updatedAt - a.updatedAt),
    [conversations],
  );
  const rest = useMemo(
    () =>
      conversations
        .filter((c) => !c.pinned)
        .sort((a, b) => b.updatedAt - a.updatedAt),
    [conversations],
  );
  const deleting = conversations.find((c) => c.id === deleteId);
  const user = useCurrentUser();
  const t = useT();
  const locale = useLocale();
  const mark = accountMark(
    user?.displayName,
    user?.primaryEmail,
    t("shell.you"),
  );

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
        onShare={() =>
          void shareChat(
            c,
            t("shell.shareText", { title: displayChatTitle(locale, c.title) }),
          )
        }
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
    <div className="flex h-full min-h-0 w-full flex-col">
      <div
        className={cn(
          "flex items-center gap-1 pl-[18px]",
          mobile
            ? "pb-3 pr-4 pt-[max(1rem,env(safe-area-inset-top))]"
            : "py-3 pr-3",
        )}
      >
        <Link to="/" className="flex min-w-0 items-center text-foreground">
          <Wordmark className="text-3xl" />
        </Link>
        <div className="ml-auto flex items-center">
          {mobile ? (
            <button
              type="button"
              aria-label={t("shell.search")}
              onClick={onSearch}
              className="grid size-10 place-items-center rounded-full bg-card text-foreground shadow-border hover:bg-accent"
            >
              <RailGlyph icon={Search} heavy />
            </button>
          ) : (
            <IconBtn label={t("shell.search")} onClick={onSearch}>
              <RailGlyph icon={Search} heavy />
            </IconBtn>
          )}
          {!mobile ? (
            <IconBtn label={t("shell.closeSidebar")} onClick={onCollapse}>
              <RailGlyph icon={PanelLeft} />
            </IconBtn>
          ) : null}
        </div>
      </div>
      <nav className="mt-3 flex flex-col gap-0.5 px-2">
        {NAV.map((item) => (
          <Link
            key={item.to}
            to={item.to}
            onClick={onNavigate}
            className={cn(
              "flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm",
              pathname === item.to
                ? "bg-accent text-foreground"
                : "text-foreground/90 hover:bg-accent hover:text-foreground",
            )}
          >
            <RailGlyph icon={item.icon} />
            {t(item.labelKey)}
          </Link>
        ))}
      </nav>
      <ScrollArea className="min-h-0 flex-1 px-2 py-1">
        {pinned.length > 0 ? (
          <>
            <p className="mt-8 px-2 pb-1 text-2xs font-medium text-muted-foreground">
              {t("shell.pinned")}
            </p>
            <ul className="flex flex-col gap-0.5">{pinned.map(row)}</ul>
          </>
        ) : null}
        <p
          className={cn(
            "px-2 pb-1 text-2xs font-medium text-muted-foreground",
            pinned.length > 0 ? "mt-5" : "mt-8",
          )}
        >
          {t("shell.chats")}
        </p>
        <ul className="flex flex-col gap-0.5">{rest.map(row)}</ul>
      </ScrollArea>
      <div className="mt-auto px-5 py-3">
        <div className="flex items-center justify-between">
          <button
            type="button"
            aria-label={t("shell.settings")}
            onClick={onOpenSettings}
            className="relative grid size-10 shrink-0 place-items-center rounded-full bg-foreground text-sm font-medium text-background"
          >
            {mark}
            {live ? (
              <span
                className="absolute right-0 bottom-0 size-2.5 rounded-full bg-live ring-2 ring-background"
                title={t("shell.agentLive")}
              />
            ) : null}
          </button>
          <button
            type="button"
            aria-label={t("shell.newChat")}
            onClick={onNewChat}
            className="grid size-10 place-items-center rounded-full bg-card text-foreground shadow-border hover:bg-accent"
          >
            <RailGlyph icon={SquarePen} heavy />
          </button>
        </div>
      </div>
      <Dialog
        open={Boolean(renameId)}
        onOpenChange={(open) => !open && setRenameId(null)}
      >
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>{t("shell.renameTitle")}</DialogTitle>
            <DialogDescription>{t("shell.renameHint")}</DialogDescription>
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
              {t("shell.cancel")}
            </button>
            <button
              type="button"
              className="rounded-lg bg-foreground px-3 py-2 text-sm text-background"
              onClick={saveRename}
            >
              {t("shell.save")}
            </button>
          </div>
        </DialogContent>
      </Dialog>
      <Dialog
        open={Boolean(deleteId)}
        onOpenChange={(open) => !open && setDeleteId(null)}
      >
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>{t("shell.deleteChat")}</DialogTitle>
            <DialogDescription>
              {t("shell.deleteChatHint", {
                title: displayChatTitle(locale, deleting?.title ?? ""),
              })}
            </DialogDescription>
          </DialogHeader>
          <div className="flex justify-end gap-2">
            <button
              type="button"
              className="rounded-lg px-3 py-2 text-sm text-muted-foreground hover:bg-accent hover:text-foreground"
              onClick={() => setDeleteId(null)}
            >
              {t("shell.cancel")}
            </button>
            <button
              type="button"
              className="rounded-lg bg-destructive px-3 py-2 text-sm text-white"
              onClick={() => {
                if (deleteId) deleteChat(deleteId);
                setDeleteId(null);
              }}
            >
              {t("shell.delete")}
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
  const t = useT();
  const locale = useLocale();
  return (
    <li className="group relative">
      <button
        type="button"
        onClick={onSelect}
        className={cn(
          "w-full truncate rounded-lg py-2 pr-8 pl-2.5 text-left text-sm group-hover:bg-accent",
          active
            ? "bg-accent text-foreground"
            : "text-muted-foreground hover:bg-accent hover:text-foreground",
        )}
      >
        {displayChatTitle(locale, chat.title)}
      </button>
      <DropdownMenu open={menuOpen} onOpenChange={setMenuOpen}>
        <DropdownMenuTrigger asChild>
          <button
            type="button"
            aria-label={t("shell.chatOptions")}
            className={cn(
              "absolute top-1/2 right-1 grid size-7 -translate-y-1/2 place-items-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground focus-visible:text-foreground focus-visible:outline-none",
              menuOpen
                ? "opacity-100"
                : "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100",
            )}
          >
            <MoreHorizontal className="size-4" />
          </button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="min-w-40">
          <DropdownMenuItem onSelect={onShare}>
            <Share className="size-4" />
            {t("shell.share")}
          </DropdownMenuItem>
          <DropdownMenuItem onSelect={onRename}>
            <Pencil className="size-4" />
            {t("shell.rename")}
          </DropdownMenuItem>
          <DropdownMenuItem onSelect={onPin}>
            {chat.pinned ? (
              <PinOff className="size-4" />
            ) : (
              <Pin className="size-4" />
            )}
            {chat.pinned ? t("shell.unpin") : t("shell.pin")}
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            onSelect={onDelete}
            className="text-destructive focus:bg-destructive/10 focus:text-destructive"
          >
            <Trash2 className="size-4" />
            {t("shell.delete")}
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </li>
  );
}

async function shareChat(chat: Conversation, text: string) {
  const url = window.location.origin + "/";
  const payload = { title: chat.title, text, url };
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

function accountMark(
  name?: string | null,
  email?: string | null,
  fallback = "You",
) {
  const src = (name || email || fallback).trim();
  return src.charAt(0).toUpperCase() || "Y";
}

function RailGlyph({
  icon: Icon,
  heavy = false,
}: {
  icon: LucideIcon;
  heavy?: boolean;
}) {
  return (
    <Icon
      size={16}
      strokeWidth={2}
      className={cn(
        "shrink-0 text-foreground/90",
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
            active
              ? "bg-accent text-foreground"
              : "text-foreground/80 hover:bg-accent hover:text-foreground",
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
  const t = useT();
  const locale = useLocale();
  const items = useMemo(() => NAV, []);
  return (
    <CommandDialog open={open} onOpenChange={onOpenChange}>
      <Command>
        <CommandInput placeholder={t("shell.searchAlice")} />
        <CommandList>
          <CommandEmpty>{t("shell.noMatch")}</CommandEmpty>
          <CommandGroup heading={t("shell.go")}>
            {items.map((item) => (
              <CommandItem
                key={item.to}
                onSelect={() => {
                  onOpenChange(false);
                  void navigate({ to: item.to });
                }}
              >
                <item.icon className="size-4" />
                {t(item.labelKey)}
              </CommandItem>
            ))}
            <CommandItem
              onSelect={() => {
                onOpenChange(false);
                onOpenSettings();
              }}
            >
              <SETTINGS_NAV.icon className="size-4" />
              {t(SETTINGS_NAV.labelKey)}
            </CommandItem>
          </CommandGroup>
          <CommandGroup heading={t("shell.chats")}>
            {conversations.map((c) => (
              <CommandItem
                key={c.id}
                onSelect={() => {
                  onOpenChange(false);
                  onPickChat(c.id);
                }}
              >
                {displayChatTitle(locale, c.title)}
              </CommandItem>
            ))}
          </CommandGroup>
        </CommandList>
      </Command>
    </CommandDialog>
  );
}
