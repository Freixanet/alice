"""Fallback metadata for older PEP-517/PEP-621 build frontends on user hosts.

This is an Alice-owned package only; it does not install or patch Hermes.
"""

from setuptools import find_packages, setup

setup(
    name="alice-secure-runner-prototype",
    version="0.1.0",
    description="Synthetic Alice Secure Runner HTTPS contract prototype",
    packages=find_packages(include=("alice_secure_runner", "alice_secure_runner.*")),
    python_requires=">=3.11",
    install_requires=[],
)
