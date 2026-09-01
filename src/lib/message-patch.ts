import type { Message, MessagePatch } from "./types";

/** Apply a patch without persisting optional properties as explicit undefined. */
export function applyMessagePatch(
  message: Message,
  patch: MessagePatch,
): Message {
  const next = { ...message, ...patch } as Message;
  for (const key of Object.keys(patch) as Array<keyof Message>) {
    if (patch[key] === undefined) Reflect.deleteProperty(next, key);
  }
  return next;
}
