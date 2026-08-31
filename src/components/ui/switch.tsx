import * as React from "react";
import * as SwitchPrimitives from "@radix-ui/react-switch";
import { cn } from "@/lib/utils";

const Switch = React.forwardRef<
  React.ComponentRef<typeof SwitchPrimitives.Root>,
  React.ComponentPropsWithoutRef<typeof SwitchPrimitives.Root>
>(({ className, ...props }, ref) => (
  <SwitchPrimitives.Root
    className={cn(
      "group peer relative inline-flex size-11 shrink-0 cursor-pointer items-center rounded-full bg-transparent p-0.5 focus-visible:outline-none disabled:cursor-not-allowed disabled:opacity-40",
      className,
    )}
    {...props}
    ref={ref}
  >
    <span
      aria-hidden="true"
      className="pointer-events-none absolute inset-x-0 h-6 rounded-full bg-muted shadow-border transition-[background-color,box-shadow] duration-150 group-data-[state=checked]:bg-primary"
    />
    <SwitchPrimitives.Thumb
      className={cn(
        "alice-switch-thumb pointer-events-none relative z-10 block size-5 rounded-md bg-foreground transition-transform duration-150 ease-out-smooth data-[state=checked]:translate-x-5 data-[state=checked]:bg-primary-foreground",
      )}
    />
  </SwitchPrimitives.Root>
));
Switch.displayName = SwitchPrimitives.Root.displayName;

export { Switch };
