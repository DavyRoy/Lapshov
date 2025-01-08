#!/bin/bash
set -eu
echo "$0 $@ [$$] START" >&2
### --help Info: Загрузка пакета обновления
### --help Usage: --from-version=
### --help Usage: --to-version=
### --help Usage: --for-install
### --help Example:

# eva_admin может быть не установлен в opt
if [ -f "/opt/eva_admin/crab_sys.sh" ]; then
	. /opt/eva_admin/crab_sys.sh
else
	. ./crab_sys.sh
fi
if [[ ${1:-} = --help ]]; then
	sys::usage "$@"
fi
sys::arg_parse "$@"

declare DIST_PATH='./eva_docker_dist'
declare EVA_VERSIONS="/opt/eva_admin/eva_versions.py"
if [ ! -f "$EVA_VERSIONS" ]; then
	EVA_VERSIONS="./eva_versions.py"
fi
declare INSTALL_VERSION=""
declare TO_VERION_FULL=""

prepare() {
	return 0
}


clean_dist() {
	rm -f "${DIST_PATH}/download_done"
	rm -f "${DIST_PATH}/update_versions"
	return 0
}


download_eva_admin() {
	local eva_admin_path="${DIST_PATH}/eva_admin"
	if [ -d "${eva_admin_path}" ]; then
		(
			cd "${eva_admin_path}"
			git pull origin master
		)
	else
		git clone "https://updater.evateam.ru/git/eva_admin.git" "${eva_admin_path}"
	fi
	return 0
}


download_install_version(){
	INSTALL_VERSION="$($EVA_VERSIONS get-version-for-install --output-format=registry)"
	echo "Версия для загрузки: $INSTALL_VERSION"
	echo "Загружаем $INSTALL_VERSION"
	docker pull $INSTALL_VERSION
	echo "Сохраняем на диск..."
	set -o pipefail
	docker save $INSTALL_VERSION | gzip > "${DIST_PATH}/${INSTALL_VERSION##*:}.tar.gz"
	set +o pipefail
	echo "Готово"
	return 0
}


download_versions() {
	$EVA_VERSIONS update-to-version-list \
		${ARG_CHANGE_BRANCH:+--change-branch="${ARG_CHANGE_BRANCH}"} \
		--current-version="${ARG_FROM_VERSION}" \
		--to-version="${ARG_TO_VERSION}" \
		--output-format=registry >/tmp/eva_admin_download_versions.$$
	TO_VERION_FULL="$(grep "${ARG_TO_VERSION}" /tmp/eva_admin_download_versions.$$ \
		| grep official || true)"
	if [ -z "$TO_VERION_FULL" ]; then
		TO_VERION_FULL="$(grep "${ARG_TO_VERSION}" /tmp/eva_admin_download_versions.$$)"
	fi
	TO_VERION_FULL="${TO_VERION_FULL##*:}"

	local url
	echo "Список версий для загрузки:"
	cat /tmp/eva_admin_download_versions.$$ | grep -E -- "(-patch\$|$TO_VERION_FULL)" \
		| while read -r url; do
			echo "Загружаем $url"
			docker pull $url
			echo "Сохраняем на диск..."
			set -o pipefail
			docker save $url | gzip > "${DIST_PATH}/${url##*:}.tar.gz"
			set +o pipefail
			echo "Готово"
			echo "$url" >>"${DIST_PATH}/update_versions"
		done
	rm -f /tmp/eva_admin_download_versions.$$

	return 0
}


save_metadata() {
	echo "UPDATE_FROM_VERION='${ARG_FROM_VERSION:-}'" > "${DIST_PATH}/update_config"
	echo "UPDATE_TO_VERION='${ARG_TO_VERSION:-}'" >> "${DIST_PATH}/update_config"
	echo "UPDATE_TO_VERION_FULL='${TO_VERION_FULL:-}'" >> "${DIST_PATH}/update_config"
	echo "FOR_INSTALL='${ARG_FOR_INSTALL:-}'" >> "${DIST_PATH}/update_config"
	echo "INSTALL_VERSION='${INSTALL_VERSION:-}'" >> "${DIST_PATH}/update_config"
	touch "${DIST_PATH}/download_done"
	return 0
}


check_if_update_is_available(){
	if curl -f -s -I -o /dev/null https://updater.evateam.ru/evateam/update_lock; then
		echo
		echo "Обновление пока заблокировано на сервере обновлений."
		echo
		exit 0
	fi
	return 0
}


main() {
	if [[ ! "${ARG_FOR_INSTALL:-}" ]] && [[ ! "${ARG_TESTS:-}" ]]; then
		check_if_update_is_available
	fi
	prepare
	clean_dist
	download_eva_admin
	if [ "${ARG_FOR_INSTALL:-}" = 'TRUE' ]; then
		download_install_version
	else
		download_versions
	fi
	save_metadata
	return 0
}


main

echo "$0 $@ [$$] SUCCESS" >&2
exit 0
