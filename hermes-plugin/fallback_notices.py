"""Surface real provider fallback decisions before the alternate model runs.
Uses the installed Hermes status callback contract; never changes routing or credentials.
"""
def install(store=None):
    try:
        from agent import chat_completion_helpers as helpers
        original = helpers._buffer_fallback_notice
    except (ImportError, AttributeError):
        return False
    if getattr(original, '_alice_immediate_fallback', False) is True:
        return True
    def immediate(agent, notice):
        record(agent, notice, store)
        emit = getattr(agent, '_emit_status_kind', None)
        if callable(emit):
            try:
                emit('model_change', notice, origin='alice_model_fallback')
                return
            except Exception:
                pass
        # Older runtimes retain their existing notification path.
        original(agent, notice)
    immediate._alice_immediate_fallback = True
    helpers._buffer_fallback_notice = immediate
    install_startup_notice(store)
    return True


def record(agent, notice, store):
    # Background errands need a durable notice even without a connected chat client.
    session = getattr(agent, 'session_id', None)
    if store is None or not isinstance(session, str) or not session:
        return False
    try:
        home = store._default_home()
        for entry in store.listing(home):
            if entry.get('session_id') != session:
                continue
            notices = list(entry.get('model_notices') or [])
            if not notices or notices[-1] != notice:
                notices.append(notice)
                store.update(home, entry['id'], model_notices=notices[-8:])
            return True
    except Exception:
        pass  # Failure to persist a notice never changes the model's routing or task state.
    return False


def emit_startup_notice(agent, store=None):
    pending = getattr(agent, '_pending_fallback_notice', None)
    emit = getattr(agent, '_emit_status_kind', None)
    if not pending or not callable(emit):
        return
    try:
        for notice in pending if isinstance(pending, list) else [pending]:
            record(agent, str(notice), store)
            emit('model_change', str(notice), origin='alice_startup_model_fallback')
        agent._pending_fallback_notice = None
    except Exception:
        pass  # Keep the existing delayed path if the callback is unavailable.


def install_startup_notice(store):
    try:
        from agent import turn_context
        original = turn_context._collect_pre_llm_call_context
    except (ImportError, AttributeError):
        return False
    if getattr(original, '_alice_startup_notice', False) is True:
        return True
    def before(agent, *args, **kwargs):
        emit_startup_notice(agent, store)
        return original(agent, *args, **kwargs)
    before._alice_startup_notice = True
    turn_context._collect_pre_llm_call_context = before
    return True
