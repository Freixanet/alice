"""Alice Secure Runner proof of concept: API-only *fictional* commerce adapter.

This package is NOT a sandbox, a payment processor or a production service.
The actual browser/credential isolation and real merchant adapters remain P0.
"""

from .core import AliceRunner, Denied, Indeterminate

__all__ = ["AliceRunner", "Denied", "Indeterminate"]
