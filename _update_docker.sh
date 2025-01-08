#!/bin/bash
set -eu
shopt -s extglob
echo "$0 $@ [$$] START" >&2
### --help Info: Обновление контейнера evateam
### --help Usage: --name=test1 - использовать файл конфигурации контейнера /opt/eva_admin/CONFIG-test1
### --help Usage: --version=v00.00.00.0000
# --skip-backup-bd
### --help Usage: --skip-backup - пропустить бекап
### --help Usage:     В случае использования, нужно сделать бекап
### --help Usage:     непосредственно перед обновлением самостоятельно
### --help Usage: --branch=release - бранч для обновления
### --help Usage:     Нужно указывать при смене бранча при обновлении
### --help Usage: --offline - не загружать версии из docker-registry.evateam.ru
### --help Usage:     Версии должны быть загружены локально самостоятельно
### --help Usage:     включая все промежуточные patch-версии.
### --help Usage: --list [--all] - показать доступные версии для обновления
### --help Usage:     Если передан --all, то показать все всерсии.
### --help Example:
. /opt/eva_admin/crab_sys.sh
if [[ ${1:-} = --help || ${1:-} ]]; then
	sys::usage "$@"
fi
declare ARG_NAME ARG_FROM_VERSION ARG_BRANCH ARG_OFFLINE ARG_LIST ARG_ALL ARG_SKIP_BACKUP
sys::arg_parse "$@"

declare _NAME="${ARG_NAME:-evateam}"
declare CONFIG_PATH="/opt/eva_admin/CONFIG${ARG_NAME:+-$ARG_NAME}"


declare CONTAINER_NAME CONTAINER_PARAMS CONTAINER_ENGINE CONTAINER_AS_SERVICE
declare NAME BRANCH VERSION DOCKER_IMAGE CONTAINER_VOLUME
declare CONTAINER_CUSTOM_PARAMS CONF_TZ 
source "$CONFIG_PATH"

declare CONTAINER_PARAMS_UPDATE="${CONTAINER_PARAMS}"
CONTAINER_PARAMS_UPDATE="${CONTAINER_PARAMS_UPDATE##--restart=always}"
CONTAINER_PARAMS_UPDATE="${CONTAINER_PARAMS_UPDATE##--read-only}"

declare PATCH_VERSIONS=''

declare TO_VERSION TO_BRANCH TO_VERSION_FULL UPDATE_SCOPE

declare UPDATE_CONTAINER_NAME IMAGE_NAME FROM_VERSION FROM_VERSION_FULL
declare SKIP_PATCH_VERSIONS=0

declare SELINUX_OPT
[[ $CONTAINER_ENGINE = podman ]] && SELINUX_OPT=",relabel=private"


prepare() {
	if [ -z "${ARG_FROM_VERSION:-}" ]; then
		set -o pipefail
		FROM_VERSION_FULL="$($CONTAINER_ENGINE container inspect "$CONTAINER_NAME" \
			| jq -r '.[0].Config.Image' | cut -d ':' -f 2)"
		set +o pipefail
	else
		FROM_VERSION_FULL="${ARG_FROM_VERSION:-}"
	fi
	FROM_VERSION="$(echo "$FROM_VERSION_FULL" | cut -d '-' -f 2)"
	FROM_BRANCH="$(echo "$FROM_VERSION_FULL" | cut -d '-' -f 3)"

	# Если скрипту передали бранч и он не равен текущему, пропускаем применение промежуточных патчей
	if [ ! -z "${ARG_BRANCH:-}" -a "${ARG_BRANCH:-}" != "${FROM_BRANCH}" -a "${ARG_BRANCH:-}" != "all" ]; then
		SKIP_PATCH_VERSIONS=1
		TO_BRANCH="${ARG_BRANCH}"
	else
		TO_BRANCH="${FROM_BRANCH}"
	fi

	if [[ " integra devel release master " == *" $TO_BRANCH "* ]]; then
		UPDATE_SCOPE=public
	else
		UPDATE_SCOPE="$TO_BRANCH"
	fi
	return 0
}


