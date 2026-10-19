# ADR-0004: Keychain update-then-add, never delete-then-add

## STATUS

Accepted

## CONTEXT

The Hermes key is the one asset worth protecting. Whoever holds it can act
as the person through their agent. It is stored in Keychain with
`WhenUnlockedThisDeviceOnly` accessibility. A naive implementation might
delete the old key and then add the new one — but if the add fails (locked
keychain, entitlement change, storage error), the person has lost their
credential.

## DECISION

`KeyStore.save` uses `SecItemUpdate` first. If the update succeeds, the old
key is replaced in place. If the item does not exist (`errSecItemNotFound`),
it falls back to `SecItemAdd`. Delete-then-add is never used.

## EVIDENCE

- `KeyStore.swift` — `save(_ key: String, account: String)`:
  `SecItemUpdate` first, then `SecItemAdd` on `errSecItemNotFound`
- Comment: "Delete-then-add is deliberately avoided: if an add ever fails,
  the previous working credential must still be there."
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — excluded from backups
  and iCloud Keychain

## ALTERNATIVES CONSIDERED

Delete-then-add is simpler but unsafe. The update-then-add pattern is a
standard Keychain best practice.

## WHY THIS APPROACH EXISTS

A failed add after a delete leaves the person with no credential and no
way to connect to Hermes. Update-then-add ensures the old credential
survives any failure of the new one.

## CONSEQUENCES

- The person's credential is never lost due to a write failure.
- `WhenUnlockedThisDeviceOnly` means the key does not survive a device
  restore (intentional: a stolen device's backup should not carry the key).
- Re-pairing is required after a device replacement.

## RISKS

- If the Keychain itself is corrupted (iOS-level issue), Alice cannot
  recover the key. This is an iOS limitation, not an Alice bug.

## WHEN TO REVISIT

If Alice adds biometric protection to the key (requiring Face ID on read),
the accessibility class would change. The update-then-add pattern should
be preserved.
