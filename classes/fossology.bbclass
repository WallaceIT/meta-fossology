#
# Yocto class for automatic Fossology scan
#
# Copyright (C) 2021 Francesco Valla <valla.francesco@gmail.com>
#
# SPDX-License-Identifier: MIT
#

FOSSOLOGY_SERVER ??= "http://127.0.0.1:8081/repo"
FOSSOLOGY_TOKEN ??= ""
FOSSOLOGY_ANALYSIS ?= "bucket copyright_email_author ecc keyword mime monk nomos ojo package reso"
FOSSOLOGY_DECIDER ?= "nomos_monk bulk_reused new_scanner ojo_decider"
FOSSOLOGY_REPORT_FORMAT ??= "spdx2tv"
FOSSOLOGY_FOLDER ??= "1"

FOSSOLOGY_EXCLUDE_PACKAGES ?= "linux-libc-headers"

FOSSOLOGY_EXCLUDE_CROSS_INITIAL ??= "1"
FOSSOLOGY_EXCLUDE_NATIVE ??= "1"
FOSSOLOGY_EXCLUDE_SDK ??= "1"

DEPLOY_DIR_FOSSOLOGY ?= "${DEPLOY_DIR}/fossology"
FOSSOLOGY_WORKDIR = "${WORKDIR}/fossology-work/"
FOSSOLOGY_REPORTDIR = "${WORKDIR}/fossology-report/"

