let currentId: string | null = null;
let owner = false;

export function setCockpitIdentity(next: { id: string | null; owner: boolean }) {
  currentId = next.id;
  owner = next.owner;
}

export function cockpitUserId() {
  return currentId;
}

export function cockpitIsOwner() {
  return owner;
}

export const COCKPIT_STORE = "alice-cockpit-v1";
