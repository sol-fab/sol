#!/usr/bin/env bash
# Provider-neutral phase bodies. A phase here owns ordering, verdicts and evidence;
# it names no provider and branches on none. Provider mechanics arrive through
# hook_${PROVIDER}_*.
#
# No phase body has moved yet: phase_cloud is still provider-local until the body
# swap lands. This file exists first so the sandbox and the guards have something to
# point at.