fix_config(){
	# Исправления файла конфигурации из новых версий install_docker.sh
	# Добавляем параметр --shm-size=8g
	if ! [[ "${CONTAINER_PARAMS}" = *"--shm-size="* ]]; then
		sed -i 's/^CONTAINER_PARAMS=./&--shm-size=8g /g' "$CONFIG_PATH"
		CONTAINER_PARAMS="--shm-size=8g $CONTAINER_PARAMS"
	fi
	if [ -z "${CONTAINER_ENGINE:-}" ]; then
		CONTAINER_ENGINE='docker'
		if which docker &>/dev/null; then
			CONTAINER_ENGINE='docker'
		elif which podman &>/dev/null; then
			CONTAINER_ENGINE='podman'
		fi
		echo "CONTAINER_ENGINE='${CONTAINER_ENGINE}'" >>"$CONFIG_PATH"
	fi
	# Для совместимости со старыми конфигами инициализируем недостающие переменные с параметрами контейнера
	#     BRANCH, VERSION, DOCKER_IMAGE
	#     CONTAINER_CUSTOM_PARAMS
	#     HTTPS_PORT='0.0.0.0:443' HTTP_PORT='0.0.0.0:80'
	# ? SELECTED_PRODUCT, CONF_ADMIN_EMAIL, CONF_DOMAIN, CONF_CERTBOT,
	#   CONF_TZ, CONF_MEMORY_LIMIT_GB
	if [[ $_NAME = evateam ]]; then
		if [[ ! ${NAME+set} ]]; then
			NAME="$_NAME"
			echo "NAME=$NAME" >>"$CONFIG_PATH"
			echo "Config Patched: NAME=$NAME"
		fi
		if [[ ! ${CONTAINER_NAME+set} ]]; then
			# TODO: check?
			CONTAINER_NAME=evateam
			echo "CONTAINER_NAME=$CONTAINER_NAME" >>"$CONFIG_PATH"
			echo "Config Patched: CONTAINER_NAME=$CONTAINER_NAME"
		fi
		if [[ ! ${CONTAINER_VOLUME+set} ]]; then
			# TODO: Check? source=evateam-shared in CONTAINER_PARAMS
			CONTAINER_VOLUME=evateam-shared
			echo "CONTAINER_VOLUME=$CONTAINER_VOLUME" >>"$CONFIG_PATH"
			echo "Config Patched: CONTAINER_VOLUME=$CONTAINER_VOLUME"
		fi
		if [[ ! ${HTTP_PORT+set} ]]; then
			HTTP_PORT=$(sed -E 's/.* -p ([^ ]+):80\/tcp.*/\1/;t;d'<<<"$CONTAINER_PARAMS")
			echo "HTTP_PORT=$HTTP_PORT" >>"$CONFIG_PATH"
			echo "Config Patched: HTTP_PORT=$HTTP_PORT"
		fi
		if [[ ! ${HTTPS_PORT+set} ]]; then
			HTTPS_PORT=$(sed -E 's/.* -p ([^ ]+):443\/tcp.*/\1/;t;d'<<<"$CONTAINER_PARAMS")
			echo "HTTPS_PORT=$HTTPS_PORT" >>"$CONFIG_PATH"
			echo "Config Patched: HTTPS_PORT=$HTTPS_PORT"
		fi
		if [[ ! ${CONF_TZ+set} ]]; then
			CONF_TZ=$(sed -E 's/.* -e TZ=([^ ]+).*/\1/;t;d'<<<"$CONTAINER_PARAMS")
			echo "CONF_TZ=$CONF_TZ" >>"$CONFIG_PATH"
			echo "Config Patched: CONF_TZ=$CONF_TZ"
		fi
		if [[ ! ${CONF_DOMAIN+set} ]]; then
			CONF_DOMAIN=$(sed -E 's/.* -h ([^ ]+).*/\1/;t;d'<<<"$CONTAINER_PARAMS")
			echo "CONF_DOMAIN=$CONF_DOMAIN" >>"$CONFIG_PATH"
			echo "Config Patched: CONF_DOMAIN=$CONF_DOMAIN"
		fi
		if [[ ! ${CONTAINER_CUSTOM_PARAMS+set} ]]; then
			CONTAINER_CUSTOM_PARAMS="$CONTAINER_PARAMS"
			CONTAINER_CUSTOM_PARAMS="$(sed -E 's/--restart=always//' <<<"$CONTAINER_CUSTOM_PARAMS")"
			CONTAINER_CUSTOM_PARAMS="$(sed -E 's/--shm-size=8g//' <<<"$CONTAINER_CUSTOM_PARAMS")"
			CONTAINER_CUSTOM_PARAMS="$(sed -E 's/--stop-timeout=60//' <<<"$CONTAINER_CUSTOM_PARAMS")"
			CONTAINER_CUSTOM_PARAMS="$(sed -E 's/--mount=type=volume,source=evateam-shared,target=\/mnt\/shared//' <<<"$CONTAINER_CUSTOM_PARAMS")"
			CONTAINER_CUSTOM_PARAMS="$(sed -E 's/--volume=\/mnt\/tmp//' <<<"$CONTAINER_CUSTOM_PARAMS")"
			CONTAINER_CUSTOM_PARAMS="$(sed -E 's/-h [^ ]+//' <<<"$CONTAINER_CUSTOM_PARAMS")"
			CONTAINER_CUSTOM_PARAMS="$(sed -E 's/-e TZ=[^ ]*//' <<<"$CONTAINER_CUSTOM_PARAMS")"
			CONTAINER_CUSTOM_PARAMS="$(sed -E 's/-p 443:443\/tcp//' <<<"$CONTAINER_CUSTOM_PARAMS")"
			CONTAINER_CUSTOM_PARAMS="$(sed -E 's/-p 80:80\/tcp//' <<<"$CONTAINER_CUSTOM_PARAMS")"
			CONTAINER_CUSTOM_PARAMS="${CONTAINER_CUSTOM_PARAMS##*( )}"
			CONTAINER_CUSTOM_PARAMS="${CONTAINER_CUSTOM_PARAMS%%*( )}"
			echo "CONTAINER_CUSTOM_PARAMS='$CONTAINER_CUSTOM_PARAMS'" >>"$CONFIG_PATH"
			echo "Config Patched: CONTAINER_CUSTOM_PARAMS=$CONTAINER_CUSTOM_PARAMS"
		fi
	fi
	return 0
}


