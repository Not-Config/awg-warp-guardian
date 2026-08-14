# Third-party notices

`vendor/warp_generator.sh` is copied from the separate
[`ImMALWARE/bash-warp-generator`](https://github.com/ImMALWARE/bash-warp-generator)
project. It provides local command-line WARP registration; this repository does
not copy the source code of `warp-gen.github.io`.

Copyright (c) 2024 MALWARE. It is distributed under the MIT License; the
original license text is included as `vendor/LICENSE.ImMALWARE`.

The bundled copy is security-sanitized: code that printed PrivateKey-bearing
configs as `vpn://` data or embedded them in an external download URL was
removed. Package-management and interactive-environment code was removed too.
The generator writes credentials only to a local `warp.conf` file with no
secret output.
