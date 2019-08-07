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

import ConfigParser
import platform

from tools.statics import BUILD_CONFIG_PATH


def optionxform_arch(option):
    return str(option).replace('#ARCH#', platform.machine())


class BuildConfigParser(ConfigParser.ConfigParser):
    def __init__(self, ini_file=BUILD_CONFIG_PATH):
        ConfigParser.ConfigParser.__init__(self)
        self.ini_file = ini_file
        self.optionxform = optionxform_arch
        self.read(self.ini_file)

    def items(self, section):  # pylint: disable=arguments-differ
        defaults = self.defaults()
        resultlist = []
        for item in ConfigParser.ConfigParser.items(self, section):
            if item[0] not in defaults:
                resultlist.append(item)
        return resultlist
