"""Fail-closed pre-tool policy. Model descriptions never determine permissions."""
import importlib.util
import shlex
from pathlib import Path

_spec = importlib.util.spec_from_file_location('alice_review_tasks', Path(__file__).with_name('review_tasks.py'))
module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(module)
Store = module.Store

READ_TOOLS = frozenset({
    'web_search', 'web_extract', 'image_search', 'read_file', 'list_directory', 'search_files',
    'vision_analyze', 'session_search', 'session_get', 'search_memory', 'memory_search',
    'browser_snapshot', 'browser_screenshot', 'browser_get_url', 'browser_get_text',
    'browser_back', 'browser_scroll', 'browser_wait', 'browser_tabs',
    'purchase_discover', 'purchase_verify', 'catalog_search', 'catalog_product',
    'think', 'ask_person', 'read_agent', 'list_agents', 'review_read',
})
CONTROL_TOOLS = frozenset({'review_tasks'})
# Only exact, known read operations. Unknown extension names do not inherit permissions.
READ_ACTIONS = {
    'watchers': {'list'}, 'goals': {'list', 'get', 'create', 'update', 'step', 'decide', 'link_routine'},
}


def safe_terminal(args):
    command = args.get('command', '')
    if not isinstance(command, str) or any(c in command for c in (';', '|', '&', '>', '<', '`', '$', '\n')): return False
    try: parts = shlex.split(command)
    except ValueError: return False
    if not parts: return False
    # No arbitrary executables, interpreters, wrappers or find -exec/-delete.
    if parts[0] in ('pwd', 'ls', 'cat', 'head', 'tail', 'wc', 'stat', 'rg'):
        return not any(p.startswith(('--pre', '--hostname-bin')) for p in parts[1:])
    return False


def preparation(tool, args):
    if tool in READ_TOOLS or tool in CONTROL_TOOLS: return True
    if tool in READ_ACTIONS and args.get('action') in READ_ACTIONS[tool]: return True
    if tool in ('terminal', 'shell', 'bash', 'run_command') and safe_terminal(args): return True
    # Draft tools are explicit API operations. Arbitrary browser clicks/typing can
    # submit a form; they are not declared harmless from an agent-supplied label.
    # Arbitrary URLs can mutate a service through GET (logout, unsubscribe).
    # Read through verified extraction tools; navigation is not presumed safe.
    return False


def check(home, tool, args, session, profile=''):
    args = args if isinstance(args, dict) else {}
    if preparation(tool, args): return None
    store = Store(home)
    try:
        # Legacy errands already have a host-owned checkout/access harness.
        # draft_only also applies outside Tasks. In act, the existing harness
        # remains in charge of legacy chats; tracked Tasks stay guarded after closing.
        mode = store.autonomy()
        if mode == 'act' and tool in ('gmail_create_draft', 'gmail_update_draft'): return None
        tracked = [t for t in store.listing() if session in [t['session_id'], *t.get('session_aliases', [])] and t['profile'] == profile]
        active = [t for t in tracked if t['status'] not in ('done', 'failed')]
        if mode == 'act' and not tracked: return None
        if mode == 'act' and session.startswith('errand-') and not active: return None
        if session and store.consume(tool, args, session, profile): return None
        return {'action': 'block', 'message': (
            'No external action was executed. This tool is not a verified read/draft operation. '
            'Use review_tasks to create a Task for the original request if needed, prepare the concrete result, '
            'record checks against that request, and submit needs_review with the exact tool name and arguments. '
            'Only the person can accept its current version in Alice. A changed call needs a new review. '
            'Known read and draft tools can continue immediately. Autonomy: ' + mode)}
    finally: store.close()
