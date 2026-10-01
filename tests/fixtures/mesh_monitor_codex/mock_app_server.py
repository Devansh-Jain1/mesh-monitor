#!/usr/bin/env python3
"""Offline JSONL protocol fixture. Never calls Codex, network, or models."""
import json
import os
from pathlib import Path
import sys
import time
import threading

write_lock = threading.Lock()

scenario = Path.cwd().name
thread = 'monitor-fixture-thread'
turn = 'turn-fixture'
turn_count = 0
race_scenarios = {'disconnect_reconnect', 'cancel_reconnect', 'stale_send_cancel', 'late_interrupt_failure', 'interrupt_timeout', 'interrupt_ack_no_terminal'}
first_instance = False
if scenario in race_scenarios:
    try:
        descriptor = os.open('first-instance', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(descriptor)
        first_instance = True
    except FileExistsError:
        pass

def wait_for_marker(name):
    deadline = time.monotonic() + 1.8
    while not Path(name).exists() and time.monotonic() < deadline:
        time.sleep(0.005)


def emit(message, fragmented=False):
    data = (json.dumps(message, ensure_ascii=False) + '\n').encode()
    with write_lock:
        if fragmented:
            for offset in range(0, len(data), 7):
                os.write(sys.stdout.fileno(), data[offset:offset+7])
        else:
            os.write(sys.stdout.fileno(), data)

def notify(method, params):
    emit({'method': method, 'params': {'threadId': thread, **params}})

Path('child.pid').write_text(str(os.getpid()))
Path('arguments.json').write_text(json.dumps(sys.argv[1:]))
for line in sys.stdin:
    msg = json.loads(line)
    with open('wire.jsonl', 'a') as log:
        log.write(json.dumps(msg) + '\n')
    method, rid = msg.get('method'), msg.get('id')
    replied_early = False
    if not method:
        if rid == 'approval-fixture':
            notify('turn/completed', {'turn': {'id': turn, 'status': 'interrupted', 'items': []}})
        continue
    if rid is None:
        continue
    if method == 'initialize':
        if scenario == 'connect_cancel':
            continue
        if scenario in {'disconnect_reconnect', 'cancel_reconnect'}:
            if first_instance:
                Path('first-initialize-held').write_text('held')
                continue
            Path('second-initialize-held').write_text('held')
            wait_for_marker('release-initialize')
        result = {'userAgent': 'fixture'}
    elif method == 'account/read':
        result = {'requiresOpenaiAuth': True, 'account': None if scenario == 'unauthenticated' else {'type': 'chatgpt', 'email': 'never-expose@example.test'}}
    elif method == 'thread/read':
        result = {'thread': {'id': thread, 'name': 'Mesh Monitor' if scenario != 'foreign_resume' else 'Control Room', 'status': {'type': 'active' if scenario == 'busy_resume' else 'notLoaded'}, 'turns': [], 'model': 'stale-history-model'}}
    elif method in ('thread/start', 'thread/resume'):
        result = {'thread': {'id': thread, 'model': 'not-the-resolved-model'},
                  'model': 'fixture-resumed-model' if method == 'thread/resume' else 'fixture-session-model',
                  'modelProvider': 'fixture-provider'}
        if scenario == 'missing_model':
            result.pop('model'); result.pop('modelProvider')
        elif scenario == 'invalid_model_metadata':
            result.update(model=42, modelProvider={'not': 'a string'})
        elif scenario == 'blank_model_metadata':
            result.update(model=' \n ', modelProvider='')
        elif scenario == 'unsafe_model_metadata':
            result.update(model='model\ninjected', modelProvider='p' * 257)
        elif scenario == 'partial_model_metadata':
            result.update(model=None, modelProvider='custom-provider')
    elif method == 'thread/name/set':
        result = {}
    elif method == 'turn/start':
        turn_count += 1
        if scenario in {'interrupt_drain', 'interrupt_ack_first', 'interrupt_ack_no_terminal', 'stale_send_cancel', 'late_interrupt_failure', 'interrupt_timeout'}:
            turn = f'turn-fixture-{turn_count}'
        if scenario == 'interrupt_ack_first' and turn_count == 2:
            if not Path('old-terminal-sent').exists():
                Path('replacement-before-terminal').write_text('unsafe early retry')
            # These stale frames arrive while the replacement turn has no RPC ID.
            notify('turn/started', {'turn': {'id': 'turn-fixture-1', 'status': 'inProgress'}})
            notify('item/agentMessage/delta', {'turnId': 'turn-fixture-1', 'itemId': 'old', 'delta': 'STALE OLD OUTPUT'})
            notify('turn/completed', {'turn': {'id': 'turn-fixture-1', 'status': 'interrupted', 'items': []}})
            Path('replacement-start-held').write_text('held')
            wait_for_marker('release-replacement-start')
        notify('turn/started', {'turn': {'id': turn, 'status': 'inProgress'}})
        if scenario == 'large_unknown_notification':
            for _ in range(4):
                notify('unknown/' + 'x' * 500_000, {'turnId': turn})
        if scenario == 'nonterminal_completion':
            notify('turn/completed', {'turn': {'id': turn, 'status': 'inProgress', 'items': []}})
        if scenario == 'preack_count_limit':
            for index in range(513):
                notify('item/agentMessage/delta', {'turnId': turn, 'itemId': 'pending', 'delta': '.'})
            continue
        if scenario == 'preack_byte_limit':
            notify('item/agentMessage/delta', {'turnId': turn, 'itemId': 'pending', 'delta': '.' * 1_250_001})
            continue
        if scenario == 'bound_turn_stale':
            emit({'id': rid, 'result': {'turn': {'id': turn, 'status': 'inProgress'}}})
            replied_early = True
            time.sleep(0.04)
            notify('turn/started', {'turn': {'id': 'old-turn', 'status': 'inProgress'}})
            notify('item/agentMessage/delta', {'turnId': 'old-turn', 'itemId': 'old', 'delta': 'STALE OLD OUTPUT'})
            notify('turn/completed', {'turn': {'id': 'old-turn', 'status': 'interrupted', 'items': []}})
            # Conflicting top-level/nested IDs must not pass either.
            notify('turn/completed', {'turnId': turn, 'turn': {'id': 'old-turn', 'status': 'interrupted', 'items': []}})
        if scenario in {'approval', 'approval_preack'}:
            if scenario == 'approval':
                emit({'id': rid, 'result': {'turn': {'id': turn, 'status': 'inProgress'}}})
                replied_early = True
                time.sleep(0.04)  # Let the client bind the correlated RPC reply.
            emit({'id': 'approval-fixture', 'method': 'item/commandExecution/requestApproval', 'params': {'threadId': thread, 'turnId': turn, 'command': 'touch forbidden'}})
            if scenario == 'approval_preack':
                continue  # No start acknowledgement: cancellation must close safely.
        elif scenario not in ('timeout', 'cancel') and not (
            scenario in {'interrupt_drain', 'interrupt_ack_first'} and turn_count == 1
            or scenario in {'stale_send_cancel', 'late_interrupt_failure', 'interrupt_timeout', 'interrupt_ack_no_terminal'} and first_instance
        ):
            # A late notification from another conversation must not contaminate output.
            emit({'method': 'item/agentMessage/delta', 'params': {'threadId': 'foreign', 'turnId': turn, 'itemId': 'foreign', 'delta': 'WRONG'}})
            notify('item/completed', {'turnId': turn, 'item': {'id': 'comment', 'type': 'agentMessage', 'text': 'Checking…', 'phase': 'commentary'}})
            notify('item/started', {'turnId': turn, 'item': {'id': 'answer', 'type': 'agentMessage', 'text': '', 'phase': 'final_answer'}})
            emit({'method': 'item/agentMessage/delta', 'params': {'threadId': thread, 'turnId': turn, 'itemId': 'answer', 'delta': 'A precise answer 👀.'}}, fragmented=True)
            notify('item/completed', {'turnId': turn, 'item': {'id': 'answer', 'type': 'agentMessage', 'text': 'A precise answer 👀.', 'phase': 'final_answer'}})
            # Deliberately complete before the RPC acknowledgement: tiny replies can do this.
            notify('turn/completed', {'turn': {'id': turn, 'status': 'completed', 'items': []}})
        result = {'turn': {'id': turn, 'status': 'inProgress'}}
    elif method == 'turn/interrupt':
        if scenario == 'interrupt_ack_first':
            interrupted_turn = turn
            emit({'id': rid, 'result': {}})
            Path('interrupt-ack-sent').write_text('acknowledged')
            def later_terminal():
                wait_for_marker('release-old-terminal')
                Path('old-terminal-sent').write_text('sending terminal')
                notify('turn/completed', {'turn': {'id': interrupted_turn, 'status': 'interrupted', 'items': []}})
            threading.Thread(target=later_terminal, daemon=True).start()
            continue
        if scenario == 'interrupt_ack_no_terminal' and first_instance:
            emit({'id': rid, 'result': {}})
            Path('interrupt-held').write_text('acknowledged without terminal')
            continue
        if scenario in {'interrupt_drain', 'late_interrupt_failure'}:
            Path('interrupt-held').write_text('held')
            wait_for_marker('release-interrupt')
        if scenario == 'interrupt_timeout' and first_instance:
            Path('interrupt-held').write_text('held')
            continue
        notify('turn/completed', {'turn': {'id': turn, 'status': 'interrupted', 'items': []}})
        result = {}
    else:
        result = {}
    if not replied_early:
        emit({'id': rid, 'result': result})
    if scenario == 'closed_stdin' and method == 'thread/name/set':
        # Keep stdout and the process alive after closing the request pipe. A
        # client that trusts only Process.isRunning must handle EPIPE safely.
        os.close(sys.stdin.fileno())
        Path('stdin-closed').write_text('closed')
        time.sleep(8)
        break
