#
# Yocto class for automatic Fossology scan
#
# Copyright (C) 2021 Francesco Valla <valla.francesco@gmail.com>
#
# SPDX-License-Identifier: MIT
#

FOSSOLOGY_SERVER ??= "http://127.0.0.1:8081/repo"
FOSSOLOGY_TOKEN ??= ""
FOSSOLOGY_ANALYSIS ?= "${AVAILABLE_ANALYSIS}"
FOSSOLOGY_DECIDER ?= "${AVAILABLE_DECIDER}"
FOSSOLOGY_REPORT_FORMAT ??= "spdx2tv"
FOSSOLOGY_FOLDER ??= "1"

FOSSOLOGY_EXCLUDE_PACKAGES ?= "binutils-cross linux-libc-headers libtool-cross gcc-cross libgcc-initial glibc libgcc gcc gcc-runtime glibc-locale shadow-sysroot"

FOSSOLOGY_EXCLUDE_NATIVE ??= "1"
FOSSOLOGY_EXCLUDE_SDK ??= "1"

DEPLOY_DIR_FOSSOLOGY ?= "${DEPLOY_DIR}/fossology"
FOSSOLOGY_WORKDIR = "${WORKDIR}/fossology-work/"
FOSSOLOGY_REPORTDIR = "${WORKDIR}/fossology-report/"

AVAILABLE_ANALYSIS = "bucket copyright_email_author ecc keyword mime monk nomos ojo package reso"
AVAILABLE_DECIDER = "nomos_monk bulk_reused new_scanner ojo_decider"
AVAILABLE_FORMATS = "dep5 spdx2 spdx2tv readmeoss unifiedreport"

python () {
    analysis_available = d.getVar('AVAILABLE_ANALYSIS').split()
    analysis_enabled = d.getVar('FOSSOLOGY_ANALYSIS').split()
    for invalid in filter(lambda x: x not in analysis_available, analysis_enabled):
        bb.fatal("Invalid element %s found in FOSSOLOGY_ANALYSIS" % invalid)

    decider_available = d.getVar('AVAILABLE_DECIDER').split()
    decider_enabled = d.getVar('FOSSOLOGY_DECIDER').split()
    for invalid in filter(lambda x: x not in decider_available, decider_enabled):
        bb.fatal("Invalid element %s found in FOSSOLOGY_DECIDER" % invalid)

    formats_available = d.getVar('AVAILABLE_FORMATS').split()
    format_selected = d.getVar('FOSSOLOGY_REPORT_FORMAT')
    if format_selected not in formats_available:
        bb.fatal("Invalid report format %s selected" % (format_selected))
}

python () {
    pn = d.getVar('PN')
    assume_provided = (d.getVar("ASSUME_PROVIDED") or "").split()
    if pn in assume_provided:
        for p in d.getVar("PROVIDES").split():
            if p != pn:
                pn = p
                break

    # Do not include recipes which don't produce packages
    if bb.data.inherits_class('nopackages', d) or \
       bb.data.inherits_class('packagegroup', d) or \
       bb.data.inherits_class('image', d):
        return

    # Analyze native recipes only if not excluded
    if pn.endswith('-native') and d.getVar("FOSSOLOGY_EXCLUDE_NATIVE") == "1":
        return

    # Analyze SDK-related recipes only if not excluded
    if pn.startswith('nativesdk-') and d.getVar("FOSSOLOGY_EXCLUDE_SDK") == "1":
        return
    if pn.endswith('-crosssdk') and d.getVar("FOSSOLOGY_EXCLUDE_SDK") == "1":
        return
    if pn.endswith('-cross-canadian') and d.getVar("FOSSOLOGY_EXCLUDE_SDK") == "1":
        return

    # Exclude packages contained in FOSSOLOGY_EXCLUDE_PACKAGES
    if pn in d.getVar("FOSSOLOGY_EXCLUDE_PACKAGES").split():
        bb.debug(1, 'fossology: %s excluded from analysis' % (pn))
        return

    d.appendVarFlag('do_fossology_deploy_report', 'depends', ' %s:do_fossology_get_report' % pn)
}

def get_upload_filename(d):
    return '%s.tar.gz' % (d.getVar('PF'))

def get_report_filename(d, format):
    return '%s.%s' % (d.getVar('PF'), format)

def get_folder_id(server, name):
    if name.isdecimal():
        return int(name)
    else:
        return server.get_folder_id(name)

