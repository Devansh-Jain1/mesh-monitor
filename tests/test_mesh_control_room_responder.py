"""Synthetic, isolated, silent fixtures. Never invokes SSH or production state."""
import copy
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import subprocess
import sys
import time
import unittest
import uuid

SOURCE = Path(__file__).resolve().parents[1] / "ops/mesh_monitor_control_room_responder.py"
spec = importlib.util.spec_from_file_location("mesh_responder", SOURCE)
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class ResponderFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mesh-responder-fixture-", dir="/private/tmp")
        self.base = Path(self.temp.name)
        os.chmod(self.base, 0o700)
        self.store = r.Store(self.base)
        for folder in ("requests", "replies", "cancellations", "ledger", "prepared"):
            with self.store.sub(folder, create=True):
                pass
        self.now = datetime(2026, 9, 19, 18, 0, tzinfo=timezone.utc).timestamp()
        self.created = self.now - 300  # A five-minute scheduled delay is valid.
        self.session_id, self.generation, self.request_id, self.runner = [str(uuid.uuid4()) for _ in range(4)]
        self.event = "raspberrypi-" + str(uuid.uuid4())
        self.epoch = "4242:Sat Sep 19 08:00:00 2026"
        self.proof = dict(authenticated=True, physical_pi=True, peer_ip="100.64.0.10", pi="raspberrypi",
                          detected_at=self.created - 1, sent_at=self.created - .5, previous_mode="dark", monitor_session_id=self.session_id)
        self.session = dict(schema="mesh.control-room.session.v1", source="MeshMonitor", targetThreadID=r.TARGET,
                            physicalSessionID=self.session_id, eventID=self.event, active=True, createdAt=r.stamp(self.created),
                            updatedAt=r.stamp(self.now), expiresAt=r.stamp(self.now + 3600), proof=self.proof,
                            sourceEpoch=self.epoch, generation=self.generation, livenessAt=r.stamp(self.now))
        self.request = dict(schema="mesh.control-room.request.v1", source="MeshMonitor", targetThreadID=r.TARGET,
                            requestID=self.request_id, physicalSessionID=self.session_id, eventID=self.event,
                            originalMessage="  Explain this exact thing.\n", originalMessageSHA256=r.digest(b"  Explain this exact thing.\n"),
                            createdAt=r.stamp(self.now - 2), expiresAt=r.stamp(self.now + 700), proof=self.proof,
                            context={"currentTask": "Synthetic task"}, images=[], sourceEpoch=self.epoch, sessionGeneration=self.generation)
        self.remote = dict(schema_version=2, source_epoch=self.epoch, sampled_at=self.now, mode="desktop", active=True,
                           reason="button_receipt", ts=self.created,
                           arm=dict(schema_version=1, armed=True, session_id=self.session_id, intended_date="2026-09-19", time_zone="America/New_York",
                                    created_at=self.created - 10, expires_at=self.now + 3600, pi_name="raspberrypi", pi_addresses=["100.64.0.10"]),
                           receipts=[dict(event_id=self.event, requested_action="toggle", target_mode="desktop", status="final", changed=True,
                                          result=dict(ok=True, event_id=self.event, mode="desktop", active=True, changed=True, return_origin=self.proof))])
        self.calls = 0
        self.responder = r.Responder(self.store, "raspberrypi", {"100.64.0.10"}, self.remote_read, lambda: self.now)
        self.put_session()
        self.put_request()

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def remote_read(self):
        self.calls += 1
        return copy.deepcopy(self.remote)

    def put_session(self):
        r.publish_at(self.store.fd, "session.json", r.encode(self.session), replace=True)

    def put_request(self):
        self.store.write("requests", self.request_id + ".json", self.request, replace=True)

    def claim(self):
        result = self.responder.claim_one(self.runner)
        self.assertTrue(result["claimed"], result)
        return result

    def publish(self, claim, text="Synthetic reply"):
        return self.responder.publish(self.request_id, claim["claimToken"], self.runner, text=text)

    def ledger(self):
        return r.decode(self.store.read("ledger", self.request_id + ".json"))

    def cancel(self):
        marker = dict(schema="mesh.control-room.cancel.v1", source="MeshMonitor", **{key: self.request[key] for key in r.TUPLE},
                      createdAt=r.stamp(self.now), reason="fixture_pause")
        self.store.write("cancellations", self.request_id + ".json", marker)

    def test_preserves_exact_text_after_durable_processing_claim(self):
        claim = self.claim()
        self.assertEqual(claim["request"]["originalMessage"], "  Explain this exact thing.\n")
        self.assertEqual(self.ledger()["state"], "processing")
        self.assertEqual(claim["envelopeSHA256"], r.digest(self.store.read("requests", self.request_id + ".json")))
        self.assertGreaterEqual(self.calls, 2)
        self.assertEqual(len(claim["claimToken"]), 64)

    def test_processing_never_reclaimed_by_same_or_different_runner(self):
        self.claim()
        self.assertFalse(self.responder.claim_one(self.runner)["claimed"])
        self.assertFalse(self.responder.claim_one(str(uuid.uuid4()))["claimed"])

    def test_publication_exact_correlation_and_once(self):
        claim = self.claim()
        published = self.publish(claim)
        raw = self.store.read("replies", self.request_id + ".json")
        reply = r.decode(raw)
        self.assertEqual(reply["text"], "Synthetic reply")
        for key in r.TUPLE:
            self.assertEqual(reply[key], self.request[key])
        self.assertEqual(published["replySHA256"], r.digest(raw))
        again = self.responder.publish(self.request_id, claim["claimToken"], self.runner, recover=True)
        self.assertEqual(again["replySHA256"], published["replySHA256"])
        self.assertEqual(raw, self.store.read("replies", self.request_id + ".json"))

    def test_wrong_token_or_runner_cannot_publish(self):
        claim = self.claim()
        for token, runner in [("wrong", self.runner), (claim["claimToken"], str(uuid.uuid4()))]:
            with self.assertRaises(r.Refused):
                self.responder.publish(self.request_id, token, runner, text="NO")
        self.assertEqual(self.ledger()["state"], "processing")

    def test_original_hash_and_entire_envelope_hash_are_both_checked(self):
        claim = self.claim()
        self.request["context"]["currentTask"] = "Changed after claim"
        self.put_request()
        with self.assertRaisesRegex(r.Refused, "request_envelope_changed"):
            self.publish(claim)
        self.assertEqual(self.ledger()["state"], "rejected")

    def test_cancel_prevents_reply_and_records_terminal(self):
        claim = self.claim()
        self.cancel()
        with self.assertRaisesRegex(r.Refused, "request_cancelled"):
            self.publish(claim)
        self.assertEqual(self.ledger()["state"], "cancelled")
        self.assertIsNone(self.store.read("replies", self.request_id + ".json", optional=True))

    def test_pause_new_session_and_generation_invalidate_claim(self):
        claim = self.claim()
        self.session["generation"] = str(uuid.uuid4())
        self.put_session()
        with self.assertRaisesRegex(r.Refused, "session_generation_changed"):
            self.publish(claim)
        self.assertEqual(self.ledger()["state"], "cancelled")

    def test_rechecks_cancellation_after_remote_delay(self):
        claim = self.claim()
        def remote_cancel():
            self.cancel()
            return copy.deepcopy(self.remote)
        self.responder.remote = remote_cancel
        with self.assertRaisesRegex(r.Refused, "cancelled_during_verification"):
            self.publish(claim)
        self.assertIsNone(self.store.read("replies", self.request_id + ".json", optional=True))

    def test_crash_after_claim_before_processing_does_not_release_again(self):
        original = self.store.write
        def fail_processing(folder, name, value, replace=False):
            if folder == "ledger" and isinstance(value, dict) and value.get("state") == "processing":
                raise OSError("synthetic crash")
            return original(folder, name, value, replace)
        self.store.write = fail_processing
        with self.assertRaises(OSError):
            self.responder.claim_one(self.runner)
        self.store.write = original
        self.assertEqual(self.ledger()["state"], "claimed")
        self.assertFalse(self.responder.claim_one(self.runner)["claimed"])

    def test_crash_after_prepared_bytes_recovers_identical_reply_only(self):
        claim = self.claim()
        original = self.store.write
        def fail_prepared_state(folder, name, value, replace=False):
            if folder == "ledger" and isinstance(value, dict) and value.get("state") == "reply_prepared":
                raise OSError("synthetic crash")
            return original(folder, name, value, replace)
        self.store.write = fail_prepared_state
        with self.assertRaises(OSError):
            self.publish(claim)
        self.store.write = original
        prepared = self.store.read("prepared", self.request_id + ".json")
        self.assertEqual(self.ledger()["state"], "processing")
        self.responder.publish(self.request_id, claim["claimToken"], self.runner, recover=True)
        self.assertEqual(prepared, self.store.read("replies", self.request_id + ".json"))

    def test_conflicting_existing_reply_terminal_uncertain(self):
        claim = self.claim()
        self.store.write("replies", self.request_id + ".json", {"text": "conflict"})
        with self.assertRaisesRegex(r.Refused, "conflicting_reply_exists"):
            self.publish(claim)
        self.assertEqual(self.ledger()["state"], "uncertain")
        self.assertEqual(r.decode(self.store.read("replies", self.request_id + ".json"))["text"], "conflict")

    def test_operator_can_close_uncertain_without_reply(self):
        claim = self.claim()
        self.responder.finish_without_reply(self.request_id, claim["claimToken"], self.runner, "uncertain")
        self.assertEqual(self.ledger()["state"], "uncertain")
        self.assertFalse(self.responder.claim_one(self.runner)["claimed"])

    def test_mutations_rejected_without_releasing_original_text(self):
        original_request, original_session, original_remote = copy.deepcopy((self.request, self.session, self.remote))
        mutations = [
            lambda: self.request.update(originalMessageSHA256="0" * 64),
            lambda: self.request.update(targetThreadID=str(uuid.uuid4())),
            lambda: self.request.update(images=[{"data": "not allowed"}]),
            lambda: self.request["context"].update(privateObservation="not allowed"),
            lambda: self.request.update(expiresAt=r.stamp(self.now - 1)),
            lambda: self.session.update(active=False),
            lambda: self.session.update(livenessAt=r.stamp(self.now - 13)),
            lambda: self.session.update(sourceEpoch="new receiver"),
            lambda: self.remote.update(source_epoch="new receiver"),
            lambda: self.remote.update(sampled_at=self.now - 11),
            lambda: self.remote.update(mode="dark", active=False),
            lambda: self.remote.update(reason="button_pending"),
            lambda: self.remote["arm"].update(armed=False),
            lambda: self.remote["arm"].update(intended_date="2026-09-18"),
            lambda: self.remote["arm"].update(pi_addresses=["127.0.0.1"]),
            lambda: self.remote["receipts"][0]["result"].update(ok=False),
            lambda: self.remote["receipts"].append(dict(status="final", changed=True, event_id="later")),
            lambda: self.session.update(createdAt=r.stamp(self.created + 60)),
        ]
        for mutate in mutations:
            (self.base / "ledger" / (self.request_id + ".json")).unlink(missing_ok=True)
            self.request, self.session, self.remote = copy.deepcopy((original_request, original_session, original_remote))
            mutate()
            self.put_request()
            self.put_session()
            result = self.responder.claim_one(self.runner)
            self.assertFalse(result["claimed"], mutate)
            self.assertNotIn("originalMessage", json.dumps(result))

    def test_missing_new_epoch_generation_liveness_fields_fail_closed(self):
        for field in ("sourceEpoch", "sessionGeneration"):
            (self.base / "ledger" / (self.request_id + ".json")).unlink(missing_ok=True)
            saved = self.request.pop(field)
            self.put_request()
            self.assertFalse(self.responder.claim_one(self.runner)["claimed"])
            self.request[field] = saved
        self.put_request()
        (self.base / "ledger" / (self.request_id + ".json")).unlink(missing_ok=True)
        self.session.pop("livenessAt")
        self.put_session()
        self.assertFalse(self.responder.claim_one(self.runner)["claimed"])

    def test_malformed_duplicate_json_rejected(self):
        self.store.write("requests", self.request_id + ".json", b'{"schema":1,"schema":2}', replace=True)
        self.assertFalse(self.responder.claim_one(self.runner)["claimed"])

    def test_single_link_private_permissions_and_symlinks(self):
        path = self.base / "requests" / (self.request_id + ".json")
        for mode in (0o644, 0o400):
            os.chmod(path, mode)
            with self.assertRaises(r.Refused):
                self.responder.claim_one(self.runner)
        os.chmod(path, 0o600)
        alias = path.with_name("alias")
        os.link(path, alias)
        with self.assertRaises(r.Refused):
            self.responder.claim_one(self.runner)
        alias.unlink()
        raw = path.read_bytes()
        path.unlink()
        target = self.base / "target"
        target.write_bytes(raw)
        os.chmod(target, 0o600)
        path.symlink_to(target)
        with self.assertRaises(OSError):
            self.responder.claim_one(self.runner)

    def test_parent_symlink_refused(self):
        link = self.base / "link"
        link.symlink_to(self.base / "requests")
        with self.assertRaises(OSError):
            r.directory(link)

    def test_oversize_request_and_scan_bound(self):
        self.store.write("requests", self.request_id + ".json", b"x" * r.MAX_JSON, replace=True)
        path = self.base / "requests" / (self.request_id + ".json")
        with path.open("ab") as stream:
            stream.write(b"x")
        with self.assertRaises(r.Refused):
            self.responder.claim_one(self.runner)
        path.unlink()
        self.put_request()
        for _ in range(270):
            old_id = str(uuid.uuid4())
            self.store.write("requests", old_id + ".json", {"synthetic": "historical"})
            self.store.write("ledger", old_id + ".json", {"state": "replied"})
        self.assertTrue(self.responder.claim_one(self.runner)["claimed"])

    def test_expired_and_cancelled_unclaimed_backlog_does_not_starve_valid_request(self):
        for index in range(270):
            old = copy.deepcopy(self.request)
            old_id = str(uuid.uuid4())
            old["requestID"] = old_id
            if index % 2:
                old.update(createdAt=r.stamp(self.now - 800), expiresAt=r.stamp(self.now - 100))
            else:
                marker = dict(schema="mesh.control-room.cancel.v1", source="MeshMonitor", **{key: old[key] for key in r.TUPLE})
                self.store.write("cancellations", old_id + ".json", marker)
            self.store.write("requests", old_id + ".json", old)
        # Sorting all entries with current ID last creates deterministic pressure.
        original_scandir = os.scandir
        class Entries:
            def __enter__(inner):
                with original_scandir(self.base / "requests") as entries:
                    return iter(sorted(entries, key=lambda item: item.name == self.request_id + ".json"))
            def __exit__(inner, *_):
                pass
        os.scandir = lambda _: Entries()
        try:
            result = self.responder.claim_one(self.runner)
        finally:
            os.scandir = original_scandir
        self.assertTrue(result["claimed"])
        self.assertEqual(result["requestID"], self.request_id)
        self.assertEqual(self.calls, 2)  # Stale backlog causes no SSH projections.

    def test_invocation_budget_stops_preprocessing_before_unbounded_tombstones(self):
        for _ in range(10):
            old_id = str(uuid.uuid4())
            self.store.write("requests", old_id + ".json", {"malformed": True})
        original_scandir, original_monotonic = os.scandir, time.monotonic
        class Entries:
            def __enter__(inner):
                with original_scandir(self.base / "requests") as entries:
                    return iter(sorted(entries, key=lambda item: item.name == self.request_id + ".json"))
            def __exit__(inner, *_):
                pass
        ticks = iter([0, 0, 21])  # Deadline20 starts BEFORE the first entry.
        os.scandir = lambda _: Entries()
        time.monotonic = lambda: next(ticks, 21)
        try:
            result = self.responder.claim_one(self.runner)
        finally:
            os.scandir, time.monotonic = original_scandir, original_monotonic
        self.assertFalse(result["claimed"])
        self.assertTrue(result["scanBudgetExhausted"])
        self.assertEqual(self.calls, 0)
        self.assertEqual(len(list((self.base / "ledger").glob("*.json"))), 1)
        self.assertIsNone(self.store.read("ledger", self.request_id + ".json", optional=True))

    def test_budget_expiring_during_first_verification_does_not_start_second_ssh(self):
        original_monotonic = time.monotonic
        tick = [0]
        def remote_budget():
            self.calls += 1
            tick[0] = 21
            return copy.deepcopy(self.remote)
        self.responder.remote = remote_budget
        time.monotonic = lambda: tick[0]
        try:
            result = self.responder.claim_one(self.runner)
        finally:
            time.monotonic = original_monotonic
        self.assertFalse(result["claimed"])
        self.assertTrue(result["scanBudgetExhausted"])
        self.assertEqual(self.calls, 1)
        self.assertIsNone(self.store.read("ledger", self.request_id + ".json", optional=True))

    def test_pause_between_preparation_and_final_gate_suppresses_publication(self):
        claim = self.claim()
        original = self.store.write
        def pause_after_prepare(folder, name, value, replace=False):
            result = original(folder, name, value, replace)
            if folder == "prepared":
                self.session["active"] = False
                self.put_session()
            return result
        self.store.write = pause_after_prepare
        with self.assertRaisesRegex(r.Refused, "inactive_session"):
            self.publish(claim)
        self.assertEqual(self.ledger()["state"], "cancelled")
        self.assertIsNone(self.store.read("replies", self.request_id + ".json", optional=True))

    def test_crash_after_reply_publication_only_republishes_identical_bytes(self):
        claim = self.claim()
        original = self.store.write
        def crash_after_reply(folder, name, value, replace=False):
            result = original(folder, name, value, replace)
            if folder == "replies":
                raise OSError("synthetic post-publication crash")
            return result
        self.store.write = crash_after_reply
        with self.assertRaises(OSError):
            self.publish(claim)
        self.store.write = original
        old = self.store.read("replies", self.request_id + ".json")
        self.assertEqual(self.ledger()["state"], "reply_prepared")
        self.session["active"] = False
        self.put_session()
        self.now += 701  # Paused AND expired after bytes had already published.
        remote_calls = self.calls
        result = self.responder.publish(self.request_id, claim["claimToken"], self.runner, recover=True)
        self.assertTrue(result["alreadyPublished"])
        self.assertEqual(self.calls, remote_calls)
        self.assertEqual(old, self.store.read("replies", self.request_id + ".json"))
        self.assertEqual(self.ledger()["state"], "replied")

    def test_finish_after_publication_crash_reconciles_before_abort_while_paused_expired(self):
        claim = self.claim()
        original = self.store.write
        def crash_after_reply(folder, name, value, replace=False):
            result = original(folder, name, value, replace)
            if folder == "replies":
                raise OSError("synthetic post-publication crash")
            return result
        self.store.write = crash_after_reply
        with self.assertRaises(OSError):
            self.publish(claim)
        self.store.write = original
        published = self.store.read("replies", self.request_id + ".json")
        self.session["active"] = False
        self.put_session()
        self.now += 701
        remote_calls = self.calls
        for reason in ("cancelled", "expired", "uncertain", "rejected"):
            result = self.responder.finish_without_reply(self.request_id, claim["claimToken"], self.runner, reason)
            self.assertEqual(result["state"], "replied")
            self.assertTrue(result["alreadyPublished"])
            self.assertEqual(self.ledger()["state"], "replied")
            self.assertEqual(published, self.store.read("replies", self.request_id + ".json"))
        self.assertEqual(self.calls, remote_calls)

    def test_terminal_replied_never_republishes_or_changes_after_history_damage(self):
        claim = self.claim()
        self.publish(claim)
        ledger_before = self.store.read("ledger", self.request_id + ".json")
        reply_path = self.base / "replies" / (self.request_id + ".json")
        prepared_path = self.base / "prepared" / (self.request_id + ".json")
        reply_before, prepared_before = reply_path.read_bytes(), prepared_path.read_bytes()
        write_original = self.store.write
        writes = []
        def observe_write(folder, name, value, replace=False):
            writes.append(folder)
            return write_original(folder, name, value, replace)
        self.store.write = observe_write
        damages = ("reply_missing", "reply_corrupt", "reply_conflicting", "prepared_missing", "prepared_corrupt")
        for damage in damages:
            reply_path.write_bytes(reply_before)
            prepared_path.write_bytes(prepared_before)
            os.chmod(reply_path, 0o600)
            os.chmod(prepared_path, 0o600)
            if damage == "reply_missing":
                reply_path.unlink()
            elif damage == "reply_corrupt":
                reply_path.write_bytes(b"{malformed")
            elif damage == "reply_conflicting":
                altered = r.decode(reply_before)
                altered["text"] = "Different bytes"
                reply_path.write_bytes(r.encode(altered))
            elif damage == "prepared_missing":
                prepared_path.unlink()
            else:
                prepared_path.write_bytes(b"corrupt")
            calls_before = self.calls
            for action in (
                lambda: self.responder.publish(self.request_id, claim["claimToken"], self.runner, recover=True),
                lambda: self.responder.finish_without_reply(self.request_id, claim["claimToken"], self.runner, "uncertain"),
            ):
                with self.assertRaisesRegex(r.Refused, "terminal_replied_history_"):
                    action()
                self.assertEqual(self.store.read("ledger", self.request_id + ".json"), ledger_before)
            self.assertEqual(self.calls, calls_before)
        self.assertEqual(writes, [])
        self.store.write = write_original

    def test_real_multiprocess_claim_contention_releases_message_only_once(self):
        projection = self.base / "synthetic-projection.json"
        projection.write_bytes(r.encode(self.remote))
        os.chmod(projection, 0o600)
        worker = r"""
import importlib.util,json,sys,time,os
from pathlib import Path
spec=importlib.util.spec_from_file_location("helper",sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
base=Path(sys.argv[2]);store=m.Store(base);projection=json.loads((base/"synthetic-projection.json").read_bytes())
def remote():
 if sys.argv[5]=="hold":
  (base/"entered").touch(mode=0o600)
  deadline=time.monotonic()+5
  while not (base/"release").exists():
   if time.monotonic()>deadline:raise RuntimeError("fixture release timeout")
   time.sleep(.01)
 return projection
try:
 responder=m.Responder(store,"raspberrypi",{"100.64.0.10"},remote,lambda:float(sys.argv[3]))
 try:print(json.dumps(responder.claim_one(sys.argv[4])))
 except m.Refused as e:print(json.dumps({"refused":e.reason}))
finally:store.close()
"""
        winner = subprocess.Popen([sys.executable, "-c", worker, str(SOURCE), str(self.base), str(self.now), self.runner, "hold"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while not (self.base / "entered").exists():
                self.assertIsNone(winner.poll())
                self.assertLess(time.monotonic(), deadline)
                time.sleep(.01)
            contender = subprocess.run([sys.executable, "-c", worker, str(SOURCE), str(self.base), str(self.now), str(uuid.uuid4()), "pass"], capture_output=True, text=True, timeout=5)
            self.assertEqual(contender.returncode, 0, contender.stderr)
            self.assertEqual(json.loads(contender.stdout), {"refused": "responder_busy"})
            (self.base / "release").touch(mode=0o600)
            stdout, stderr = winner.communicate(timeout=5)
            self.assertEqual(winner.returncode, 0, stderr)
            self.assertTrue(json.loads(stdout)["claimed"])
            self.assertEqual(self.ledger()["state"], "processing")
            self.assertFalse(self.responder.claim_one(str(uuid.uuid4()))["claimed"])
        finally:
            if winner.poll() is None:
                winner.kill()
            winner.communicate()

    def test_fsync_failure_before_claim_rename_releases_no_text(self):
        fsync_original = os.fsync
        def fail_sync(_):
            raise OSError("synthetic fsync failure")
        os.fsync = fail_sync
        try:
            with self.assertRaises(OSError):
                self.responder.claim_one(self.runner)
        finally:
            os.fsync = fsync_original
        self.assertIsNone(self.store.read("ledger", self.request_id + ".json", optional=True))
        self.assertIsNone(self.store.read("replies", self.request_id + ".json", optional=True))
        self.assertTrue(self.responder.claim_one(self.runner)["claimed"])

    def test_directory_fsync_failure_after_claim_rename_never_reclaims(self):
        original_write = self.store.write
        original_sync = os.fsync
        def write_with_failed_directory_sync(folder, name, value, replace=False):
            if folder != "ledger" or not isinstance(value, dict) or value.get("state") != "claimed":
                return original_write(folder, name, value, replace)
            count = 0
            def fail_second(fd):
                nonlocal count
                count += 1
                if count == 2:
                    raise OSError("synthetic directory fsync failure")
                return original_sync(fd)
            os.fsync = fail_second
            try:
                return original_write(folder, name, value, replace)
            finally:
                os.fsync = original_sync
        self.store.write = write_with_failed_directory_sync
        with self.assertRaises(OSError):
            self.responder.claim_one(self.runner)
        self.store.write = original_write
        self.assertEqual(self.ledger()["state"], "claimed")
        self.assertFalse(self.responder.claim_one(str(uuid.uuid4()))["claimed"])

    def test_processing_expiry_becomes_terminal(self):
        claim = self.claim()
        self.now += 701
        with self.assertRaisesRegex(r.Refused, "request_expired"):
            self.publish(claim)
        self.assertEqual(self.ledger()["state"], "expired")

    def test_readiness_requires_explicit_provisioned_and_bounded_ttl(self):
        for consent, ttl in [(False, 720), (True, 901), (True, 0)]:
            with self.assertRaises(r.Refused):
                r.readiness(self.store, consent, ttl, self.now)
        value = r.readiness(self.store, True, 720, self.now)
        self.assertEqual(value["expectedPollSeconds"], 600)
        self.assertEqual(value["mode"], "scheduled_degraded")
        self.assertEqual(os.stat(self.base / "readiness.json").st_mode & 0o777, 0o600)
        self.assertEqual(r.preflight(self.store)["readinessPresent"], True)


if __name__ == "__main__":
    unittest.main()
