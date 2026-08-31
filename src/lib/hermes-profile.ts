export const HERMES_PROFILE_NAME_PATTERN = /^[a-z0-9][a-z0-9_-]{0,63}$/;

export function isHermesProfileName(value: string): boolean {
  return HERMES_PROFILE_NAME_PATTERN.test(value);
}
