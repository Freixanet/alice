/** Build an object field only when the value is present. */
export function whenDefined<K extends PropertyKey, V>(
  key: K,
  value: V | undefined,
): { [P in K]?: V } {
  return value === undefined ? {} : ({ [key]: value } as { [P in K]: V });
}
