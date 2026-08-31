export type CommandEnvironment = Record<string, string | undefined>;

export declare function applyCommandDefaults(
  command: string,
  args: string[],
  env: CommandEnvironment,
): CommandEnvironment;
