"""Safe ASR terminal-browser cleanup retry; all data and effects are fictional."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from alice_secure_runner.core import AliceRunner


class ReadOnlyBrowserFixture:
    def __init__(self, generation: str, *, transient_close_failure: bool = False):
        self.generation_id = generation
        self.transient_close_failure = transient_close_failure
        self.close_attempts = []

    def search(self, query, *, browser_session):
        return {"products": []}

    def release_session(self, job_id):
        self.close_attempts.append(job_id)
        if self.transient_close_failure:
            self.transient_close_failure = False
            raise TimeoutError("disposable fixture close ACK lost")


class TerminalBrowserReaperTests(unittest.TestCase):
    def test_failed_terminal_close_is_retried_without_restarting_checkout(self):
        with tempfile.TemporaryDirectory(prefix="r02-browser-cleanup-") as directory:
            db = Path(directory) / "ledger.sqlite3"
            browser = ReadOnlyBrowserFixture("same-child-generation", transient_close_failure=True)
            runner = AliceRunner(browser, approval_key=b"fixture-only-approval-" * 3, ledger_path=db)
            try:
                job = runner.new_job("tenant", "session", "fictional recipient")["job_id"]
                runner.propose(job, tenant="tenant", session="session",
                               proposal={"action": "search", "query": "keyboard", "epoch": 0})
                stopped = runner.propose(job, tenant="tenant", session="session",
                                         proposal={"action": "stop", "epoch": 1})
                self.assertFalse(stopped["browser_cleanup_verified"])
                self.assertEqual(browser.close_attempts, [job])
                result = runner.reap_terminal_browser_sessions()
                self.assertEqual(result, {"closed": 1, "pending_unverified": 0})
                self.assertEqual(browser.close_attempts, [job, job])
                self.assertEqual(runner.reap_terminal_browser_sessions(),
                                 {"closed": 0, "pending_unverified": 0})
            finally:
                runner.close()

            # A fresh process cannot claim it closed somebody else's Chromium.
            later = ReadOnlyBrowserFixture("different-generation")
            reopened = AliceRunner(later, approval_key=b"fixture-only-approval-" * 3,
                                   ledger_path=db)
            try:
                self.assertEqual(reopened.reap_terminal_browser_sessions(),
                                 {"closed": 0, "pending_unverified": 0})
                self.assertEqual(later.close_attempts, [])
            finally:
                reopened.close()

    def test_previous_generation_is_never_falsely_attested_as_closed(self):
        with tempfile.TemporaryDirectory(prefix="r02-browser-owner-") as directory:
            db = Path(directory) / "ledger.sqlite3"
            former = ReadOnlyBrowserFixture("former-generation", transient_close_failure=True)
            first = AliceRunner(former, approval_key=b"fixture-only-approval-" * 3, ledger_path=db)
            job = first.new_job("tenant", "session", "fake address")["job_id"]
            first.propose(job, tenant="tenant", session="session",
                          proposal={"action": "search", "query": "keyboard", "epoch": 0})
            stopped = first.propose(job, tenant="tenant", session="session",
                                    proposal={"action": "stop", "epoch": 1})
            self.assertFalse(stopped["browser_cleanup_verified"])
            first.close()

            replacement = ReadOnlyBrowserFixture("new-generation")
            second = AliceRunner(replacement, approval_key=b"fixture-only-approval-" * 3,
                                 ledger_path=db)
            try:
                self.assertEqual(second.reap_terminal_browser_sessions(),
                                 {"closed": 0, "pending_unverified": 1})
                self.assertEqual(replacement.close_attempts, [])
                self.assertTrue(second._AliceRunner__jobs[job].browser_opened)
                self.assertEqual(second._AliceRunner__jobs[job].browser_generation,
                                 "former-generation")
            finally:
                second.close()


if __name__ == "__main__":
    unittest.main()
