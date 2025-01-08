#!/bin/bash
set -eu
shopt -s nullglob

### --help Info: Управление бэкапами Evateam
### --help Usage: /opt/eva_admin/backup_ctl.sh backup|list|restore ...
### --help Usage: TODO: offline
### --help Usage:  list - вывести список бекапов
### --help Usage:  prepare - создать онлайн копию тома, чтобы снизить downtime
### --help Usage:   --image - сделать копию докер образа.
### --help Usage:  backup - сделать бекап
### --help Usage:   --backup=2024-08-14-15-14-46_upgrade - имя бекапа
### --help Usage:   --alias=last_upgrade - алиас, для удобства
### --help Usage:   --name=test1 - использовать файл конфигурации контейнера /opt/eva_admin/CONFIG-test1
### --help Usage:  restore - восстановить бекап
### --help Usage:   --name=test1 - использовать файл конфигурации контейнера /opt/eva_admin/CONFIG-test1
# export and store image? --offline --image?
### --help Example: /opt/eva_admin/backup_ctl.sh list
### --help Example: /opt/eva_admin/backup_ctl.sh prepare [--image]
### --help Example: /opt/eva_admin/backup_ctl.sh backup [--alias=last_upgrade] [--backup=BACKUP_NAME]
### --help Example:                                     [--image] [--name=CONFIG_NAME]
### --help Example: /opt/eva_admin/backup_ctl.sh restore BACKUP_NAME

source /opt/eva_admin/crab_sys.sh

if [[ ${1:---help} = --help ]]; then
	sys::usage "$@"
	exit 0
fi

declare ARG_1
declare ARG_2
declare ARG_ALIAS
declare ARG_NAME
declare ARG_IMAGE
sys::arg_parse "$@"

# from /opt/eva_admin/CONFIG
declare CONTAINER_NAME
declare CONTAINER_VOLUME
declare CONTAINER_PARAMS
declare CONTAINER_ENGINE
declare CONTAINER_AS_SERVICE
declare _NAME
declare CONTAINER_NAME
declare CONFIG_PATH
declare CONTAINER_SEC_PARAMS

# init by ct_state
declare SHARED_VOL
declare CT_EXISTS
declare CT_RUNNINIG
declare IMAGE
declare IMAGE_TAG
declare SHARED_VOL

declare BACKUPS_DIR
declare IMAGES_DIR
declare PREPARE_DIR

_NAME="${ARG_NAME:-evateam}"
CONFIG_NAME="CONFIG"
[[ ${ARG_NAME:-} && $ARG_NAME != evateam ]] && CONFIG_NAME+="-$ARG_NAME"
CONFIG_PATH="/opt/eva_admin/$CONFIG_NAME"
CONTAINER_SEC_PARAMS=""

BACKUPS_DIR=/opt/eva_admin/backups
IMAGES_DIR="$BACKUPS_DIR/images"
PREPARE_DIR="$BACKUPS_DIR/_prepare"

CT_EXISTS=
CT_RUNNINIG=
IMAGE=
IMAGE_TAG=
SHARED_VOL=