prepare_update() {
	if [[ "${ARG_OFFLINE:-}" ]]; then
		. /opt/eva_admin/eva_docker_dist/update_config
		TO_VERSION="${UPDATE_TO_VERION}"
		TO_VERSION_FULL="${UPDATE_TO_VERION_FULL}"
		if [ "$FROM_VERSION_FULL" != "$UPDATE_FROM_VERION" ]; then
			echo "Обновление подготовлено для версии $UPDATE_FROM_VERION, но установлена версия $FROM_VERSION_FULL"
			echo "Создайте обновление с версии $FROM_VERSION_FULL"
			exit 1
		fi
	else
		if [ -z "${ARG_VERSION:-}" ]; then
			echo "Укажите версию для обновления"
			exit 1
		fi
		TO_VERSION="${ARG_VERSION}"
		TO_VERSION_FULL="$(/opt/eva_admin/eva_versions.py get-docker-image-name -v "${UPDATE_SCOPE}-${ARG_VERSION}-${TO_BRANCH}")"
		TO_VERSION_FULL="${TO_VERSION_FULL##*:}"
	fi

	UPDATE_CONTAINER_NAME="${CONTAINER_NAME}-update"
	IMAGE_NAME="docker-registry.evateam.ru/evateam:${TO_VERSION_FULL}"

	if [ "$FROM_VERSION" == "$TO_VERSION" ]; then
		echo "Версия $TO_VERSION уже установлена!"
		exit 1
	fi
	return 0
}


get_versions_offline() {
	. /opt/eva_admin/eva_docker_dist/update_config
	if [ ! -f "/opt/eva_admin/eva_docker_dist/download_done" ]; then
		echo "Файлы для установки не загружены до конца!"
		exit 1
	fi
	PATCH_VERSIONS="$(cat /opt/eva_admin/eva_docker_dist/update_versions)"
	echo "Загружаем патч-версии"
	for p_ver in $PATCH_VERSIONS; do
		echo "$p_ver"
		$CONTAINER_ENGINE load -i "/opt/eva_admin/eva_docker_dist/${p_ver##*:}.tar.gz" </dev/null
	done
	return 0
}


