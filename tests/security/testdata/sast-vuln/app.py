"""Runs a command through a shell: Semgrep's subprocess-shell-true (ERROR, security, MEDIUM confidence)."""
import subprocess

subprocess.call(input(), shell=True)
