// @vitest-environment jsdom

import { cleanup, render } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Message } from "@/lib/types";
import {
  MESSAGE_VIRTUALIZATION_THRESHOLD,
  VirtualMessageList,
} from "./virtual-message-list";

class ResizeObserverStub {
  observe() {}
  disconnect() {}
}

const messages = (count: number): Message[] =>
  Array.from({ length: count }, (_, index) => ({
    id: `message-${index}`,
    role: index % 2 === 0 ? "user" : "assistant",
    content: `Message ${index}`,
    createdAt: index,
  }));

beforeEach(() => {
  vi.stubGlobal("ResizeObserver", ResizeObserverStub);
  vi.stubGlobal("requestAnimationFrame", () => 1);
  vi.stubGlobal("cancelAnimationFrame", () => undefined);
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe("VirtualMessageList", () => {
  it("keeps short conversations fully available to the DOM", () => {
    const short = messages(MESSAGE_VIRTUALIZATION_THRESHOLD);
    const view = render(
      <VirtualMessageList
        conversationId="short"
        messages={short}
        sending={false}
        firstIsUser
        label="Conversation"
        renderMessage={(message) => (
          <article key={message.id} data-message-id={message.id}>
            {message.content}
          </article>
        )}
      />,
    );
    expect(view.container.querySelectorAll("article")).toHaveLength(
      MESSAGE_VIRTUALIZATION_THRESHOLD,
    );
  });

  it("mounts only the final visible window of a large conversation", () => {
    const long = messages(10_000);
    const view = render(
      <VirtualMessageList
        conversationId="long"
        messages={long}
        sending={false}
        firstIsUser
        label="Conversation"
        renderMessage={(message) => (
          <article key={message.id} data-message-id={message.id}>
            {message.content}
          </article>
        )}
      />,
    );
    const rendered = view.container.querySelectorAll("article");
    expect(rendered.length).toBeLessThan(30);
    expect(
      view.container.querySelector('[data-message-id="message-9999"]'),
    ).not.toBeNull();
    expect(
      view.container.querySelector('[data-message-id="message-0"]'),
    ).toBeNull();
  });
});
