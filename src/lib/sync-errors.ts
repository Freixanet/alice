/**
 * The key cannot read what is already in this account.
 *
 * Thrown before anything is written. A recovery phrase is well-formed long
 * before it is the *right* phrase, and a wrong one used to be accepted, saved
 * and switched on — then the client pushed this device's conversations into
 * the account before it ever tried to read what was there, leaving one
 * account holding records under two keys.
 *
 * It lives alone here, rather than beside the key-checking functions in
 * `sync-client`, because the always-running sync loop needs to recognise it
 * and nothing else in that module. Importing it from there put the whole
 * full-snapshot client — which only the settings panel calls, and only behind
 * a dynamic import — into the chunk every signed-in page loads first.
 */
export class SyncKeyMismatchError extends Error {
  constructor() {
    super("This recovery phrase does not open this account's conversations.");
    this.name = "SyncKeyMismatchError";
  }
}
