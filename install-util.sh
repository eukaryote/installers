# Utility functions for use by Bash installer scripts.

# Echo params to stderr and return with status of last command
# executed before this function was invoked.
err() {
    local -r rc=$?
    >&2 echo "$@"
    return $rc
}

# Join args by delimiter given as 1st param.
join_by() {
    local IFS="${1:?a delimiter parameter is required}"
    shift
    echo "$*"
}

# Verify path $1 is a directory, echoing to stderr an error message if not
# and returning a non-zero status.
verify_dir() {
    local -r dirpath=${1:?dirpath parameter is required}
    [[ -d "${dirpath}" ]] ||
        err " - dirpath ${dirpath} is not a directory" ||
        return
}

# Change into the directory given as the first param, failing with a helpful
# error message if unable to cd successfully or if multiple args are passed.
change_dir() {
    local -r dirpath=${1:?directory path parameter is required}
    verify_dir "${dirpath}" || return

    shift
    [[ -z "$*" ]] ||
        err "change_dir only accepts one arg" ||
        return

    cd "${dirpath}" || return
}

# Get core_count, using '1' if not able to detect OS type
core_count() {
    if [[ -z "${OSTYPE:-}" ]]
    then
        # OSTYPE is a predefined Bash variable, so should be available,
        # but use core count of 1 if not defined rather than failing
        echo -n 1
        return 0
    fi
    case $OSTYPE in
        darwin*)
            command sysctl -n machdep.cpu.core_count | tr -d -C '[:digit:]' ;;
        *)
            command grep -c -E '^processor\s*:' < /proc/cpuinfo ;;
    esac
}

# Run a build command with minimal environment, limited to
# LANG, LANGUAGE, and a minimal PATH containing just /usr/bin and /bin,
# and echoing the exact command to be executed before executing it.
run_clean() {
    local -r language="${LANGUAGE:-en_US}"
    local -r lang="${LANG:-${language}.UTF-8}"

    echo command env -i PATH=/usr/bin:/bin LANGUAGE="${language}" LANG="${lang}" "$@"
    command env -i PATH=/usr/bin:/bin LANGUAGE="${language}" LANG="${lang}" "$@"
}

# Get the path to the preferred python executable.
#
# This returns the first found path of "${PYTHON_BASE}/default/bin/python3" or
# "${PYTHON_BASE}/default/bin/python", and if neither is present, uses the
# first of $(which python3) and $(which python) that is found.
get_python() {
    local exe

    for binary in python3 python
    do
        exe="${PYBASE:-/opt/python}/default/bin/${binary}"
        [[ -e "${exe}" ]] && {
            if "${exe}" -V >/dev/null 2>&1
            then
                echo -n "${exe}"
                return 0
            fi
        }
    done

    for binary in python3 python
    do
        exe=$(which ${binary} 2>/dev/null) && {
            if "${exe}" -V >/dev/null 2>&1
            then
                echo -n "${exe}"
                return 0
            fi
        }
    done

    return 1
}


# Get the lib/pythonX.X for the Python executable given as path.
get_python_lib_dir() {
    local -r exe="${1:?path to a python executable is required}"
    local -r pyconfig="${exe}-config"

    if [[ ! -x "${exe}" ]]
    then
        err "'${exe}' is not a Python executable"
        return 1
    fi

    local prefix
    prefix=$("${pyconfig}" --prefix) ||
        err "ERROR: '${pyconfig} --prefix' failed" ||
        return 1

    local major_dot_minor
    major_dot_minor=$("${exe}" --version 2>&1 | \
        command tail -n 1 | \
        command grep -E -o '(\.|[[:digit:]])+' | \
        command tr -d '\s' | \
        command grep -E -o '[[:digit:]]+\.[[:digit:]]+' \
    ) || {
        err "ERROR: couldn't determine Python lib dir"
        return 1
    }
    local -r libdir="${prefix}/lib/python${major_dot_minor}"

    if [[ ! -d "${libdir}" ]]
    then
        err "ERROR: expected Python lib dir '${libdir}' not found"
        return 1
    fi
    echo -n "${libdir}"
}