get_versions_and_pull() {
	echo "Загружаем версию для обновления ${TO_VERSION_FULL}"
	if ! $CONTAINER_ENGINE pull $IMAGE_NAME; then
		echo "ERROR! Не удалось загрузить версию для обновления!"
		exit 1
	fi

	if [ "$SKIP_PATCH_VERSIONS" == "1" ]; then
		return 0
	fi

	/opt/eva_admin/eva_versions.py update-to-version-list \
		${ARG_CHANGE_BRANCH:+--change-branch="${ARG_CHANGE_BRANCH}"} \
		--current-version="$FROM_VERSION_FULL" --to-version="$TO_VERSION_FULL" \
		--output-format=registry \
		>/tmp/eva_admin_update_versions.$$

	PATCH_VERSIONS="$(cat /tmp/eva_admin_update_versions.$$ | grep -- '-patch$' || true)"
	echo "Список промежуточных версий: $PATCH_VERSIONS"
	rm -f /tmp/eva_admin_update_versions.$$

	echo "Загружаем патч-версии"
	for p_ver in $PATCH_VERSIONS; do
		echo "$p_ver"
		$CONTAINER_ENGINE pull $p_ver </dev/null
	done
	return 0
}


clean_before_update() {
	echo "Удаляем прошлые артефакты обновления"
	$CONTAINER_ENGINE stop -t 60 "$UPDATE_CONTAINER_NAME" 2>/dev/null || true
	$CONTAINER_ENGINE rm "$UPDATE_CONTAINER_NAME" 2>/dev/null || true
	$CONTAINER_ENGINE volume rm evateam-update-patch 2>/dev/null || true
	return 0
}


_yesnobackup() {
	local ans=0
	local reply
	while [ $ans -eq 0 ]; do
		echo -n "Вы сделали бекап БД перед обновлением (да/нет)? " ; read reply
		if [ "${reply:0:1}" = 'y' -o  "${reply:0:1}" = 'Y' -o  "${reply:0:1}" = 'д' -o  "${reply:0:1}" = 'Д' ]; then
			ans=1
		elif [ "${reply:0:1}" = 'n' -o  "${reply:0:1}" = 'N' -o  "${reply:0:1}" = 'н' -o  "${reply:0:1}" = 'Н' ]; then
			ans=1
		else
			echo "Ответьте да или нет"
		fi
	done
	return 0
}

stop_container() {
	local has_service=

	echo "Удаляем контейнер"
	if [[ $CONTAINER_ENGINE = podman ]]; then
		if systemctl show --property=LoadState "$CONTAINER_NAME.service" \
			| grep -q LoadState=loaded; then
			has_service=TRUE
			if [[ ${CONTAINER_AS_SERVICE:-} != TRUE ]]; then
				echo "Add CONTAINER_AS_SERVICE to config!" >&2
				CONTAINER_AS_SERVICE=TRUE
				echo "CONTAINER_AS_SERVICE='TRUE'" >> "$CONFIG_PATH"
			fi
		else
			if [[ ${CONTAINER_AS_SERVICE:-} ]]; then
				echo "Remove CONTAINER_AS_SERVICE from config!" >&2
				sed -iE 's/^CONTAINER_AS_SERVICE=.*//' "$CONFIG_PATH"
			fi
			CONTAINER_AS_SERVICE=
		fi
	fi
	# !!! podman не остановить $CONTAINER_ENGINE stop, т.к. systemd его перезапустит.
	if [[ $CONTAINER_ENGINE = podman && ${CONTAINER_AS_SERVICE:-} ]]; then
		echo "Stop systemd service $CONTAINER_NAME" >&2
		# !!! если остановить через systemd, то контейнер будет удалён хуком.
		systemctl stop "$CONTAINER_NAME.service"
	else
		# Не удаляем основной контейнер, пока не будем готовы к запуску новой версии
		"$CONTAINER_ENGINE" stop "$CONTAINER_NAME"
	fi
	return 0
}

