#!/usr/bin/env python
# Copyright 2019 Nokia
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# pylint: disable=too-many-instance-attributes,too-many-arguments

import argparse
import copy
import sys
import logging
import re
import json
from pprint import pformat

import os

from tools.rpm import RpmInfoParser
from tools.utils import apply_jenkins_auth
from tools.yum import Yum, YumInfoParser
from tools.repository import RepositoryConfig
from tools.log import set_logging
from tools.io import read_from, write_to, read_json
from tools.convert import to_json, CsvConverter


class RpmDataBuilder(object):
    def __init__(self, build_config, yum_info_installed, rpm_info_installed,
                 crypto_info_installed, boms, remote=False):
        self.remote = remote
        self.yum_info_installed = yum_info_installed
        self.rpm_info_installed = rpm_info_installed
        self.crypto_info_installed = json.loads(crypto_info_installed)
        self.boms = boms
        logging.debug('BOMS: {}'.format(pformat(self.boms)))
        self.repoconfig = RepositoryConfig(build_config)
        self.installed_rpms = None
        self.repos = None

    def run(self):
        self.installed_rpms = self.read_installed_rpms()
        srpms = set([rpm['Source RPM'] for rpm in self.installed_rpms])
        logging.info('Installed RPMs:{} SRPMs:{}'.format(len(self.installed_rpms), len(srpms)))
        self.repos = self._read_configured_repos()
        logging.info('Configured repos: {}'.format(len(self.repos)))
        available_rpms = self._read_available_rpms(self.repos)
        logging.info('Found {} available RPMs in binary repos'.format(
            len([rpm for repo_rpms in available_rpms.values() for rpm in repo_rpms])))
        for i_rpm in self.installed_rpms:
            i_rpm_repo_name = self._get_rpm_available_in(i_rpm, available_rpms)
            i_rpm['Repo data'] = self._get_repo(i_rpm_repo_name)
            i_rpm['Obsoletes'] = self._resolve_obsoletes(i_rpm)
            i_rpm['Crypto capable'] = self._resolve_ecc(str(i_rpm))
            i_rpm['BOM'] = self._resolve_bom(i_rpm)
        self._log_repo_rpm_statistics()
        self._log_rpm_statistics()
        return self.installed_rpms

    @staticmethod
    def _resolve_obsoletes(rpm):
        if 'Obsoletes' not in rpm:
            return 'N/A'
        elif rpm['Obsoletes'] == '(none)':
            return 'N/A'
        return rpm['Obsoletes']

    def _resolve_ecc(self, rpm):
        for item in self.crypto_info_installed:
            if item['name'] == rpm:
                return True
        return False

    def _resolve_bom(self, rpm):
        bom_content = self.boms.get(str(rpm))
        if bom_content is None:
            return ''
        self._validate_bom(str(rpm), bom_content)
        return bom_content['bom']

    @staticmethod
    def _validate_bom(rpm_name, bom_content):
        try:
            if 'bom' not in bom_content:
                raise Exception('BOM base object "bom" missing')
            bom = bom_content['bom']
            for material in bom:
                for key in ['name', 'version', 'source-url', 'foss']:
                    if key not in material:
                        raise Exception('Key "{}" not found in BOM'.format(key))
                if material['foss'].lower() not in ['yes', 'no', 'modified']:
                    raise Exception('BOM foss value not valid')
            missing_crypto_count = len([material for material in bom if
                                        'crypto-capable' not in material])
            if missing_crypto_count != 0:
                logging.warning(
                    'crypto-capable missing from %s materials in RPM %s',
                    missing_crypto_count, rpm_name)
        except Exception as e:
            correct_format = {'bom': [
                {'name': '<component-name>',
                 'version': '<component-version>',
                 'source-url': '<source-url>',
                 'foss': '<yes/no/modified>',
                 'crypto-capable': '<true/false (OPTIONAL)>'}]}
            msg_fmt = 'BOM for {rpm} is not correct format. {error}:\n{correct_format}'
            raise Exception(msg_fmt.format(rpm=rpm_name,
                                           error=str(e),
                                           correct_format=pformat(correct_format)))

    def _get_repo(self, name):
        for r in self.repos:
            if r['name'] == name:
                return r
        raise Exception('No repository found with name: {}'.format(name))

    def read_installed_rpms(self):
        installed_rpms = []
        yum_rpms = YumInfoParser().parse_installed(self.yum_info_installed)
        rpm_rpms = RpmInfoParser().parse_multiple(self.rpm_info_installed)
        self._validate_rpm_lists_identical(yum_rpms, rpm_rpms)
        yum_rpms_dict = {rpm['Name']: rpm for rpm in yum_rpms}
        for rpm_data in rpm_rpms:
            yum_data = yum_rpms_dict[rpm_data['Name']]
            combined_data = self._combine_rpm_data(rpm_data, yum_data)
            installed_rpms.append(combined_data)
        logging.debug('One parsed RPM data as example:\n{}'.format(pformat(installed_rpms[0])))
        return installed_rpms

    def _combine_rpm_data(self, rpm_data, yum_data):
        combined_data = copy.deepcopy(rpm_data)
        fields_known_to_differ = ['Description',  # May contain deffering newline and indentation
                                  'Size']  # Bytes in RPM, humanreadable in yum
        yum2rpm_field_name_map = {'Arch': 'Architecture'}
        for yum_key in yum_data:
            if yum_key in yum2rpm_field_name_map:
                rpm_key = yum2rpm_field_name_map[yum_key]
            else:
                rpm_key = yum_key
            if rpm_key in combined_data:
                yum_comparable_rpm_string = self._rpm_info_str_to_yum_info_str(
                    combined_data[rpm_key])
                if yum_comparable_rpm_string != yum_data[yum_key]:
                    if rpm_key in fields_known_to_differ:
                        continue
                    raise Exception(
                        'RPM data in "{}" not match in rpm "{}" vs yum "{}" for package {}'.format(
                            rpm_key,
                            repr(combined_data[rpm_key]),
                            repr(yum_data[yum_key]),
                            combined_data))
            else:
                combined_data[rpm_key] = yum_data[yum_key]
        return combined_data

    @staticmethod
    def _rpm_info_str_to_yum_info_str(string):
        try:
            string.decode()
        except (UnicodeEncodeError, UnicodeDecodeError):
            return re.sub(r'[^\x00-\x7F]+', '?', string)
        except Exception as e:
            logging.error('{}: for string {}'.format(str(e), repr(string)))
            raise
        return string

    @staticmethod
    def _validate_rpm_lists_identical(yum_rpms, rpm_rpms):
        yum_rpms_dict = {rpm['Name']: rpm for rpm in yum_rpms}
        rpm_rpms_dict = {rpm['Name']: rpm for rpm in rpm_rpms}
        if len(yum_rpms) != len(rpm_rpms):
            raise Exception(
                'Given RPM lists are unequal: yum RPM count {} != rpm RPM count {}'.format(
                    len(yum_rpms), len(rpm_rpms)))
        assert sorted(yum_rpms_dict.keys()) == sorted(rpm_rpms_dict.keys())
        for name in yum_rpms_dict.keys():
            if not yum_rpms_dict[name].is_same_package_as(rpm_rpms_dict[name]):
                raise Exception(
                    'Packages are not same: yum {} != rpm {}'.format(yum_rpms_dict[name],
                                                                     rpm_rpms_dict[name]))

    def _read_configured_repos(self):
        repos = self.repoconfig.read_sections(
            ['baseimage-repositories', 'repositories'])
        if 'BUILD_URL' in os.environ:
            repos.append(self.repoconfig.get_localrepo(remote=True))
        else:
            repos.append(self.repoconfig.get_localrepo(remote=False))
        logging.debug('Configured repos: {}'.format(pformat(repos)))
        return repos

    def _read_available_rpms(self, repos):
        Yum.clean_and_remove_cache()
        yum = Yum()
        for repo in repos:
            name = repo['name']
            if name == 'localrepo':
                if self.remote:
                    url = self.repoconfig.get_localrepo(remote=True)['baseurl']
                    yum.add_repo(name, apply_jenkins_auth(url))
                else:
                    url = self.repoconfig.get_localrepo(remote=False)['baseurl']
                    yum.add_repo(name, url)
            else:
                yum.add_repo(name, repo['baseurl'])
        yum_available_output = yum.read_all_packages()
        available_rpms = YumInfoParser().parse_available(yum_available_output)
        rpms_per_repo = {}
        for rpm in available_rpms:
            repo = rpm.get('Repo')
            if repo not in rpms_per_repo:
                rpms_per_repo[repo] = []
            rpms_per_repo[repo].append(rpm)
        return rpms_per_repo

    def _log_repo_rpm_statistics(self):
        logging.info('--- RPM repo statistics ---')
        for repo in self.repos:
            name = repo['name']
            repo_url = repo['baseurl']
            if name in [r['name'] for r in self._get_nonerepos()]:
                expected_from_repo = None
            else:
                expected_from_repo = name
            repo_installed_rpm_count = len([rpm for rpm in self.installed_rpms if
                                            rpm['Repo data']['baseurl'] == repo_url and rpm.get(
                                                'From repo') == expected_from_repo])
            logging.info(
                'RPMs installed from repo "{}": {}'.format(name, repo_installed_rpm_count))
            if repo_installed_rpm_count is 0:
                logging.warning(
                    'Repository configured but no RPMs installed: {}={}'.format(name, repo_url))

        return self.installed_rpms

    def _log_rpm_statistics(self):
        def _get_count(func):
            return len([rpm for rpm in self.installed_rpms if func(rpm)])

        logging.info('----- RPMs per type -----')
        logging.info(' => Total: %s', len(self.installed_rpms))
        logging.info('----- RPMs per attribute -----')
        logging.info(' * Crypto capable: %s', _get_count(lambda rpm: rpm['Crypto capable']))
        logging.info(' * Complex (BOM): %s', _get_count(lambda rpm: rpm['BOM']))

    def _get_rpm_available_in(self, rpm, available_rpms):
        if 'From repo' in rpm.keys():
            if rpm['From repo'] == 'localrepo':
                return 'localrepo'
            if rpm['From repo'] == 'anaconda':
                return 'localrepo'
            available_repo_rpms = available_rpms[rpm['From repo']]
            for a_rpm in available_repo_rpms:
                if self._is_same_rpm(a_rpm, rpm):
                    return rpm['From repo']
            rpms_in_matching_repo = [str(a_rpm) for a_rpm in available_repo_rpms]
            rpms_with_matching_name = [str(a_rpm) for a_rpm in available_repo_rpms if
                                       rpm['Name'] == a_rpm['Name']]
            if len(rpms_in_matching_repo) <= 1000:
                logging.debug(
                    'Available RPMs in {}: {}'.format(rpm['From repo'], rpms_in_matching_repo))
            error_str = 'RPM "{}" is not available in configured repo: {}, ' \
                        'RPMs with correct name: {}'.format(str(rpm), rpm['From repo'],
                                                            rpms_with_matching_name)
            raise Exception(error_str)
        else:
            none_repos = self._get_nonerepos()
            for repo in [r['name'] for r in none_repos]:
                for a_rpm in available_rpms[repo]:
                    if self._is_same_rpm(a_rpm, rpm):
                        return repo
            msg = 'RPM "{}" is not available in any configured "none*" repos: {}'.format(
                rpm['Name'], none_repos)
            raise Exception(msg)

    def _get_nonerepos(self):
        return [repo for repo in self.repos if re.match(r'^none\d+$', repo['name'])]

    @staticmethod
    def _is_same_rpm(rpm1, rpm2):
        return rpm1['Name'] == rpm2['Name'] and \
               rpm1['Version'] == rpm2['Version'] and \
               rpm1['Release'] == rpm2['Release'] and \
               rpm1['Arch'] == rpm2['Architecture']


