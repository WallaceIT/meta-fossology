# meta-fossology

Yocto meta-layer for automatic scan of used sources using Fossology.

## Build host requirements

* Yocto build requirements
* python3-requests
* python3-requests-toolbelt

## How-To

To enable Fossology scan on built sources, add following lines to _local.conf_:

```
FOSSOLOGY_SERVER = "http://127.0.0.1:8081/repo"
FOSSOLOGY_TOKEN = "<MY-TOKEN>"
```

_FOSSOLOGY_TOKEN_ shall be set to the value of a read/write token generated
through Fossolgy web UI.

### Exclude packages from scan

By default, _-native_, _nativesdk-_ and _-canadian_ packages are excluded from
the scan; to customize this behaviour, following variables are available:

```
FOSSOLOGY_EXCLUDE_NATIVE = "1"
FOSSOLOGY_EXCLUDE_SDK = "1"
FOSSOLOGY_EXCLUDE_CANADIAN = "1"
```

A selection of target packages, contained in _FOSSOLOGY_EXCLUDE_PACKAGES_, is
also excluded.

### Customize analysis agents

Analysis agents can be customized using the _FOSSOLOGY_ANALYSIS_ variable.

Following agents are available:

* bucket
* copyright_email_author
* ecc
* keyword
* mime
* monk
* nomos
* ojo
* package
* reso

e.g.
```
FOSSOLOGY_ANALYSIS = "bucket copyright_email_author ecc keyword mime monk nomos"
```

### Customize output report format

Report format can be customized using the _FOSSOLOGY_REPORT_FORMAT_ variable.

Following formats are available:

* dep5
* spdx2
* spdx2tv
* readmeoss
* unifiedreport

e.g.
```
FOSSOLOGY_REPORT_FORMAT = "spdx2tv"
```

### Report output directory

Once generated, reports will be downloaded to _DEPLOY_DIR_FOSSOLOGY_, which
defaults to _tmp/deploy/fossology_.
