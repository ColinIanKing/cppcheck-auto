#!/bin/bash 

#
# Copyright (C) 2012-2015 Canonical
#   
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#

#
# Author Colin Ian King,  colin.king@canonical.com
#
if [ -z "$USER" ]; then
	USER=cking
fi
ROOT_DIR=/home/${USER}/cppcheck
#
#  cppcheck 
#
CPPCHECK_DIR=tools/cppcheck
CPPCHECK_REPO=https://github.com/danmar/cppcheck.git

#
#  Specify where we keep the linux repos
#
LINUX_SRC_DIR=src

#
#  Where were keep the cppcheck logs 
#
BUILD_LOG_DIR=build-log

#
#  Where to copy the data to
#
RSYNC_COPY_TO=cking@zinc.canonical.com:public_html/cppcheck/kernel

#
#  Default tag, empty means get latest
#
TAG=

releases=( \
        [0]=linux)

kernel_repos=( \
	[0]="git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux")

kernel_branches=( \
	[0]="master")

repo_clone()
{
	repo=$1
	dest=$2
	echo "Cloning $repo to $dest"
	git clone $repo $dest
	ret=$?
	[ $ret -eq 0 ] && echo "Clone succeeded" || echo "Clone failed"
	return $?
}

repo_update()
{
	dest=$1
	echo "Updating $dest"
	here=$(pwd)
	cd ${dest}
	git checkout -f master >& /dev/null
	git fetch origin >& /dev/null
	git fetch origin master	>& /dev/null
	git reset --hard FETCH_HEAD >& /dev/null
	cd ${here}
}

repo_get()
{
	repo=$1
	dest=$2
	branch=$3

	if [ -d ${dest} ]; then
		repo_update ${dest} ${branch}
	else
		repo_clone ${repo} ${dest}
		repo_update ${dest} ${branch}
	fi
}

cppcheck_remove()
{
	rm -rf ${CPPCHECK_DIR}
}

cppcheck_save()
{
	mv ${CPPCHECK_DIR} ${CPPCHECK_DIR}.save
}

cppcheck_get()
{
	repo_get ${CPPCHECK_REPO} ${CPPCHECK_DIR} master
}

cppcheck_clean()
{
	echo "Cleaning cppcheck.."
	here=$(pwd)
	cd ${CPPCHECK_DIR}
	make clean >& /dev/null
	cd ${here}
}

cppcheck_build()
{
	echo "Building cppcheck.."

	here=$(pwd)
	cd ${CPPCHECK_DIR}
	make -j 6 >& /dev/null
	if [ $? -eq 0 ]; then
		echo "Build succeeded"
		rm -rf ${here}/${CPPCHECK_DIR}.built_ok
		cp -rp ${here}/${CPPCHECK_DIR} ${here}/${CPPCHECK_DIR}.built_ok
	else
		if [ -d ${here}/${CPPCHECK_DIR}.built_ok ]; then
			echo "Build failed, using previous working version"
			cd ${here}
			rm -rf ${CPPCHECK_DIR}
			cp -rp ${CPPCHECK_DIR}.built_ok ${CPPCHECK_DIR}
		else
			echo "Build failed, no previous version of cppcheck either"
			exit 1
		fi
		
	fi
	cd ${here}
}

#
#  Get latest cppcheck and build it
#
cppcheck_prepare()
{
	cppcheck_get
	cppcheck_clean
	cppcheck_build
}

#
#  Rsync the cppcheck results
#
kernel_build_logs_rsync()
{
	echo "Rsyncing.."
	rsync -t -r -e ssh build-log ${RSYNC_COPY_TO}
	if [ $? -eq 0 ] ; then
		echo "Rsync succeeded!"
	else
		echo "Rsync failed!"
	fi
}