# Check success of stage just completed, and on failure, show log
# info and return with the original status.
# The first param should be a stage (configure, compile, install, or
# install_pip), the second param should be the build directory,
# and the third param should be the status code of the stage.
stage_complete() {
    local -r stage=${1:?stage parameter is required}
    local -r build_dir=${2:?build_dir parameter is required}
    local -r complete_status=${3:?complete_status parameter is required}

    if [[ ${complete_status} != 0 ]]
    then
        echo " - failed with code ${complete_status}:"
        tail "${build_dir}/${stage}.log"
        echo
        echo "See ${build_dir}/${stage}.log for more info"
    fi
    return "${complete_status}"
}

# Extract the basename from a package path (e.g., 'myfile' for
# 'myfile.tar.gz' or '/a/myfile.tbz2').
basename_from_package() {
    local -r packagepath=${1:?packagepath is required}
    [[ -z "${2:-}" ]] || {
        err "usage: basename_from_package PKGPATH"
        return 1
    }

    local name=$(basename "${packagepath}") || return
    sed -r -e 's/\.tar$//g' -e 's/\.(tar\.|t)(gz|bz2|xz)$//g' <<<"${name}"
}

# Extract basename of URL (last path segment), ignoring query string if present.
basename_from_url() {
    local -r url="${1:?url is required}"
    [[ -z "${2:-}" ]] || {
        err "usage: basename_from_url PKGPATH"
        return 1
    }
    basename "${url/%\?*/}"
}

# Unpack the downloaded source package in the same directory that contains
# the tarball and which should be given as the first param
# the package as the first param, and the version as second param.
# The tar packaged
unpack() {
    local -r tarpath=${1:?tarpath parameter is required}
    [[ -f "${tarpath}" ]] ||
        err "invalid path to package: ${tarpath}" ||
        return

    local parentdir
    parentdir=$(dirname "${tarpath}") || return

    echo -n " - unpacking"
    change_dir "${parentdir}" || return

    local unpack_status
    tar xf "${tarpath}" ||
        err " - failed with status ${unpack_status} to unpack package: ${tarpath}" ||
        return
}

# Return whether Python configure script in current working directory
# supports the option passed as the first parameter.
has_configure_opt() {
    local -r opt=${1:?opt parameter is required}
    ./configure --help=short | command grep -- "${opt}" >/dev/null 2>&1
}

# Evaluate to non-zero if there is a broken symlink at path provided
# by the first param, which is required.
is_broken_symlink() {
    local filepath=${1:?filepath parameter is required}
    [[ -L "${filepath}" ]] && [[ ! -a "${filepath}" ]]
}

# Add a 'default' symlink to the directory named $2 inside the basedir $1
# if there is not already a 'default' file in that directory.
add_default_symlink() {
    local basedir=${1:?basedir parameter is required}
    local version=${2:?version parameter is required}

    local -r dest="${basedir}/default"

    # If 'default' exists and is a symlink, update it iff NO_UPDATE var not set
    if [[ -L "${dest}" ]]
    then
        if [[ "${DEFAULT_SYMLINK_NO_UPDATE:0}" != "1" ]]
        then
            ln -sfn "${version}" "${basedir}/default"
        fi
        return
    fi

    # If 'default' exists and is not a symlink, update it if NO_UPDATE not set
    if [[ -e "${dest}" ]]
    then
        if [[ "${DEFAULT_SYMLINK_NO_UPDATE:0}" != "1" ]]
        then
            ln -sfn "${version}" "${basedir}/default"
        fi
        return
    fi

    # If 'default' doesn't exist at all, create it unless NO_CREATE not set
    if [[ "${DEFAULT_SYMLINK_NO_CREATE:0}" != "1" ]]
    then
        ln -sfn "${version}" "${basedir}/default"
    fi
}

# Check that gpg2 is installed.
check_gpg() {
    which gpg2 >/dev/null 2>&1 ||
        err "gpg2 not found"
}

# GPG verify the signature $1 for the package $2.
gpg_verify() {
    local -r signature=${1:?signature parameter is required}
    local -r package=${2:?package parameter is required}

    check_gpg || return

    command gpg2 --verify "${signature}" "${package}" >/dev/null 2>&1 ||
        err "GPG verification of package ${package} with signature ${signature} failed with status $?" ||
        return
}

