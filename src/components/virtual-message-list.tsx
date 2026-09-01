import {
  useCallback,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import type { Message } from "@/lib/types";
import {
  buildVirtualLayout,
  selectVirtualWindow,
} from "@/lib/variable-virtual-list";
import { cn } from "@/lib/utils";

export const MESSAGE_VIRTUALIZATION_THRESHOLD = 60;
const OVERSCAN_PX = 640;

type Props = {
  conversationId: string;
  messages: Message[];
  sending: boolean;
  firstIsUser: boolean;
  label: string;
  renderMessage: (message: Message, index: number) => ReactNode;
};

export function VirtualMessageList({
  conversationId,
  messages,
  sending,
  firstIsUser,
  label,
  renderMessage,
}: Props) {
  const scrollerRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const measuredSizes = useRef(new Map<string, number>());
  const previousCount = useRef(messages.length);
  const stickToBottom = useRef(true);
  const frame = useRef<number | null>(null);
  const [measurementRevision, setMeasurementRevision] = useState(0);
  const [viewport, setViewport] = useState({ start: 0, size: 0 });
  const virtual = messages.length > MESSAGE_VIRTUALIZATION_THRESHOLD;

  const layout = useMemo(() => {
    void measurementRevision;
    return buildVirtualLayout(messages, measuredSizes.current, (message) =>
      message.role === "user" ? 96 : 176,
    );
  }, [measurementRevision, messages]);
  const visibleItems = useMemo(() => {
    if (!virtual) return layout.items;
    const initialSize = viewport.size || 1_000;
    const initialStart = viewport.size
      ? viewport.start
      : Math.max(0, layout.totalSize - initialSize);
    return selectVirtualWindow(layout, initialStart, initialSize, OVERSCAN_PX);
  }, [layout, viewport, virtual]);
  const last = messages.at(-1);
  const contentRevision = `${last?.id ?? ""}:${last?.content.length ?? 0}:${last?.pending ? 1 : 0}:${last?.tools?.length ?? 0}:${last?.approval ? 1 : 0}`;

  const readViewport = useCallback(() => {
    const scroller = scrollerRef.current;
    if (!scroller) return;
    const listStart = virtual ? (listRef.current?.offsetTop ?? 0) : 0;
    const next = {
      start: Math.max(0, scroller.scrollTop - listStart),
      size: scroller.clientHeight,
    };
    setViewport((current) =>
      Math.abs(current.start - next.start) < 1 &&
      Math.abs(current.size - next.size) < 1
        ? current
        : next,
    );
    stickToBottom.current =
      scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 160;
  }, [virtual]);

  const scheduleViewportRead = useCallback(() => {
    if (frame.current !== null) return;
    frame.current = requestAnimationFrame(() => {
      frame.current = null;
      readViewport();
    });
  }, [readViewport]);

  const handleScroll = useCallback(() => {
    const scroller = scrollerRef.current;
    if (scroller) {
      stickToBottom.current =
        scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight <
        160;
    }
    scheduleViewportRead();
  }, [scheduleViewportRead]);

  useLayoutEffect(() => {
    const scroller = scrollerRef.current;
    if (!scroller) return;
    const observer = new ResizeObserver(scheduleViewportRead);
    observer.observe(scroller);
    readViewport();
    return () => {
      observer.disconnect();
      if (frame.current !== null) cancelAnimationFrame(frame.current);
      frame.current = null;
    };
  }, [readViewport, scheduleViewportRead]);

  useLayoutEffect(() => {
    measuredSizes.current.clear();
    setMeasurementRevision((revision) => revision + 1);
    stickToBottom.current = true;
    previousCount.current = 0;
  }, [conversationId]);

  useLayoutEffect(() => {
    const scroller = scrollerRef.current;
    if (!scroller) return;
    const addedMessage = messages.length > previousCount.current;
    previousCount.current = messages.length;
    if (addedMessage || stickToBottom.current) {
      scroller.scrollTop = scroller.scrollHeight;
      scheduleViewportRead();
    }
  }, [
    contentRevision,
    layout.totalSize,
    messages.length,
    scheduleViewportRead,
    sending,
  ]);

  const recordSize = useCallback(
    (id: string, size: number) => {
      if (!Number.isFinite(size) || size <= 0) return;
      const row = layout.items.find((item) => item.id === id);
      const previous = measuredSizes.current.get(id) ?? row?.size;
      if (previous !== undefined && Math.abs(previous - size) < 0.5) return;
      measuredSizes.current.set(id, size);
      if (row && row.start < viewport.start && previous !== undefined) {
        const scroller = scrollerRef.current;
        if (scroller) scroller.scrollTop += size - previous;
      }
      setMeasurementRevision((revision) => revision + 1);
    },
    [layout.items, viewport.start],
  );

  return (
    <div
      ref={scrollerRef}
      onScroll={handleScroll}
      className="alice-chat-scroller min-h-0 flex-1 overflow-y-auto"
    >
      {virtual ? (
        <div
          role="log"
          aria-label={label}
          aria-live="polite"
          aria-relevant="additions text"
          className="alice-message-list mx-auto w-full max-w-[45rem] px-4 sm:px-6"
        >
          <div className={firstIsUser ? "h-[10vh]" : "h-8"} />
          <div
            ref={listRef}
            className="relative w-full"
            style={{ height: layout.totalSize }}
          >
            {visibleItems.map((item) => {
              const message = messages[item.index];
              if (!message) return null;
              return (
                <MeasuredMessage
                  key={message.id}
                  id={message.id}
                  start={item.start}
                  onSize={recordSize}
                >
                  {renderMessage(message, item.index)}
                </MeasuredMessage>
              );
            })}
          </div>
          <div className="h-28" />
        </div>
      ) : (
        <div
          role="log"
          aria-label={label}
          aria-live="polite"
          aria-relevant="additions text"
          className={cn(
            "alice-message-list mx-auto flex w-full max-w-[45rem] flex-col gap-6 px-4 pb-28 sm:px-6",
            firstIsUser ? "pt-[10vh]" : "pt-8",
          )}
        >
          {messages.map(renderMessage)}
        </div>
      )}
    </div>
  );
}

function MeasuredMessage({
  id,
  start,
  onSize,
  children,
}: {
  id: string;
  start: number;
  onSize: (id: string, size: number) => void;
  children: ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const element = ref.current;
    if (!element) return;
    const measure = () => onSize(id, element.getBoundingClientRect().height);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, [id, onSize]);
  return (
    <div
      ref={ref}
      className="absolute inset-x-0 pb-6"
      style={{ transform: `translateY(${start}px)` }}
    >
      {children}
    </div>
  );
}