warning_before_backup() {
	echo "ВНИМАНИЕ! Создание бекапа перед обновлением отключено!"
	echo "Бекап должен быть сделан Вами перед продолжением обновления"
	echo "иначе возможна потеря данных!"

	read -r -e -p "Продолжить [yes/no]: " ask
	if [[ $ask != [yY][eE][sS] ]]; then
			echo "Создание резервной копии прервано."
			return 1
	fi
}


make_beforeupdate_backup() {
	local ask
	echo "Делаем резервную копию контейнера"

	/opt/eva_admin/backup_ctl.sh backup --name="$CONTAINER_NAME" \
		--alias=last_upgrade --backup="$(date +%Y-%m-%d-%H-%M-%S)_upgrade"
	echo
	echo "!!! Для отката неудачной попытки обновления Используйте команду:"
	echo "   /opt/eva_admin/backup_ctl.sh restore last_upgrade"
	echo
	return 0
}


make_beforeupdate_backup_old() {
	$CONTAINER_ENGINE volume create evateam-update-backup
	$CONTAINER_ENGINE run --name "$UPDATE_CONTAINER_NAME" ${CONTAINER_PARAMS_UPDATE} \
		--mount type=volume,source=evateam-update-backup,target=/mnt/update_backup${SELINUX_OPT:-} \
		$IMAGE_NAME /opt/bin/update_scripts/update_backup.sh
	$CONTAINER_ENGINE wait "$UPDATE_CONTAINER_NAME"
	$CONTAINER_ENGINE stop -t 60 "$UPDATE_CONTAINER_NAME"
	$CONTAINER_ENGINE rm "$UPDATE_CONTAINER_NAME"
	return 0
}


make_patch_volume() {
	$CONTAINER_ENGINE volume create evateam-update-patch
	echo "Заполняем patch-volume"
	$CONTAINER_ENGINE run --name "$UPDATE_CONTAINER_NAME" ${CONTAINER_PARAMS_UPDATE} \
		--mount type=volume,source=evateam-update-patch,target=/mnt/update_patch${SELINUX_OPT:-} \
		$IMAGE_NAME /opt/bin/update_scripts/update_fill_patch_volume.sh
	$CONTAINER_ENGINE wait "$UPDATE_CONTAINER_NAME"
	$CONTAINER_ENGINE stop -t 60 "$UPDATE_CONTAINER_NAME"
	$CONTAINER_ENGINE rm "$UPDATE_CONTAINER_NAME"
	return 0
}


run_update() {
	echo "Применяем патчи"
	for p_ver in ${PATCH_VERSIONS:-}; do
		echo "Патч $p_ver"
		$CONTAINER_ENGINE run --name "$UPDATE_CONTAINER_NAME" ${CONTAINER_PARAMS_UPDATE} \
			--mount type=volume,source=evateam-update-patch,target=/mnt/update_patch${SELINUX_OPT:-} \
			${p_ver} /mnt/update_patch/update_patch.sh </dev/null
		$CONTAINER_ENGINE wait "$UPDATE_CONTAINER_NAME"
		$CONTAINER_ENGINE stop -t 60 "$UPDATE_CONTAINER_NAME"
		$CONTAINER_ENGINE rm "$UPDATE_CONTAINER_NAME"
	done

	echo "Патч $TO_VERSION"
	$CONTAINER_ENGINE run --name "$UPDATE_CONTAINER_NAME" ${CONTAINER_PARAMS_UPDATE} \
		--mount type=volume,source=evateam-update-patch,target=/mnt/update_patch${SELINUX_OPT:-} \
		$IMAGE_NAME /mnt/update_patch/update_patch.sh
	$CONTAINER_ENGINE wait "$UPDATE_CONTAINER_NAME"
	$CONTAINER_ENGINE stop -t 60 "$UPDATE_CONTAINER_NAME"
	$CONTAINER_ENGINE rm "$UPDATE_CONTAINER_NAME"
	# Save VERSION DOCKER_IMAGE to CONFIG
	if grep -qE ^VERSION= "$CONFIG_PATH"; then
		sed -i -Ee "s/^VERSION=.*/VERSION='$TO_VERSION'/" "$CONFIG_PATH"
	else
		echo "VERSION=$TO_VERSION" >>"$CONFIG_PATH"
	fi
	if grep -qE ^DOCKER_IMAGE= "$CONFIG_PATH"; then
		sed -i -Ee "s~^DOCKER_IMAGE=.*~DOCKER_IMAGE='$IMAGE_NAME'~" "$CONFIG_PATH"
	else
		echo "DOCKER_IMAGE=$IMAGE_NAME" >>"$CONFIG_PATH"
	fi
	if grep -qE ^BRANCH= "$CONFIG_PATH"; then
		sed -i -Ee "s~^BRANCH=.*~BRANCH='$TO_BRANCH'~" "$CONFIG_PATH"
	else
		echo "BRANCH=$TO_BRANCH" >>"$CONFIG_PATH"
	fi
	return 0
}


