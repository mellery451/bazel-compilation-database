#!/usr/bin/env bash

# Copyright 2017 GRAIL, Inc.
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

# Generates a compile_commands.json file at $(bazel info workspace) for
# libclang based tools.

# This is inspired from
# https://github.com/google/kythe/blob/master/tools/cpp/generate_compilation_database.sh

set -e
#set -x

source_dir=0
b_cmd="bazel"

usage() {
  printf "usage: %s flags\nwhere flags can be:\n" "${BASH_SOURCE[0]}"
  printf "\t-s\tuse the original source directory instead of bazel execroot\n"
  printf "\n"
}

while getopts "sdh" opt; do
  case "${opt}" in
    "s") source_dir=1 ;;
    "d") b_cmd="dazel" ;;
    "h") usage; exit 0;;
    *) >&2 echo "invalid option ${opt}"; exit 1;;
  esac
done
shift $((OPTIND -1))

# This function is copied from https://source.bazel.build/bazel/+/master:scripts/packages/bazel.sh.
# `readlink -f` that works on OSX too.
function get_realpath() {
	if [ "$(uname -s)" == "Darwin" ]; then
		local queue="$1"
		if [[ "${queue}" != /* ]] ; then
			# Make sure we start with an absolute path.
			queue="${PWD}/${queue}"
		fi
		local current=""
		while [ -n "${queue}" ]; do
			# Removing a trailing /.
			queue="${queue#/}"
			# Pull the first path segment off of queue.
			local segment="${queue%%/*}"
			# If this is the last segment.
			if [[ "${queue}" != */* ]] ; then
				segment="${queue}"
				queue=""
			else
				# Remove that first segment.
				queue="${queue#*/}"
			fi
			local link="${current}/${segment}"
			if [ -h "${link}" ] ; then
				link="$(readlink "${link}")"
				queue="${link}/${queue}"
				if [[ "${link}" == /* ]] ; then
					current=""
				fi
			else
				current="${link}"
			fi
		done

		echo "${current}"
	else
		readlink -f "$1"
	fi
}

readonly ASPECTS_DIR="$(dirname "$(get_realpath "${BASH_SOURCE[0]}")")"
readonly OUTPUT_GROUPS="compdb_files"
readonly BAZEL="${BAZEL_COMPDB_BAZEL_PATH:-bazel}"

readonly WORKSPACE="$(${b_cmd} info workspace 2>&1 | tail -1)"
readonly EXEC_ROOT="$(${b_cmd} info execution_root 2>&1 | tail -1)"
readonly BAZEL_BIN="$(${b_cmd} info bazel-bin 2>&1 | tail -1)"
readonly BAZEL_BIN_TRIM="$(echo ${BAZEL_BIN} | sed -E "s|$EXEC_ROOT/||")"
echo "BAZEL BIN:  $BAZEL_BIN_TRIM"
readonly COMPDB_FILE="${WORKSPACE}/compile_commands.json"

TARGETS=()
while read -r target ; do
    TARGETS+=(${target})
done < <( ${b_cmd} \
    query --noshow_progress --noshow_loading_progress \
    'kind("cc_(library|binary|test|inc_library|proto_library)", //...) union kind("objc_(library|binary|test)", //...)' 2>&1)
echo "NUM ELEMS: ${#TARGETS[*]}"

# Clean any previously generated files.
if [[ -e "${EXEC_ROOT}" ]]; then
  find "${EXEC_ROOT}" -name '*.compile_commands.json' -delete
fi

# shellcheck disable=SC2046
${b_cmd} build \
  "--override_repository=bazel_compdb=${ASPECTS_DIR}" \
  "--aspects=@bazel_compdb//:aspects.bzl%compilation_database_aspect" \
  "--noshow_progress" \
  "--noshow_loading_progress" \
  "--output_groups=${OUTPUT_GROUPS}" \
  "$@" > /dev/null
#  "$@" "${TARGETS[@]}" > /dev/null

echo "[" > "${COMPDB_FILE}"
while read -r found ; do
    size=$(cat $found | wc -l)
    if (( ${size} > 0 )) ; then
        cat "$found" >> "${COMPDB_FILE}"
        echo "," >> "${COMPDB_FILE}"
    fi
done < <(find "${EXEC_ROOT}" -name '*.compile_commands.json')
echo "]" >> "${COMPDB_FILE}"

# Remove the last occurence of a comma from the output file.
# This is necessary to produce valid JSON
sed -i.bak -e x -e '$ {s/,$//;p;x;}' -e 1d "${COMPDB_FILE}"

if (( source_dir )); then
  sed -i.bak -e "s|__EXEC_ROOT__|${WORKSPACE}|" "${COMPDB_FILE}"  # Replace exec_root marker
  # This is for libclang to help find source files from external repositories.
  ln -f -s "${EXEC_ROOT}/external" "${WORKSPACE}/external"
else
  sed -i.bak -e "s|__EXEC_ROOT__|${EXEC_ROOT}|" "${COMPDB_FILE}"  # Replace exec_root marker
  # This is for YCM to help find the DB when following generated files.
  # The file may be deleted by bazel on the next build.
  ln -f -s "${WORKSPACE}/${COMPDB_FILE}" "${EXEC_ROOT}/"
fi
sed -i.bak -e "s|-isysroot __BAZEL_XCODE_SDKROOT__||" "${COMPDB_FILE}"  # Replace -isysroot __BAZEL_XCODE_SDKROOT__ marker

sed -i.bak -e "s|-isysroot __BAZEL_XCODE_SDKROOT__||" "${COMPDB_FILE}"  # Replace -isysroot __BAZEL_XCODE_SDKROOT__ marker

if [[ $b_cmd == "dazel" ]] ; then
  sed -i.bak -E -e "s|bazel-out/.+/gcc_nvcc_wrapper|g++|g" "${COMPDB_FILE}"  # Replace gcc_nvcc with compiler
  TO_ELIM=(-fno-canonical-system-headers
           -Wno-free-nonheap-object
           -Wfree-nonheap-object
           -Wno-unused-but-set-parameter
           -Wunused-but-set-parameter
           -Wno-maybe-uninitialized
           -Wmaybe-uninitialized
           "-nvcc_options [^[:space:]]+"
           "${BAZEL_BIN_TRIM}/")
  for elim in  "${TO_ELIM[@]}" ; do
    sed -i.bak -E -e "s|$elim||g" "${COMPDB_FILE}"
  done

  # extract a comprehensive list of include paths
  # in the DB and then munge the ones that are invalid
  while read -r inc ; do
    inc=$(echo "${inc}" | sed -E -e "s|^[[:space:]]+||" | sed -E -e "s|[[:space:]]+$||")
    newinc=${inc}
    newinc=$(echo "${newinc}" | sed -E -e "s|^bazel-out/k8-[^/]+/bin/||")
    if echo "${newinc}" | grep -q -E "/_virtual_includes/" ; then
      newinc=$(echo "${newinc}" | sed -E -e "s|/_virtual_includes/.+||")
      if [[ -d "${newinc}/include" ]]; then
        moarinc="${newinc}/include"
        if [[ -d "${newinc}/src" ]]; then
          moarinc+=" -isystem ${newinc}/src"
        fi
        newinc="${moarinc}"
      elif [[ -d "${newinc}/src" ]]; then
        newinc+="/src"
      fi
    fi

    # custom hacks for some "installed" 3rdparty
    if echo "${newinc}" | grep -q "/gmock/install/" ; then
      newinc=$(echo "${newinc}" | sed -E -e "s|/gmock/install/|/googlemock/|")
    fi
    if echo "${newinc}" | grep -q "/gtest/install/" ; then
      newinc=$(echo "${newinc}" | sed -E -e "s|/gtest/install/|/googletest/|")
    fi
    if echo "${newinc}" | grep -q "/ion" ; then
        newinc="3rdparty/src/ion/pkg/ionc/inc -isystem 3rdparty/src/ion/pkg/ionc"
    fi
    if [[ "${newinc}" == "3rdparty/src/physfs/physfs/install/include" ]]; then
        newinc="3rdparty/src/physfs/include"
    fi
    if [[ "${newinc}" == "3rdparty/src/xsens/xsens/install/include" ]]; then
        newinc="3rdparty/src/xsens/include"
    fi
    #echo -e "   >>> turned [$inc]\\n    >>> into [$newinc]"
    if [[ "$newinc" != "$inc" ]]; then
      sed -i.bak -E -e "s|[[:space:]=]+${inc}[[:space:]=]+| ${newinc} |g" "${COMPDB_FILE}"
    fi
  done < <( \
    sed -E -e 's/(-I|-isystem|-iquote)[[:space:]=]+([^[:space:]]+)/\n\1 \2\n/g' "${COMPDB_FILE}" \
    | grep -E '(-I|-isystem|-iquote) ' \
    | sed -E -e 's/(-I|-isystem|-iquote) (.+)/\2/g' \
    | sort | uniq)
  ## ^^^ this matching has to be revisited if we have any paths with spaces

  while read -r inc ; do
    if [[ ! -d $inc ]]; then
      echo "WARN: might need a manual substition for $inc (which does not exist)"
    fi
  done < <( \
    sed -E -e 's/(-I|-isystem|-iquote)[[:space:]=]+([^[:space:]]+)/\n\1 \2\n/g' "${COMPDB_FILE}" \
    | grep -E '(-I|-isystem|-iquote) ' \
    | sed -E -e 's/(-I|-isystem|-iquote) (.+)/\2/g' \
    | sort | uniq)

  gendir="$PWD/build/_gen"
  add_includes=""
  #  while read -r inc; do
  #      add_includes+=" -isystem $inc"
  #  done < <(find 3rdparty/src 3rdparty/shared -name include)
  add_includes+=" -I src"
  add_includes+=" -isystem /usr/local/cuda/include"
  add_includes+=" -isystem $gendir"
  while read -r inc ; do
    add_includes+=" -I $inc"
  done < <(ls -d src/dwshared/*/)
  #  sed -i.bak -E -e "s|-isystem 3rdparty/[^[:space:]]+/install/[^[:space:]]+ ||g" "${COMPDB_FILE}"
  sed -i.bak -E -e "s|(.*) -isystem |\\1 $add_includes -isystem |" "${COMPDB_FILE}"

  # TODO -- these all need to come from the actual build/config (generated headers)
  mkdir -p "$gendir/dw/core"
  echo "#define DW_RUNTIME_CHECKS() 1" > $gendir/dw/core/ConfigChecks.h
  echo -e "#ifndef DW_CORE_CONFIG_H__\\n#define LINUX\\n#define DW_USE_NVMEDIA_X86\\n#define DW_USE_NVSIPL\\n#define DW_USE_OPENDDS\\n#endif\\n" > $gendir/dw/core/Config.h
  echo -e "#ifndef DW_CORE_CONFIG3RDPARTY_HPP__\\n#define DW_USE_OPENCV\\n#define DW_USE_HERE\\n#define TRT_VERSION_DECIMAL 6000011\\n#define NVDLA_VERSION_DECIMAL 10400\\n#define NVMEDIA_VERSION_DECIMAL 14\\n#endif\\n" > $gendir/dw/core/Config3rdParty.hpp
  echo -e "#ifndef DW_CORE_VERSIONCURRENT_H_\\n#include <dw/core/Version.h>\\n#define DW_VERSION dwVersion{3,0,-1,\"nil\",\"-exp\"}\\n#endif\\n" > $gendir/dw/core/VersionCurrent.h
  echo -e "#ifndef DW_CORE_VERSION_EXTRA_HPP__\\n#define DW_SDK_VERSION_GIT_DESCRIPTION \"none\"\\n#define DW_SDK_BUILD_COMPILER_STRING \"GNU\"\\n#define DW_SDK_BUILD_TYPE \"Debug\"\\n#endif\\n" > $gendir/dw/core/VersionExtra.hpp
fi

# Clean up backup file left behind by sed.
rm "${COMPDB_FILE}.bak"