python do_fossology_create_tarball() {
    import tarfile
    import os

    def exclude_paths(tarinfo):
        if tarinfo.isdir() and tarinfo.name.endswith('.git'):
            return None
        elif tarinfo.issym() and tarinfo.name in ['oe-workdir', 'oe-logs']:
            return None
        return tarinfo

    fossology_workdir = d.getVar('FOSSOLOGY_WORKDIR')
    srcdir = os.path.realpath(d.getVar('S'))
    filename = get_upload_filename(d)

    bb.note('Archiving the sources to be analyzed as %s...' % (filename))

    tar = tarfile.open(os.path.join(fossology_workdir, filename), 'w:gz')
    tar.add(srcdir, arcname=os.path.basename(srcdir), filter=exclude_paths)
    tar.close()
}
do_fossology_create_tarball[cleandirs] = "${FOSSOLOGY_WORKDIR}"

python do_fossology_upload_analyze() {
    from fossology import FossologyServer, FossologyError, FossologyInvalidParameter, \
                          FossologyRetryAfter, FossologyJobFailure
    import os

    fossology_workdir = d.getVar('FOSSOLOGY_WORKDIR')
    fossology_folder = d.getVar('FOSSOLOGY_FOLDER')

    fossology_analysis = d.getVar('FOSSOLOGY_ANALYSIS').split()
    fossology_decider = d.getVar('FOSSOLOGY_DECIDER').split()

    filename = get_upload_filename(d)
    filepath = os.path.join(fossology_workdir, filename)

    server_url = d.getVar('FOSSOLOGY_SERVER', True)
    token = d.getVar('FOSSOLOGY_TOKEN', True)
    server = FossologyServer(server_url, token)

    folder_id = get_folder_id(server, fossology_folder)
    if folder_id is None:
        bb.fatal('Cannot find folder "%s"' % (fossology_folder))
    else:
        bb.debug(1, 'Folder "%s" has ID %d' % (fossology_folder, folder_id))

    upload_id = server.get_upload_id(filename, folder_id)
    if upload_id is not None:
        bb.note('Sources already uploaded to fossology server (ID = %d)' % (upload_id))
    else:
        wait_time = 5
        for i in range(10):
            bb.debug(1, 'Upload %s, trial %d' % (filename, i))
            upload_id = server.upload(filepath, filename, folder_id)
            if upload_id is not None:
                bb.note('Uploading %s to fossology server, with ID = %u' % (filename, upload_id))
                break
            else:
                bb.warn('Upload failed, will retry in %ds' % (wait_time))
                time.sleep(wait_time)
                wait_time = wait_time * 2
        else:
            bb.fatal('Failed to upload %s to fossology server' % filename)

    bb.debug(1, 'Wait for upload summary to be ready')
    while True:
        try:
            server.upload_get_summary(upload_id)
        except FossologyRetryAfter as ra:
            bb.note('Summary not yet ready, will retry after %ds' % (ra.time))
            time.sleep(ra.time)
        except FossologyError as e:
            bb.fatal('Cannot get upload summary: %s' % (e.message))
        else:
            bb.note('Upload complete')
            break

    bb.debug(1, 'Schedule analysis job')
    bb.debug(2, 'Analysis agents: %s' % (fossology_analysis))
    bb.debug(2, 'Decider agents: %s' % (fossology_decider))
    try:
        job_id = server.schedule_job(upload_id, folder_id, fossology_analysis, fossology_decider)
    except FossologyError as e:
        bb.fatal('Failed to schedule analysis: %s' % (e.message))
    except FossologyInvalidParameter as e:
        bb.fatal('Parameter error: %s' % (e.message))
    else:
        bb.note('Scheduled analysis job, with ID = %d' % (job_id))

    bb.debug(1, 'Wait for job to complete')
    wait_time = 2
    while True:
        try:
            if server.job_completed(job_id):
                bb.note('Analysis job completed')
                break
        except FossologyError as e:
            bb.fatal('Failed to retrieve job status: %s' % (e.message))
        except FossologyJobFailure as f:
            bb.fatal('Fossology job %d failed' % (f.job))
        else:
            bb.debug(1, 'Job not yet completed, will retry after %ds' % (wait_time))
            time.sleep(wait_time)
            wait_time = max(wait_time * 2, 60)

    bb.debug(1, 'Wait for licenses to be ready')
    while True:
        try:
            agents = [x for x in ["nomos", "monk", "ojo", "reso"] if x in fossology_analysis]
            server.upload_get_licenses(upload_id, agents)
        except FossologyRetryAfter as ra:
            bb.note('Licenses not yet ready, will retry after %ds' % (ra.time))
            time.sleep(ra.time)
        except FossologyError as e:
            bb.fatal('Cannot get upload licenses: %s' % (e.message))
        except FossologyInvalidParameter as e:
            bb.fatal('Parameter error: %s' % (e.message))
        else:
            bb.note('Analysis complete')
            break
}