do_list() {
	local backup_dir backup_name name
	# if [[ ! -d $BACKUPS_DIR ]]; then
	# 	return 0
	# fi
	for backup_dir in "$BACKUPS_DIR"/*; do
		backup_name="${backup_dir#$BACKUPS_DIR/}"
		if [[ ! -f $backup_dir/datetime || backup_name = _* ]]; then
			continue
		fi
		if [[ -f $backup_dir/CONFIG ]]; then
			name="$(set -e; . $backup_dir/CONFIG; echo ${NAME:-evateam})"
		else
			name="$(set -e; source $(find $backup_dir/ -maxdepth 1 -iname CONFIG\*); echo $NAME)"
		fi
		echo "$(<$backup_dir/datetime) $name $backup_name"
	done
	return 0
}


check_external_database() {
	local custom_config ask

	custom_config="$("$CONTAINER_ENGINE" run --rm $CONTAINER_SEC_PARAMS\
		--volume="$SHARED_VOL:/mnt/shared" "$IMAGE" \
		cat /opt/eva-app/custom/config.py)"
	if grep -q ^data_sources <<<"$custom_config"; then
		# TODO: backup extenal BD, how?
		# TODO: force skip
		echo -n "Вероятно используется внешня СУБД." >&2
		echo -n " Сделайте её резервную копию собственными средствами" >&2
		echo " и введите yes, чтобы продолжить." >&2
		read -r -e -p "Продолжить [yes/no]: " ask
		if [[ $ask != [yY][eE][sS] ]]; then
			echo "Создание резервной копии прервано."
			return 1
		fi
	fi
	return 0
}


check_free_space() {
	local volume_kb free_kb prepared_kb=0 _

	read -r volume_kb _ <<<"$("$CONTAINER_ENGINE" run $CONTAINER_SEC_PARAMS \
		--rm --volume="$SHARED_VOL:/mnt/shared" "$IMAGE" du -sk /mnt/shared/)"

	set -o pipefail
	# skip strongbash034
	free_kb="$(df -k --output=avail "$BACKUPS_DIR" | tail -n 1)"
	set +o pipefail

	if [[ -d "$PREPARE_DIR/$SHARED_VOL" ]]; then
		read -r prepared_kb _ <<<"$(du -sk "$PREPARE_DIR/$SHARED_VOL")"
	fi

	echo "Для создания бэкапа необходимо $((volume_kb/1024/1024 + 5))Gb" \
		"свободного пространства на диске." >&2
	echo "Доступно пространства $((free_kb/1024/1024))Gb" >&2
	echo "Пространства в кеше: $((prepared_kb/1024/1024))Gb"
	if (( volume_kb > free_kb + prepared_kb - 5 * 1000 * 1000 )); then
		return 1
	fi
	return 0
}


backup_image() {
	mkdir -p "$IMAGES_DIR"
	set -o pipefail
	"$CONTAINER_ENGINE" image save "$IMAGE" | gzip > "$IMAGES_DIR/tmp-$IMAGE_TAG.tgz"
	set +o pipefail
	mv "$IMAGES_DIR/tmp-$IMAGE_TAG.tgz" "$IMAGES_DIR/$IMAGE_TAG.tgz"
	return 0
}


backup_configs() {
	local backup_dir_tmp="$1"
	echo "$CONTAINER_NAME" > "$backup_dir_tmp/container_name"
	echo "$SHARED_VOL" > "$backup_dir_tmp/shared_volume_name"
	echo "$IMAGE" > "$backup_dir_tmp/image_name"
	if [[ $CT_EXISTS ]]; then
		"$CONTAINER_ENGINE" container inspect "$CONTAINER_NAME" \
			> "$backup_dir_tmp/container_inspect"
	fi
	"$CONTAINER_ENGINE" run $CONTAINER_SEC_PARAMS --rm "$IMAGE" \
		cat /opt/eva_branch > "$backup_dir_tmp/eva_branch"
	"$CONTAINER_ENGINE" run $CONTAINER_SEC_PARAMS --rm "$IMAGE" \
		cat /opt/eva_version > "$backup_dir_tmp/eva_version"
	cp "$CONFIG_PATH" "$backup_dir_tmp/$CONFIG_NAME"
	if [[ $CONTAINER_ENGINE = podman && -f /etc/systemd/system/evateam.service ]]; then
		cp /etc/systemd/system/evateam.service "$backup_dir_tmp/evateam.service"
	fi
	return 0
}


ct_state() {
	# Set backup vars and import CONFIG
	CT_EXISTS=
	CT_RUNNINIG=
	IMAGE=
	IMAGE_TAG=

	source $CONFIG_PATH

	if [[ ! ${NAME:-} ]]; then
		NAME="$_NAME"
	elif [[ $NAME != $_NAME ]]; then
		echo "Параметр NAME=$NAME в файле $CONFIG_PATH не соответствует аргументу --name=$_NAME" >&2
		exit 1
	fi

	# Check container exists
	if "$CONTAINER_ENGINE" container inspect --format - "$CONTAINER_NAME" >/dev/null; then
		CT_EXISTS=TRUE
		if [[ $("$CONTAINER_ENGINE" container \
			inspect --format "{{.State.Running}}" "$CONTAINER_NAME") = true ]]; then
			CT_RUNNINIG=TRUE
		fi
		IMAGE="$("$CONTAINER_ENGINE" container \
			inspect --format "{{.Config.Image}}" "$CONTAINER_NAME")"

	elif [[ $CONTAINER_ENGINE = podman && -f /etc/systemd/system/evateam.service ]]; then
		# Если Eva запущена через systemd, то при останове контейнер удаляется.
		# Получить имя образа можно из конфигурации сервиса.
		set -o pipefail
		IMAGE="$(systemctl show --property=ExecStart ${CONTAINER_NAME}.service \
			| sed -E 's/.* (docker-registry.evateam.ru\/evateam:[^ ]*).*/\1/')"
		set +o pipefail
	else
		# Если не нашли какой образ использовать пока будем падать здесь, так удобней..
		# По идее для бэкапа достаточно shared тома, а контейнер подойдёт любой.
		# Если возникнет необходимость можно будет это зарешать.
		echo "Не смогли определить имя образа для выполнения бэкапа." >&2
		return 1
	fi
	if [[ $CONTAINER_ENGINE = podman && -f /etc/systemd/system/evateam.service ]]; then
		# CONTAINER_AS_SERVICE - может не стоять
		CONTAINER_AS_SERVICE=TRUE
	fi
	if [[ $IMAGE ]]; then
		IMAGE_TAG="${IMAGE##*:}"
	fi

	if [[ $CONTAINER_ENGINE = podman ]]; then
		CONTAINER_SEC_PARAMS+=" --security-opt label=disable"
	fi

	SHARED_VOL="$CONTAINER_VOLUME"
	# Здесь проверить удобней.
	if ! "$CONTAINER_ENGINE" volume inspect --format - "$SHARED_VOL"; then
		echo "Не смогли найти том $SHARED_VOL для выполнения бэкапа." >&2
		return 1
	fi
	return 0
}