# Download into the directory $1 the URLs given as the remaining parameters.
# This uses curl and the '--output' param, which uses the last part
# of the URL as the downloaded file name.
download() {
    local -r download_dir=${1:?download_dir parameter is required}
    change_dir "${download_dir}" || return

    shift
    for url in "$@"
    do
        command curl --fail --fail-early -L -s -O "${url}" || {
            local -r rc=$?
            true
            err " - curl failed to download file [status ${rc}]:"
            err "   - ${url}"
            return $rc
        }
    done
    return 0
}

# Download file and GPG signature given as the first and second parameters,
# respectively, and verify the signature using gpg2. An optional third
# parameter may be supplied to provide a directory path to cd into and
# save the files to. If not provided, the current working directory is used.
#
# The URLs will be  downloaded using cURL and the --output/-o option that
# saves the file using the last part of the URL as the filename, so the URLs
# must be in a # suitable format such that the saved files will have different
# names that are extractable using 'basename' on the URL.
download_and_verify() {
    local -r package=${1:?package parameter is required}
    local -r signature=${2:?signature parameter is required}

    local -r download_dir=${3:-.}

    if [[ "${download_dir}" != "." ]]
    then
        change_dir "${download_dir}" || return
    fi

    download "${download_dir}" "${signature}" "${package}" || return
    gpg_verify "$(basename "${signature}")" "$(basename ${package})" || return
}

# Get the latest tag for Git repo dir provided as param 1 by using
# 'git tag -l' and an optional prefix regex provided as param 2,
# using 'sort -V' to determine the latest version number.
get_latest_tag() {
    local repo="${1:?repo directory is required}"
    local prefix="${2:-.}"
    local tag

    tag=$(cd "${repo}" && command git tag -l | \
        command grep -E "^${prefix}" | \
        command sort -V | \
        command tail -n 1 \
    ) || {
        err "ERROR: couldn't list tags for repo: ${repo}"
        return 1
    }

    [[ -n "${tag}" ]] ||
        err "ERROR: couldn't determine latest tag for repo: ${repo}" ||
        return 1

    echo -n "${tag}"
}

# Create a download directory for the current host, if it doesn't already
# exist, and echo the full path to the directory.
make_download_dir() {
    local package_name="${1:?package_name is required}"

    local -r dirpath="${TMPDIR}/installers/${package_name}"

    if [[ -e "${dirpath}" ]]
    then
        verify_private_dir "${dirpath}" || return

        echo -n "${dirpath}"
        return 0
    fi

    mkdir -p -m 700 "${dirpath}" || return
    echo -n "${dirpath}"
}

# Verify each directory given as a param exists and has 0700 perms and is
# owned by the current user. At least 1 directory is required.
verify_private_dir() {
    if [[ -z "$*" ]]
    then
        err "ERROR: verify_private_dir requires at least one directory path to check"
        return 1
    fi

    local me
    me=$(whoami) || return

    local dirpath
    for dirpath in "$@"
    do
        if ! command ls -ld "${dirpath}" | command grep -E "^drwx------ [0-9]+ ${me} " > /dev/null 2>&1
        then
            err "directory '${dirpath}' should have perms 0700 and be owned by user '${me}'"
            return 1
        fi
    done

    return 0
}

# Verify (detached) GPG signature file ($1) for file ($2).
gpg_verify() {
    local -r sigpath=${1:?sigpath is required}
    local -r filepath=${2:?filepath is required}

    [[ -f "${sigpath}" ]] ||
        err "ERROR: signature file '${sigpath}' does not exist or is not a regular file" ||
        return 1

    [[ -f "${filepath}" ]] ||
        err "ERROR: file '${sigpath}' does not exist or is not a regular file" ||
        return 1

    command gpg -q --verify "${sigpath}" "${filepath}" >/dev/null 2>&1 || {
        err "ERROR: gpg verification failed [gpg --verify '${sigpath}' '${filepath}']"
        err "Import the relevant public key, if necessary, and run the command manually to view the error messages"
        return 1
    }
}
