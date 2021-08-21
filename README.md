# meta-fossology

Yocto meta-layer for automatic scan of built sources using
[Fossology](https://www.fossology.org/).

## Build host requirements

* Yocto build requirements
* python3-requests
* python3-requests-toolbelt

## How-To

To enable Fossology scan on built sources, following lines shall be added to
_local.conf_ file of current Yocto build:

```
FOSSOLOGY_SERVER = "http://127.0.0.1:8081/repo"
FOSSOLOGY_TOKEN = "<MY-TOKEN>"
```

_FOSSOLOGY_TOKEN_ shall be set to the value of a read/write token generated
through Fossology web UI.

### Exclude packages from scan

By default, _-initial_, _-cross_, _-native_, _nativesdk-_ and _-cross-canadian_
packages are excluded from the scan; to customize this behaviour, following
variables are available:

```
# Include *-initial and *-cross packages
FOSSOLOGY_EXCLUDE_CROSS_INITIAL = "0"

# Include *-native packages
FOSSOLOGY_EXCLUDE_NATIVE = "0"

# Include nativesdk-* and *-cross-canadian packages
FOSSOLOGY_EXCLUDE_SDK = "0"
```

A selection of target packages, contained in _FOSSOLOGY_EXCLUDE_PACKAGES_, is
also excluded.

### Select upload folder

Upload folder can be selected through the _FOSSOLOGY_FOLDER_ variable, either
using the folder name or its numeric ID.

e.g.
```
FOSSOLOGY_FOLDER = "My upload folder"
```

By default the root folder, having ID=1, is used.

### Customize analysis and decider agents

Analysis and decider agents can be customized using respectively the
_FOSSOLOGY_ANALYSIS_ and _FOSSOLOGY_DECIDER_ variables.

e.g.
```
FOSSOLOGY_ANALYSIS = "bucket copyright_email_author ecc keyword mime monk nomos"
FOSSOLOGY_DECIDER = "nomos_monk bulk_reused new_scanner"
```

For available agents see the [fossology class](lib/fossology.py).

### Customize output report format

Report format can be customized using the _FOSSOLOGY_REPORT_FORMAT_ variable.

e.g.
```
FOSSOLOGY_REPORT_FORMAT = "spdx2tv"
```

For available formats see the [fossology class](lib/fossology.py).

### Report output directory

Once generated, reports will be downloaded to _DEPLOY_DIR_FOSSOLOGY_, which
defaults to _tmp/deploy/fossology_.

### Delete upload from server

In order to delete a specific upload from the Fossology server, the
_fossology_delete_ task can be invoked.

e.g.
```
bitbake -c fossology_delete opkg-utils
```

## License

Meta-fossology layer is released under the [MIT license](LICENSE.MIT).

Fossology is a Linux Foundation Project with its own licenses; for details, see
the [Fossology official website](https://www.fossology.org/).