python () {
    pn = d.getVar('PN')
    assume_provided = (d.getVar('ASSUME_PROVIDED') or '').split()
    if pn in assume_provided:
        for p in d.getVar('PROVIDES').split():
            if p != pn:
                pn = p
                break

    # Do not include recipes which don't produce packages
    if bb.data.inherits_class('nopackages', d) or \
       bb.data.inherits_class('packagegroup', d) or \
       bb.data.inherits_class('image', d):
        return

    # Analyze -cross and -initial recipes only if not excluded
    if d.getVar('FOSSOLOGY_EXCLUDE_CROSS_INITIAL') == '1':
        for t in ['-initial', '-cross-${TARGET_ARCH}',
                  '-cross-initial-${TARGET_ARCH}']:
            if pn.endswith(d.expand(t)):
                return

    # Analyze native recipes only if not excluded
    if d.getVar('FOSSOLOGY_EXCLUDE_NATIVE') == '1':
        if pn.endswith('-native'):
            return

    # Analyze SDK-related recipes only if not excluded
    if d.getVar('FOSSOLOGY_EXCLUDE_SDK') == '1':
        if pn.startswith('nativesdk-'):
            return
        for t in ['-crosssdk-${SDK_SYS}', '-crosssdk-initial-${SDK_SYS}',
                  '-cross-canadian-${TRANSLATED_TARGET_ARCH}']:
            if pn.endswith(d.expand(t)):
                return

    # Just scan gcc-source for all the gcc related recipes
    if pn in ['gcc', 'libgcc', 'gcc-runtime']:
        bb.debug(1, 'fossology: excluding %s, covered by gcc-source' % (pn))
        return

    # Just scan glibc for all the glibc related recipes
    if pn.startswith('glibc-'):
        bb.debug(1, 'fossology: excluding %s, covered by glibc' % (pn))
        return

    # Exclude packages contained in FOSSOLOGY_EXCLUDE_PACKAGES
    if pn in d.getVar('FOSSOLOGY_EXCLUDE_PACKAGES').split():
        bb.debug(1, 'fossology: %s excluded from analysis' % (pn))
        return

    # Check configuration variables
    from fossology import FossologyServer

    invalid_agents = ', '.join([x for x in d.getVar('FOSSOLOGY_ANALYSIS').split() if x not in FossologyServer.AVAILABLE_ANALYSIS])
    if len(invalid_agents) != 0:
        bb.warn('Available analysis agents: %s' % (FossologyServer.AVAILABLE_ANALYSIS))
        bb.fatal('Invalid agents found in FOSSOLOGY_ANALYSIS: %s' % (invalid_agents))

    invalid_agents = ', '.join([x for x in d.getVar('FOSSOLOGY_DECIDER').split() if x not in FossologyServer.AVAILABLE_DECIDER])
    if len(invalid_agents) != 0:
        bb.warn('Available decider agents: %s' % (FossologyServer.AVAILABLE_DECIDER))
        bb.fatal('Invalid agents found in FOSSOLOGY_DECIDER: %s' % (invalid_agents))

    report_format = d.getVar('FOSSOLOGY_REPORT_FORMAT')
    if report_format not in FossologyServer.AVAILABLE_FORMATS:
        bb.warn('Available report formats: %s' % (FossologyServer.AVAILABLE_FORMATS))
        bb.fatal('Invalid format specified in FOSSOLOGY_REPORT_FORMAT: %s' % (report_format))

    # Make fossology_deploy_report, defined for all classes, depend on fossology_get_report
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
    import gzip
    import os

    fossology_workdir = d.getVar('FOSSOLOGY_WORKDIR')
    original_sysroot_native = d.getVar('STAGING_DIR_NATIVE')
    filename = get_upload_filename(d)
    filepath = os.path.join(fossology_workdir, filename)

    # Sources are unpacked and patched in a dedicated directory, in order not
    # to have interferences with other tasks

    bb.note('Extracting and patching sources...')

    def is_work_shared(d):
        pn = d.getVar('PN')
        return bb.data.inherits_class('kernel', d) or pn.startswith('gcc-source')

    if not is_work_shared(d):
        # Change the WORKDIR to make do_unpack do_patch run in another dir.
        d.setVar('WORKDIR', os.path.join(fossology_workdir, 'workdir'))
        # Restore the original path to recipe's native sysroot (it's relative to WORKDIR).
        d.setVar('STAGING_DIR_NATIVE', original_sysroot_native)

        # The changed 'WORKDIR' also caused 'B' changed, create dir 'B' for the
        # possibly requiring of the following tasks (such as some recipes's
        # do_patch required 'B' existed).
        bb.utils.mkdirhier(d.getVar('B'))

        bb.build.exec_func('do_unpack', d)

    # If required by recipe, convert CRLF to LF
    if bb.data.inherits_class('dos2unix', d):
        bb.build.exec_func('do_convert_crlf_to_lf', d)

    # Make sure recipes with shared workdir are patched only once
    if not (d.getVar('SRC_URI') == '' or is_work_shared(d)):
        bb.build.exec_func('do_patch', d)

    # Metadata is reset for all source file, in order to produce exactly the
    # same archive on different hosts at different times; this allows for upload
    # reuse even with hash checking in place.
    def exclude_paths_and_reset_metadata(tarinfo):
        name = os.path.basename(tarinfo.name)
        if tarinfo.isdir() and name in ['CVS', '.bzr', '.git', '.hg', '.osc', '.p4', '.repo', '.svn']:
            return None
        elif tarinfo.isfile() and name in ['.gitattributes', '.gitignore', '.gitmodules']:
            return None
        elif (tarinfo.isdir() or tarinfo.issym()) and name in ['oe-local-files', 'oe-logs', 'oe-workdir']:
            return None
        tarinfo.uid = tarinfo.gid = 1000
        tarinfo.uname = tarinfo.gname = 'fossy'
        tarinfo.mtime = 1629378450
        return tarinfo

    bb.note('Archiving the patched sources to be analyzed...')

    # TAR.GZ is produced in two steps in order to force its mtime
    with gzip.GzipFile(filepath, 'wb', mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode='w:') as tar:
            tar.add(d.getVar('S'), arcname=d.getVar('PF'), filter=exclude_paths_and_reset_metadata)
}
do_fossology_create_tarball[cleandirs] = "${FOSSOLOGY_WORKDIR}"

