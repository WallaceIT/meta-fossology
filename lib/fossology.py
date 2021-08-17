#
# Fossology support functions and classes
#
# Copyright (C) 2021 Francesco Valla <valla.francesco@gmail.com>
#
# SPDX-License-Identifier: MIT
#

from typing import Optional, Union

import logging
import requests

logger = logging.getLogger("fossology")

class FossologyRetryAfter(Exception):
    """Exception raised when Fossology server replies Retry-After"""
    def __init__(self, time: int, message: str=""):
        self.time = time
        self.message = message
        super().__init__(self.message)


class FossologyInvalidParameter(Exception):
    """Exception raised when parameter validation fails"""
    def __init__(self, message: str=""):
        self.message = message
        super().__init__(self.message)


class FossologyJobFailure(Exception):
    """Exception raised when a job fails"""
    def __init__(self, job: int):
        self.job = job
        super().__init__()


class FossologyError(Exception):
    """Exception raised on error returned by server"""
    def __init__(self, code, message=""):
        self.code = code
        self.message = message
        super().__init__(self.message)


class FossologyServer:
    def __init__(self,url: str, token: str):
        self._url = url
        self._token = token

    @property
    def url(self):
        """Get server URL"""
        return self._url

    @property
    def token(self):
        """Get token used for server authentication"""
        return self._token

    def _api_get(self, api: str, headers: dict=None, params: dict=None, binary: bool=False) -> (int, Union[list,dict,None], int):
        all_headers = {'Authorization': 'Bearer %s' % self.token}
        if headers is not None:
            all_headers.update(headers)
        r = requests.get('%s/api/v1%s' % (self.url, api), headers=all_headers, params=params)
        try:
            if binary:
                results = r.content
            else:
                results = r.json()
        except requests.exceptions.JSONDecodeError:
            logger.error('Failed to decode JSON response')
            results = None
        logger.debug('GET %s -> %d' % (api, r.status_code))
        return (r.status_code, r.headers, results)

    def _api_post(self, api: str, headers: str=None, data=None, json: dict=None) -> (int, Union[list,dict,None], int):
        all_headers = {'Authorization': 'Bearer %s' % self.token}
        if headers is not None:
            all_headers.update(headers)
        r = requests.post('%s/api/v1%s' % (self.url, api), headers=all_headers, data=data, json=json)
        try:
            results = r.json()
        except requests.exceptions.JSONDecodeError:
            logger.error('Failed to decode JSON response')
            results = None
        logger.debug('POST %s -> %d' % (api, r.status_code))
        return (r.status_code, r.headers, results)

    def _api_delete(self, api: str, headers: str=None) -> (int, dict):
        all_headers = {'Authorization': 'Bearer %s' % self.token}
        if headers is not None:
            all_headers.update(headers)
        r = requests.delete('%s/api/v1%s' % (self.url, api), headers=all_headers)
        try:
            results = r.json()
        except requests.exceptions.JSONDecodeError:
            logger.error('Failed to decode JSON response')
            results = None
        logger.debug('DELETE %s -> %d' % (api, r.status_code))
        return (r.status_code, r.headers, results)

    def get_api_version(self):
        (code, headers, results) = self._api_get('/version')
        if code != 200:
            raise FossologyError(code, results.get("message", ""))
        return results["version"]

    def get_folder_id(self, name: str) -> Optional[int]:
        """Get ID for folder with given name"""
        (code, headers, results) = self._api_get('/folders')
        if code != 200:
            logger.error("Failed to get folder list")
            raise FossologyError(code, results.get("message", ""))
        for folder in filter(lambda f: f["name"] == name, results):
            folder_id = int(folder["id"])
            logger.debug(1, "Found folder %s with ID = %d" % (name, folder_id))
            return folder_id
        else:
            return None

    def get_upload_id(self, filename: str, folder_id: int) -> Optional[int]:
        """Get upload ID for given filename inside given folder"""
        page_num = 1
        while True:
            rq_headers = {
                'folderId' : str(folder_id),
                'page' : str(page_num),
            }
            (code, headers, results) = self._api_get('/uploads', headers=rq_headers)
            if code != 200:
                logger.error("Failed to get upload list")
                raise FossologyError(code, results.get("message", ""))
            for upload in filter(lambda u: u["uploadname"] == filename, results):
                upload_id = int(upload["id"])
                logger.debug(1, "Found upload %s with ID = %d" % (filename, upload_id))
                return upload_id
            if page_num < int(headers.get('X-Total-Pages', 1)):
                page_num += 1
            else:
                return None

    def upload(self, filepath: str, filename: str, folder_id: str, description: str="Uploaded by FossologyServer class") -> int:
        """Upload file"""
        from requests_toolbelt.multipart.encoder import MultipartEncoder
        with open(filepath, 'rb') as file:
            m = MultipartEncoder(fields={'fileInput': (filename, file, 'application/octet-stream')})
            rq_headers = {
                'folderId' : str(folder_id),
                'uploadDescription' : description,
                'public' : 'public',
                'Content-Type': m.content_type
            }
            (code, headers, results) = self._api_post('/uploads', headers=rq_headers, data=m)
            if code != 201:
                logger.warning('Upload failed with message: %s' % results.get("message", "None"))
                raise FossologyError(code, results.get("message", ""))
            return int(results["message"])

    def upload_delete(self, upload_id: int) -> bool:
        """Delete upload file(s)"""
        (code, headers, results) = self._api_delete('/uploads/%d' % (upload_id))
        return (code != 202)

    def upload_get_summary(self, upload_id: int) -> dict:
        """Get summary for given upload ID"""
        (code, headers, results) = self._api_get('/uploads/%d/summary' % (upload_id))
        if code == 503:
            retry_after = int(headers.get("Retry-After", 3))
            logger.info('Upload summary not yet available')
            raise FossologyRetryAfter(retry_after)
        elif code != 200:
            raise FossologyError(code, results.get("message", ""))
        return results

    def upload_get_licenses(self, upload_id: int, agents: list, get_containers: bool=False) -> dict:
        """Get license findings for given upload ID"""
        available_agents = [ "nomos", "monk", "ninka", "ojo", "reportImport", "reso" ]
        invalid_agents = [x for x in agents if x not in available_agents]
        if len(invalid_agents) > 0:
            raise FossologyInvalidParameter("Invalid agents for license findings: %s" % (','.join(invalid_agents)))
        params = {
            "agent" : ','.join(agents),
            "containers" : get_containers
        }
        (code, headers, results) = self._api_get('/uploads/%d/licenses' % upload_id, params=params)
        if code == 503:
            retry_after = int(headers.get("Retry-After", 3))
            logger.info('Upload licenses not yet available')
            raise FossologyRetryAfter(retry_after)
        elif code != 200:
            raise FossologyError(code, results.get("message", ""))
        return results

    def schedule_job(self, upload_id: int, folder_id: int, analysis: list, decider: list) -> int:
        """Schedule jobs for given upload ID"""
        available_analysis = [ "bucket", "copyright_email_author", "ecc", "keyword",
                             "mime", "monk", "nomos", "ojo", "package", "reso" ]
        available_decider = [ "nomos_monk", "bulk_reused", "new_scanner", "ojo_decider" ]
        invalid_analysis = [x for x in analysis if x not in available_analysis]
        if len(invalid_analysis) > 0:
            raise FossologyInvalidParameter("Invalid analysis for job: %s" % (','.join(invalid_analysis)))
        invalid_decider = [x for x in decider if x not in available_decider]
        if len(invalid_decider) > 0:
            raise FossologyInvalidParameter("Invalid decider for job: %s" % (','.join(invalid_decider)))
        rq_headers = {
            'folderId' : str(folder_id),
            'uploadId' : str(upload_id)
        }
        conf = {
            "analysis": { },
            "decider": { },
        }
        for a in analysis:
            conf["analysis"].update({ a : True })
        for d in decider:
            conf["decider"].update({ d : True })
        (code, headers, results) = self._api_post('/jobs', headers=rq_headers, json=conf)
        if code != 201:
            raise FossologyError(code, results.get("message", "None"))
        return int(results["message"])

    def job_completed(self, job_id: int) -> bool:
        """Check if job with given ID has been completed"""
        (code, headers, results) = self._api_get('/jobs/%d' % (job_id))
        if code != 200:
            raise FossologyError(results.get("message", ""))
        logger.debug("Job %d status: %s" % (job_id, results["status"]))
        if results["status"] == "Failed":
            raise FossologyJobFailure(job_id)
        return (results["status"] == "Completed")

    def report_trigger_generation(self, upload_id: int, report_format: str) -> int:
        """Trigger generation of report for given upload ID"""
        available_formats = [ "dep5", "spdx2", "spdx2tv", "readmeoss", "unifiedreport" ]
        if report_format not in available_formats:
            raise FossologyInvalidParameter("Invalid report format: %s" % (report_format))
        rq_headers = {
            'uploadId' : str(upload_id),
            'reportFormat' : report_format
        }
        (code, headers, results) = self._api_get('/report', headers=rq_headers)
        if code != 201:
            raise FossologyError(code, results.get("message", ""))
        report_id = int(results["message"].split('/')[-1])
        return report_id

    def download_report(self, report_id: int) -> bytes:
        """Download report having given ID"""
        (code, headers, results) = self._api_get('/report/%d' % (report_id), binary=True)
        if code == 503:
            logger.info('Report not yet ready')
            retry_after = int(headers.get("Retry-After", 3))
            raise FossologyRetryAfter(retry_after)
        elif code != 200:
            raise FossologyError(code, results.get("message", ""))
        return results