do_prepare() {
	local ret
	# Создадим онлайн копию тома, чтобы снизить downtime
	echo "Создадим кеш бекапа для уменьшения downtime" >&2

	ct_state

	check_free_space

	if [[ ! -f $IMAGES_DIR/$IMAGE_TAG.tgz && ${ARG_IMAGE:-} ]]; then
		echo "Сохраняем докер образ" >&2
		backup_image
	fi
	echo "Сохраняем данные Eva: Том $SHARED_VOL" >&2
	mkdir -p "$PREPARE_DIR/$SHARED_VOL"
	"$CONTAINER_ENGINE" run $CONTAINER_SEC_PARAMS --rm \
		--volume="$SHARED_VOL:/mnt/shared" \
		--volume="$PREPARE_DIR/$SHARED_VOL:/mnt/backup" \
		"$IMAGE" rsync -a --stats --inplace --delete /mnt/shared/ /mnt/backup/ \
		&& ret=0 || ret=$?
	# TEM-1625030402
	# Бекап завершился ошибкой:
	# file has vanished: "/mnt/shared/postgresql/13/main/pg_wal/0000000100000047000000FD"
	# rsync warning: some files vanished before they could be transferred (code 24)
	# На этом этапе не критично, т.к. предварительный бекап.
	((ret != 0 && ret != 24)) && return "$ret"
	return 0
}


store_image() {
	local backup_dir_tmp="$1"
	touch "$backup_dir_tmp/image-$IMAGE_TAG"
	if [[ ! -f $IMAGES_DIR/$IMAGE_TAG.tgz && ${ARG_IMAGE:-} ]]; then
		backup_image
	fi
	if [[ -f $IMAGES_DIR/$IMAGE_TAG.tgz ]]; then
		ln "$IMAGES_DIR/$IMAGE_TAG.tgz" "$backup_dir_tmp/image.tgz"
	fi
	return 0
}