def parse(args):
    p = argparse.ArgumentParser(
        description='Generate package info',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    p.add_argument('--verbose', '-v', action='store_true',
                   help='More verbose logging')
    p.add_argument('--yum-info-path', required=True,
                   help='"yum info all" output as file')
    p.add_argument('--rpm-info-path', required=True,
                   help='"rpm -qai" output as file')
    p.add_argument('--crypto-info-path',
                   help='Dir from where to find ECC file')
    p.add_argument('--boms-path',
                   help='Dir from where to find RPM bill of material files')
    p.add_argument('--output-rpmlist',
                   help='output as rpm list like "rpm-qa"')
    p.add_argument('--output-json',
                   help='output json file path')
    p.add_argument('--output-csv',
                   help='output csv file path')
    p.add_argument('--output-ms-csv',
                   help='output Microsoft Excel compatible csv file path')
    p.add_argument('--build-config-path', required=True,
                   help='Build configuration ini path')
    p.add_argument('--remote', action='store_true',
                   help='Read localrepo from remote defined by BUILD_URL, '
                        'otherwise use localrepo from WORKSPACE')
    args = p.parse_args(args)
    return args


def read_files(boms_dir):
    boms = {}
    for f in os.listdir(boms_dir):
        boms[f] = read_json(boms_dir + '/' + f)
    return boms


def main(input_args):
    args = parse(input_args)
    if args.verbose:
        set_logging(debug=True, timestamps=True)
    else:
        set_logging(debug=False)
    rpmdata = RpmDataBuilder(args.build_config_path,
                             read_from(args.yum_info_path),
                             read_from(args.rpm_info_path),
                             read_from(args.crypto_info_path),
                             read_files(args.boms_path),
                             remote=args.remote).run()
    if args.output_rpmlist:
        write_to(args.output_rpmlist, '\n'.join(sorted([str(rpm) for rpm in rpmdata])))
    if args.output_json:
        write_to(args.output_json, to_json(rpmdata))
    csv = CsvConverter(rpmdata, preferred_field_order=['Name', 'Version', 'Release',
                                                       'License', 'Vendor', 'From repo',
                                                       'Source RPM'])
    if args.output_csv:
        write_to(args.output_csv, str(csv))
    if args.output_ms_csv:
        write_to(args.output_ms_csv,
                 csv.convert_to_ms_excel(text_fields=['Version', 'Size', 'Release']))
    if not args.output_json and not args.output_csv:
        print(rpmdata)


if __name__ == "__main__":
    main(sys.argv[1:])