python do_fossology_upload_analyze() {
    from fossology import FossologyServer, FossologyError, FossologyInvalidParameter, \
                          FossologyRetryAfter, FossologyJobFailure
    import os

    fossology_workdir = d.getVar('FOSSOLOGY_WORKDIR')

    fossology_analysis = d.getVar('FOSSOLOGY_ANALYSIS').split()
    fossology_decider = d.getVar('FOSSOLOGY_DECIDER').split()
    fossology_folder = d.getVar('FOSSOLOGY_FOLDER')

    filename = get_upload_filename(d)
    filepath = os.path.join(fossology_workdir, filename)

    server_url = d.getVar('FOSSOLOGY_SERVER')
    token = d.getVar('FOSSOLOGY_TOKEN')
    server = FossologyServer(server_url, token)

    folder_id = get_folder_id(server, fossology_folder)
    if folder_id is None:
        bb.fatal('Cannot find folder "%s"' % (fossology_folder))
    else:
        bb.debug(1, 'Folder "%s" has ID %d' % (fossology_folder, folder_id))

    # Check if upload already esists on server
    upload_id = server.get_upload_id(filename, folder_id)
    if upload_id is not None:
        bb.note('File %s already present on server (ID = %d)' % (filename, upload_id))
        # Check hash of local file against remote one
        while True:
            try:
                data = server.upload_get_metadata(upload_id)
            except FossologyRetryAfter as ra:
                bb.note('Metadata not yet ready, will retry after %ds' % (ra.time))
                time.sleep(ra.time)
            except FossologyError as e:
                bb.fatal('Cannot get upload metadata: %s' % (e.message))
            else:
                break
        localhash = bb.utils.md5_file(filepath).lower()
        remotehash = data['hash']['md5'].lower()
        if localhash != remotehash:
            bb.warn('Hash mismatch for file %s (local: %s, remote: %s), forcing re-upload' % (filename, localhash, remotehash))
            if not server.upload_delete(upload_id):
                bb.fatal('Failed to delete upload ID %d' % upload_id)
            # Wait for upload to be deleted
            while server.get_upload_id(filename, folder_id) is not None:
                bb.debug(1, 'Waiting for %s (ID = %d) to be deleted' % (filename, upload_id))
                time.sleep(5)
            upload_id = None

    # If upload was not found, or re-upload forced, do upload the archived sources
    if upload_id is None:
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

    # Wait for upload summary to be ready, i.e. for ununpack and adj2nest jobs to complete
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

    # Schedule selected analysis jobs
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

    # Wait for scheduled jobs to complete, using the virtual job ID provided
    # during scheduling above
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
            wait_time = min(wait_time * 2, 60)

    # Wait for licenses summary to be ready
    bb.debug(1, 'Wait for licenses to be ready')
    while True:
        try:
            agents = [x for x in ['nomos', 'monk', 'ojo', 'reso'] if x in fossology_analysis]
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

    server_url = d.getVar('FOSSOLOGY_SERVER')
    token = d.getVar('FOSSOLOGY_TOKEN')
    server = FossologyServer(server_url, token)

    folder_id = get_folder_id(server, fossology_folder)
    if folder_id is None:
        bb.fatal('Cannot find folder "%s"' % (fossology_folder))

    # Delete all uploads with the same filename
    upload_id = server.get_upload_id(filename, folder_id)
    if upload_id is None:
        bb.warn('Upload %s not found on fossology server' % filename)
        return

    while upload_id is not None:
        if not server.upload_delete(upload_id):
            bb.error('Failed to delete upload ID %d' % upload_id)
        else:
            bb.note('Deleted upload ID %d' % upload_id)
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

    server_url = d.getVar('FOSSOLOGY_SERVER')
    token = d.getVar('FOSSOLOGY_TOKEN')
    server = FossologyServer(server_url, token)

    folder_id = get_folder_id(server, fossology_folder)
    if folder_id is None:
        bb.fatal('Cannot find folder "%s"' % (fossology_folder))

    upload_id = server.get_upload_id(filename, folder_id)
    if upload_id is None:
        bb.fatal('Upload %s not found on fossology server' % filename)

    # Trigger report generation
    try:
        report_id = server.report_trigger_generation(upload_id, report_format)
    except FossologyError as e:
        bb.fatal('Failed to trigger report generation: %s' % (e.message))
    except FossologyInvalidParameter as e:
        bb.fatal('Parameter error: %s' % (e.message))

    # Wait for report to be ready, then download and save it
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
            bb.note('%s report saved to %s' % (report_format, reportpath))
            break
}
do_fossology_get_report[cleandirs] = "${FOSSOLOGY_REPORTDIR}"

addtask do_fossology_create_tarball after do_patch do_preconfigure
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