do_backup() {
	local ask backup_name="${ARG_BACKUP:-}" backup_dir_tmp timestamp

	echo "Check backup capability" >&2
	ct_state
	check_external_database
	check_free_space

	timestamp="$(date +%s)"
	if [[ ! $backup_name ]]; then
		backup_name="$(date -d @$timestamp +%Y-%m-%d_%H-%M-%S)"
	fi
	echo -n "Создаём резервную копию: name=$backup_name, container=$CONTAINER_NAME," >&2
	echo " volume=$SHARED_VOL, image=$IMAGE" >&2

	backup_dir_tmp="$BACKUPS_DIR/_${backup_name}.$$"
	mkdir -p "$backup_dir_tmp"

	echo "$timestamp" > "$backup_dir_tmp/timestamp"
	echo "$(date -d @$timestamp +%Y-%m-%d_%H-%M-%S)" > "$backup_dir_tmp/datetime"
	backup_configs "$backup_dir_tmp"

	store_image "$backup_dir_tmp"

	# TODO: eva_version_shared, eva_version_db
	if [[ $CT_RUNNINIG ]]; then
		echo "Остановим контейнер." >&2
		if [[ ${CONTAINER_AS_SERVICE:-} ]]; then
			systemctl stop "$CONTAINER_NAME"
		else
			"$CONTAINER_ENGINE" stop "$CONTAINER_NAME"
		fi
	fi

	if [[ -d "$PREPARE_DIR/$SHARED_VOL" ]]; then
		echo "Use cache $PREPARE_DIR/$SHARED_VOL" >&2
		mv "$PREPARE_DIR/$SHARED_VOL" "$backup_dir_tmp/"
	else
		mkdir "$backup_dir_tmp/$SHARED_VOL"
	fi
	echo "Copy $SHARED_VOL data" >&2
	# inplace иногда падает
	# rsync: open "/mnt/backup/log/postgresql/postgresql-13-main.log" failed:
	#   Permission denied (13)
	"$CONTAINER_ENGINE" run $CONTAINER_SEC_PARAMS --rm \
		--volume="$SHARED_VOL:/mnt/shared" \
		--volume="$backup_dir_tmp/$SHARED_VOL:/mnt/backup" \
		"$IMAGE" bash -c "\
		rsync -a --stats --inplace --delete /mnt/shared/ /mnt/backup/ \
		|| rsync -a --stats --delete /mnt/shared/ /mnt/backup/"
	# TODO: В архиве метаданные надёжней сохраняться, можно будет тома пожать.

	mv "$backup_dir_tmp" "$BACKUPS_DIR/$backup_name"
	if [[ ${ARG_ALIAS:-} ]]; then
		ln -sf --no-target-directory "$backup_name" "$BACKUPS_DIR/$ARG_ALIAS"
	fi
	if [[ $CT_RUNNINIG ]]; then
		echo "Запустим контейнер." >&2
		if [[ ${CONTAINER_AS_SERVICE:-} ]]; then
			systemctl start "$CONTAINER_NAME"
		else
			"$CONTAINER_ENGINE" start "$CONTAINER_NAME"
		fi
	fi
	return 0
}


restore_warning() {
	local shared_vol="$1" ask

	echo "Перед восстановлением из бэкапа, будут удалены" \
		"контейнеры $CONTAINER_NAME, $CONTAINER_NAME-update и том $shared_vol," \
		"если они существуют." >&2
	echo "Сделайте их резервные копии если это необходимо." >&2
	echo "Также будет заменён $CONFIG_PATH на сохранённую копию из бэкапа." >&2
	read -r -e -p "Продолжить [yes/no]: " ask
	if [[ $ask != [yY][eE][sS] ]]; then
		echo "Восстановдение резервной копии прервано."
		return 1
	fi
	return 0
}


before_restore_cleanup() {
	local shared_vol="$1"

	restore_warning "$shared_vol"


	if [[ $CONTAINER_ENGINE = podman && -f /etc/systemd/system/evateam.service ]]; then
		echo "Stop systemd service $CONTAINER_NAME" >&2
		systemctl stop "$CONTAINER_NAME"
	elif "$CONTAINER_ENGINE" container inspect --format=- "$CONTAINER_NAME" 2>/dev/null; then
		echo "Remove container $CONTAINER_NAME" >&2
		"$CONTAINER_ENGINE" rm --force --volumes "$CONTAINER_NAME"
	fi

	if "$CONTAINER_ENGINE" container inspect --format=- "$CONTAINER_NAME-update" \
		2>/dev/null; then
		echo "Remove container $CONTAINER_NAME-update" >&2
		"$CONTAINER_ENGINE" rm --force --volumes "$CONTAINER_NAME-update"
	fi

	if "$CONTAINER_ENGINE" volume inspect --format=- "$shared_vol" 2>/dev/null; then
		echo "Remove volume $shared_vol" >&2
		"$CONTAINER_ENGINE" volume rm --force "$shared_vol"
	fi
	return 0
}


