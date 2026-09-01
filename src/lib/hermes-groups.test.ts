import { describe, expect, it } from "vitest";
import { roomLogFromRpc, roomsFromRpc } from "./hermes-groups";

describe("Hermes Pantheon group contracts", () => {
  it("normalizes durable rooms and members", () => {
    expect(
      roomsFromRpc({
        rooms: [
          {
            room_id: "room-1",
            name: "Research",
            members: [
              { member_id: "writer", profile: "writer", handle: "Writer" },
            ],
            latest_seq: 4,
            updated_at: 10,
            disbanded_at: null,
          },
        ],
      }),
    ).toEqual([
      expect.objectContaining({
        id: "room-1",
        latestSeq: 4,
        disbanded: false,
        members: [expect.objectContaining({ profile: "writer" })],
      }),
    ]);
  });

  it("projects user and member log events without trusting arbitrary fields", () => {
    expect(
      roomLogFromRpc({
        cursor: 2,
        latest_seq: 2,
        has_more: false,
        events: [
          {
            seq: 2,
            kind: "message.member",
            actor: { profile: "reviewer", display_name: "Reviewer" },
            payload: { text: "Ship it" },
          },
        ],
      }),
    ).toEqual({
      cursor: 2,
      hasMore: false,
      events: [
        expect.objectContaining({
          seq: 2,
          actor: "Reviewer",
          text: "Ship it",
        }),
      ],
    });
  });
});