python do_fossology_delete() {
    from fossology import FossologyServer, FossologyError, FossologyRetryAfter

    fossology_folder = d.getVar('FOSSOLOGY_FOLDER')
    filename = get_upload_filename(d)

    server_url = d.getVar('FOSSOLOGY_SERVER', True)
    token = d.getVar('FOSSOLOGY_TOKEN', True)
    server = FossologyServer(server_url, token)

    folder_id = get_folder_id(server, fossology_folder)
    if folder_id is None:
        bb.fatal('Cannot find folder "%s"' % (fossology_folder))

    upload_id = server.get_upload_id(filename, folder_id)
    if upload_id is None:
        bb.warn('Upload %s not found on fossology server' % filename)
        return

    while upload_id is not None:
        if not server.upload_delete(upload_id):
            bb.error("Failed to delete upload ID %d" % upload_id)
        else:
            bb.note("Deleted upload ID %d" % upload_id)
        upload_id = server.get_upload_id(filename, folder_id)
}

python do_fossology_get_report() {
    from fossology import FossologyServer, FossologyError, FossologyRetryAfter
    import os

    fossology_reportdir = d.getVar('FOSSOLOGY_REPORTDIR')
    fossology_folder = d.getVar('FOSSOLOGY_FOLDER')
    report_format = d.getVar('FOSSOLOGY_REPORT_FORMAT')

    filename = get_upload_filename(d)
    reportname = get_report_filename(d, report_format)

    server_url = d.getVar('FOSSOLOGY_SERVER', True)
    token = d.getVar('FOSSOLOGY_TOKEN', True)
    server = FossologyServer(server_url, token)

    folder_id = get_folder_id(server, fossology_folder)
    if folder_id is None:
        bb.fatal('Cannot find folder "%s"' % (fossology_folder))

    upload_id = server.get_upload_id(filename, folder_id)
    if upload_id is None:
        bb.fatal('Upload %s not found on fossology server' % filename)

    try:
        report_id = server.report_trigger_generation(upload_id, report_format)
    except FossologyError as e:
        bb.fatal('Failed to trigger report generation: %s' % (e.message))
    except FossologyInvalidParameter as e:
        bb.fatal('Parameter error: %s' % (e.message))

    while True:
        try:
            reportdata = server.download_report(report_id)
        except FossologyRetryAfter as ra:
            bb.note('Waiting for report, will retry after %ds' % (ra.time))
            time.sleep(ra.time)
        except FossologyError as e:
            bb.fatal('Cannot get %s report: %s' % (report_format, e.message))
        else:
            reportpath = os.path.join(fossology_reportdir, reportname)
            with open(reportpath, 'wb') as reportfile:
                reportfile.write(reportdata)
            bb.note("%s report saved to %s" % (report_format, reportpath))
            break
}
do_fossology_get_report[cleandirs] = "${FOSSOLOGY_REPORTDIR}"

addtask do_fossology_create_tarball after do_patch
addtask do_fossology_upload_analyze after do_fossology_create_tarball
addtask do_fossology_get_report after do_fossology_upload_analyze
addtask do_fossology_delete
addtask do_fossology_deploy_report
do_build[recrdeptask] += "do_fossology_deploy_report"
do_rootfs[recrdeptask] += "do_fossology_deploy_report"
do_populate_sdk[recrdeptask] += "do_fossology_deploy_report"

SSTATETASKS += "do_fossology_deploy_report"
do_fossology_deploy_report() {
    echo "Deploying fossology report from ${FOSSOLOGY_REPORTDIR} to ${DEPLOY_DIR_FOSSOLOGY}."
}
python do_fossology_deploy_report_setscene() {
    sstate_setscene(d)
}
addtask do_fossology_deploy_report_setscene

do_fossology_deploy_report[dirs] = "${FOSSOLOGY_REPORTDIR}"
do_fossology_deploy_report[sstate-inputdirs] = "${FOSSOLOGY_REPORTDIR}"
do_fossology_deploy_report[sstate-outputdirs] = "${DEPLOY_DIR_FOSSOLOGY}"
