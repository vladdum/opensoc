# Copyright OpenSoC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

FUSESOC = fusesoc
CORES_ROOT = --cores-root=. --cores-root=hw/ip/ibex --cores-root=hw/ip/ibex/vendor/lowrisc_ip

.PHONY: lint
lint:
	$(FUSESOC) $(CORES_ROOT) run --target=lint opensoc:soc:opensoc_top
