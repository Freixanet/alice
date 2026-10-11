# Alice: public release snapshot

> Checked 2026-10-11 at 21:06 UTC. **Snapshot, not live status.** Follow the
> linked sources before relying on these results; they can change independently.

| Layer                      | Evidence at the time of this snapshot                                                                                                                                                                                                                                                                                                                                                    |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Repository**             | [`main`](https://github.com/Freixanet/alice/commit/fac9697f30c545363fb4870e601ffa36ff639167) at `fac9697f30c545363fb4870e601ffa36ff639167` (PR #74 merged).                                                                                                                                                                                                                              |
| **Quality**                | [Run #38174136599](https://github.com/Freixanet/alice/actions/runs/38174136599) on that SHA: `verify` and `browser` passed; `ios` still running. **Overall result pending.**                                                                                                                                                                                                             |
| **Web deployment**         | GitHub reports an automatic **Production** deployment of the same SHA ([Vercel status](https://vercel.com/freixanets-projects/alice/HG49ovnPhMEXWoFLEFyBfb33GEHk)). The public [`/api/status`](https://alice-ten-phi.vercel.app/api/status) returned HTTP 200 with version `fac9697f30c5`. The existing release verifier also passed with the full SHA supplied as `ALICE_EXPECTED_SHA`. |
| **Personal installations** | **Not checked.** Git and web deployment evidence do not establish the version on any iPhone, Hermes plugin or locally running service.                                                                                                                                                                                                                                                   |

The web check establishes the **self-reported 12-character release fingerprint**,
not full artifact integrity or the behavior of authenticated features. A passing
CI run does not prove that a personal installation was updated.

To refresh the snapshot, verify the current `main` SHA, the Quality run for
**that exact SHA**, and the deployment's version separately. The read-only
commands and limits are in [release operations](release-operations.md); do not
publish private runtime inventories or credentials here.