list_versions() {
	# TODO: --offline
	/opt/eva_admin/eva_versions.py get-available-versions \
		--current-version="$FROM_VERSION_FULL" ${ARG_ALL:+--all} \
		--change-branch="$TO_BRANCH"
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
	local cmd= delay

	if [[ ! "${ARG_OFFLINE:-}" ]] && [[ ! "${ARG_TESTS:-}" ]]; then
		check_if_update_is_available
	fi

	fix_config
	prepare
	if [ ! -z "${ARG_LIST:-}" ]; then
		list_versions
		exit 0
	fi
	if pidof -csxo %PPID "${0##*/}"; then
		echo "Already running" >&2
		return 1
	fi
	prepare_update
	clean_before_update
	if [[ "${ARG_OFFLINE:-}" ]]; then
		get_versions_offline
	else
		get_versions_and_pull
	fi

	# Сhecking the need to create a backup
	if [[ "${ARG_SKIP_BACKUP:-}" ]]; then
		warning_before_backup
		stop_container
	else
		# If argument --skip-backup does not exists, creating prepare conteainer & stop container & creating backup
		/opt/eva_admin/backup_ctl.sh prepare
		stop_container
		make_beforeupdate_backup
	fi

	make_patch_volume
	run_update
	echo "Очищаем patch-volume"
	"$CONTAINER_ENGINE" volume rm evateam-update-patch

	echo "Патчи применены, запускаем контейнер"
	if "$CONTAINER_ENGINE" container inspect "$CONTAINER_NAME" &>/dev/null; then
		"$CONTAINER_ENGINE" rm -fv "$CONTAINER_NAME"
	fi
	"$CONTAINER_ENGINE" run -d --name "$CONTAINER_NAME" $CONTAINER_PARAMS "$IMAGE_NAME"
	"$CONTAINER_ENGINE" exec "$CONTAINER_NAME" sh -c "date +%s > /mnt/shared/eva_last_update"
	if [[ $CONTAINER_ENGINE = podman && ${CONTAINER_AS_SERVICE:-} ]]; then
		echo "Update systemd service $CONTAINER_NAME" >&2
		# Нужно обновить конфигурацию сервиса.
		podman generate systemd --new --name "$CONTAINER_NAME" --restart-policy=always \
			> "/etc/systemd/system/$CONTAINER_NAME.service"
		systemctl daemon-reload
		systemctl enable "$CONTAINER_NAME.service"
		systemctl restart "$CONTAINER_NAME.service"
	fi

	# Включаем дебаг после обновления, необходимо чтобы контейнер был запущен
	for delay in 5 10 10 10 10 60 timeout; do
		if [[ $delay == timeout ]]; then
			echo "Не дождались запуска контейнера после обновления." >&2
			exit 1
		fi
		sleep "$delay"
		if [[ "$("$CONTAINER_ENGINE" logs --tail 1 "$CONTAINER_NAME")" == "Контейнер запущен." ]]; then
			break
		fi
	done
	cmd="if [ -f /opt/bin/debug_manager.sh ];"
	cmd+=" then bash -x /opt/bin/debug_manager.sh enable --restart; fi"
	"$CONTAINER_ENGINE" exec "$CONTAINER_NAME" bash -c "$cmd"

	# Временно не чистим
	# $CONTAINER_ENGINE volume rm evateam-update-backup
	return 0
}


main

echo "$0 $@ [$$] SUCCESS" >&2
exit 0
