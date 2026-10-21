#!/usr/bin/env bash
# The declared provider list. This file is the one place a provider name is allowed
# to be enumerated: guards iterate this list instead of writing the pair inline, so
# adding a provider is an edit here plus a provider file, and nothing else.
#
# Sourced, never executed.
PROVIDERS=(aws gcp)
