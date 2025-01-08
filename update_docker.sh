#!/bin/bash
set -eu
echo "$0 $@ [$$] START" >&2
### --help Info: Обновление контейнера evateam
### --help Usage:
### --help Example:
. /opt/eva_admin/crab_sys.sh
if [[ ${1:-} = --help ]]; then
	/opt/eva_admin/_update_docker.sh --help
	# sys::usage "$@"
	exit 0
fi
sys::arg_parse "$@"

if [ ! -z "${ARG_OFFLINE:-}" ]; then
	if [ ! -d "/opt/eva_admin/eva_docker_dist/eva_admin/" ]; then
		echo "Не найден каталог с загруженным обновлением /opt/eva_admin/eva_docker_dist/eva_admin/"
		echo "Требуется инициализировать его, либо запустите скрипт без опции --offline"
		exit 1
	fi
	git pull /opt/eva_admin/eva_docker_dist/eva_admin/
else
	(
		cd /opt/eva_admin
		git pull origin master
	)
fi

/opt/eva_admin/_update_docker.sh "$@"

echo "$0 $@ [$$] SUCCESS" >&2
exit 0
