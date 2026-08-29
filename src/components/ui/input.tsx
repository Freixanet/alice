import * as React from "react";
import { cn } from "@/lib/utils";

const Input = React.forwardRef<HTMLInputElement, React.ComponentProps<"input">>(
  ({ className, type, ...props }, ref) => {
    return (
      <input
        type={type}
        className={cn(
          "flex h-10 w-full rounded-md bg-muted px-3 text-base text-foreground shadow-border transition-[box-shadow] duration-150 placeholder:text-muted-foreground/80 hover:shadow-border-hover focus-visible:outline-none focus-visible:shadow-border-hover disabled:cursor-not-allowed disabled:opacity-50 md:text-sm",
          className,
        )}
        ref={ref}
        {...props}
      />
    );
  },
);
Input.displayName = "Input";

const Textarea = React.forwardRef<
  HTMLTextAreaElement,
  React.ComponentProps<"textarea">
>(({ className, ...props }, ref) => {
  return (
    <textarea
      suppressHydrationWarning
      className={cn(
        "flex min-h-20 w-full resize-none rounded-md bg-transparent px-0 py-0 text-base text-foreground placeholder:text-muted-foreground/80 focus-visible:outline-none disabled:cursor-not-allowed disabled:opacity-50 md:text-sm",
        className,
      )}
      ref={ref}
      {...props}
    />
  );
});
Textarea.displayName = "Textarea";

export { Input, Textarea };