do_restore() {
	local backup_name="$ARG_2" backup_dir shared_vol image

	backup_dir="$BACKUPS_DIR/$backup_name"
	# Берём настройки из бэкапа?
	source "$backup_dir/$CONFIG_NAME"
	shared_vol="$(<$backup_dir/shared_volume_name)"

	before_restore_cleanup "$shared_vol"

	if [[ $CONTAINER_ENGINE = podman ]]; then
		CONTAINER_SEC_PARAMS+=" --security-opt label=disable"
	fi

	# restore
	if [[ -f $CONFIG_PATH ]] \
		&& ! diff -q $CONFIG_PATH "$backup_dir/$CONFIG_NAME"; then
		mv "$CONFIG_PATH" "${CONFIG_PATH}.restore.$(date +%Y-%m-%d-%H-%M-%S)"
	fi
	echo "Restore $CONFIG_PATH" >&2
	cp "$backup_dir/$CONFIG_NAME" "$CONFIG_PATH"
	image="$(<$backup_dir/image_name)"
	if ! "$CONTAINER_ENGINE" image inspect --format - "$image"; then
		if [[ -f "$backup_dir/image.tgz" ]]; then
			echo "Загрузим образ $image из $backup_dir/image.tgz" >&2
			set -o pipefail
			gzip -dc "$backup_dir/image.tgz" | "$CONTAINER_ENGINE" image load
			set +o pipefail
		else
			echo "Загрузим образ $image из репозитория" >&2
			"$CONTAINER_ENGINE" pull "$image"
		fi
	fi
	if [[ ! -d $backup_dir/$shared_vol && -f $backup_dir/$shared_vol.tgz ]]; then
		echo "Расспакуем данные тома из $backup_dir/$shared_vol.tgz" >&2
		mkdir "$backup_dir/$shared_vol"
		tar --numeric-owner -xzf "$backup_dir/$shared_vol.tgz" -C "$backup_dir/$shared_vol"
	fi
	echo "Скопируем данные тома $shared_vol" >&2
	"$CONTAINER_ENGINE" run $CONTAINER_SEC_PARAMS --rm \
		--volume="$shared_vol:/mnt/shared" \
		--volume="$backup_dir/$shared_vol:/mnt/backup" \
		"$image" rsync -a --delete --stats /mnt/backup/ /mnt/shared/
	# Run restored container
	if [[ $CONTAINER_ENGINE = podman && -f $backup_dir/evateam.service ]]; then
		echo "Restore and run systemd service $CONTAINER_NAME" >&2
		cp $backup_dir/evateam.service /etc/systemd/system/evateam.service
		systemctl daemon-reload
		systemctl enable "${CONTAINER_NAME}.service"
		systemctl start "${CONTAINER_NAME}.service"
	else
		echo "Run container $CONTAINER_NAME" >&2
		/opt/eva_admin/eva-docker.sh run --name="${CONTAINER_NAME:-evateam}"
	fi
	return 0
}


main() {
	local cmd="$ARG_1"
	if [[ $cmd = list ]]; then
		do_list "$@"
		return 0
	fi
	set -x
	if pidof -csxo %PPID "${0##*/}"; then
		echo "Already running" >&2
		return 1
	fi
	mkdir -p "$BACKUPS_DIR"
	if [[ $cmd = backup ]]; then
		do_backup "$@"
	elif [[ $cmd = prepare ]]; then
		do_prepare "$@"
	elif [[ $cmd = restore ]]; then
		do_restore "$@"
	else
		echo "Invalid command $cmd" >&2
		return 1
	fi
	return 0
}


main "$@"
exit 0