#
#  Find previous version to the one specified
#
kernel_log_previous()
{
	current_ver=$1

	found=0
	prev=""

	for ver in $(ls -1 -r)
	do	
		if [ ${found} -eq 1 ]; then
			if [ -e ${ver}/*warning.log ]; then
				prev=${ver}
				found=2
			fi
		else
			if [ x${ver} == x${current_ver} ]; then
				found=1
			fi
		fi
	done

	echo "${prev}"
}

#
#  Find cppcheck log differences
#
kernel_log_diff()
{
	which_log=$2

	current_ver=${1}
	current_log=${current_ver}/${current_ver}-build-${which_log}.log

	previous_ver=$(kernel_log_previous $current_ver)
	previous_log=${previous_ver}/${previous_ver}-build-${which_log}.log

	if [ -z ${previous_ver} ]; then
		echo "No previous version found, can't calculate delta."
	else
		sed s/:[0-9]*// ${current_log} > /tmp/current-log-$$
		sed s/:[0-9]*// ${previous_log} > /tmp/previous-log-$$
		#
		#  What is in current log that is not in the previous log?
		#
		echo "Fixed ${which_log} messages between ${current_ver} and ${previous_ver}:"
		n=0
		cat /tmp/current-log-$$ | while IFS='' read -r line || [[ -n $line ]]
		do
			n=$((n+1))
        		if [ $(grep -F "$line" /tmp/previous-log-$$ | wc -l) -eq 0 ]
			then
				sed "${n}q;d" ${current_log}
			fi
		done
		echo ""
		#
		#  What is in previous log that is not in the current log?
		#
		echo "New ${which_log} messages between ${current_ver} and ${previous_ver}:"
		n=0
		cat /tmp/previous-log-$$ | sort | uniq | while IFS='' read -r line || [[ -n $line ]]
		do
			n=$((n+1))
        		if [ $(grep -F "$line" /tmp/current-log-$$ | wc -l) -eq 0 ]
			then
				sed "${n}q;d" ${previous_log}
			fi
		done
		echo ""

		rm -f /tmp/current-log-$$ /tmp/previous-log-$$
	fi
	echo " "
}

kernel_build()
{
	repo=$1
	release=$2
	branch=$3

	dest=${LINUX_SRC_DIR}/${release}
	here=$(pwd)
	cppcheck=${here}/${CPPCHECK_DIR}/cppcheck

	repo_get $1 ${dest} ${branch}
	cd ${dest}

	if [ ! -z $TAG ]; then
		echo "cppchecking on tag $TAG"
		git reset --hard $TAG
		if [ $? -ne 0 ]; then
			echo "Selecting tag $TAG failed"
			exit 1
		fi
	fi

	tag=$(git describe --abbrev=0 --tags)
	commit=$(git log --format=%h -1)
	commitdate=$(git log --format=%ci -1 | cut -d' ' -f1)
	ver=${commitdate}-${tag}-${commit}
	logpath=${here}/${BUILD_LOG_DIR}/${release}/${ver}
	logname=${logpath}/${ver}-build
	mkdir -p ${logpath}

	#if [ -e ${logname}.log ]; then
		#echo "Already built ${release} ${tag} ${branch}."
	#else 
		echo "cppchecking $tag from commit $commit"
		(nice ${cppcheck} --platform=unix32 --force --max-configs=256 -j 48 --inconclusive --enable=warning,portability . \
			>& ${logname}.log) 
	#fi

	grep "portability)" ${logname}.log | sort | sed "s#${here}/${dest}/##" > ${logname}-portability.log
	grep "error)"  ${logname}.log | sort | sed "s#${here}/${dest}/##" > ${logname}-error.log
	grep "warning)"  ${logname}.log | sort | sed "s#${here}/${dest}/##" > ${logname}-warning.log

	portabilities=$(wc -l ${logname}-portability.log | cut -d' ' -f1)
	errors=$(wc -l ${logname}-error.log | cut -d' ' -f1)
	warnings=$(wc -l ${logname}-warning.log | cut -d' ' -f1)

	cd ${here}/${BUILD_LOG_DIR}/${release}

	echo "Analysing logs (intelligent diffing)"
	kernel_log_diff ${ver} portability > ${logname}-delta.log
	kernel_log_diff ${ver} error >> ${logname}-delta.log
	kernel_log_diff ${ver} warning >> ${logname}-delta.log

	echo "cppcheck found ${errors} errors and ${warnings} warnings and ${portabilities} portable messages in ${ver}" > ${logname}-summary.log
	
	cd ${here}
}

cd ${ROOT_DIR}
echo 
echo "cppchecking on "$(date) " in " ${ROOT_DIR}
echo 
#
#  Has a specific ARCHH been given?
#
if [ $# -eq 1 ]; then
	ARCH=$1
fi

#
#  Get latest cppcheck built
#
cppcheck_prepare


#
#  cppcheckify the kernels
#
i=0
for release in ${releases[@]}; do
	echo "Build ${release} ${ARCH}"
	kernel_build ${kernel_repos[$i]} ${release} ${kernel_branches[$i]}
	i=$((i+1))
done
#
#
#  Sync over to zinc
#
#kernel_build_logs_rsync
