import { cn } from "@/lib/utils";

export function Mark({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 32 32"
      fill="none"
      className={cn("size-5 overflow-visible", className)}
      aria-hidden
    >
      <path fill="currentColor" d="M15.1 7.4 7.6 5.1 9.4 10.8Z" />
      <path fill="currentColor" d="M16.9 7.4 24.4 5.1 22.6 10.8Z" />
      <path
        fill="none"
        stroke="currentColor"
        strokeWidth="2.2"
        strokeLinecap="round"
        d="M16 11.2c-5.5 1.5-5.5 8.5 0 10"
      />
      <path
        fill="none"
        stroke="currentColor"
        strokeWidth="2.2"
        strokeLinecap="round"
        d="M16 11.2c5.5 1.5 5.5 8.5 0 10"
      />
      <rect x="15" y="7.2" width="2" height="18.4" rx="1" fill="currentColor" />
    </svg>
  );
}

export function Wordmark({ className }: { className?: string }) {
  return (
    <span className={cn("font-serif text-xl tracking-tight", className)}>
      Alice
    </span>
  );
}
