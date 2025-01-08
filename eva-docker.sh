#!/bin/bash
set -eu
### --help Info: Скрипт управления контейнером EvaTeam
### --help Usage: /opt/eva_admin/eva-docker.sh [--name=evateam] <command>
### --help Usage: commands:
### --help Usage:     install - развёртывание новой установки
### --help Usage:     apply - применений новой конфигурации, контейнер будет пересоздан.
### --help Usage:     run - создание и запуск контейнера
### --help Usage:     start - запуск контейнера
### --help Usage:     stop - останов контейнера
### --help Usage:     restart - перезапуск контейнера
### --help Usage:     rm [--volume] [--force] - удаление контейнера
### --help Usage:         и всех данных, если указан --volume
### --help Usage:         --force - не спрашивать подтверждения
### --help Usage:     exec - выполнение -ti bash, TODO: проброс $@
### --help Usage: --name=test1 - использовать файл конфигурации контейнера /opt/eva_admin/CONFIG-test1
### --help Example: /opt/eva_admin/eva-docker.sh install
# TODO: --print or --dry-run - вывод команд без их применения.

. /opt/eva_admin/crab_sys.sh


if [[ ${1:-} = --help || ${1:-} ]]; then
	sys::usage "$@"
fi


declare ARG_1 ARG_NAME ARG_FORCE ARG_VOLUME
sys::arg_parse "$@"


declare BASH_REMATCH
declare COMMAND="${ARG_1:-}"
declare _NAME="${ARG_NAME:-evateam}"
declare CONFIG_PATH="/opt/eva_admin/CONFIG${ARG_NAME:+-$ARG_NAME}"

declare OFFLINE
declare ROOTLESS
declare BRANCH
declare VERSION
declare SELECTED_PRODUCT
declare CONF_DOMAIN
declare CONF_CERTBOT
declare CONF_ADMIN_EMAIL
declare CONF_TZ
declare CONF_MEMORY_LIMIT_GB
declare HTTP_PORT
declare HTTPS_PORT
declare CONTAINER_NAME
declare CONTAINER_VOLUME
declare CONTAINER_ENGINE
declare CONTAINER_PARAMS
declare PODMAN_SECURITY_OPTS
declare DOCKER_IMAGE
declare CONTAINER_CUSTOM_PARAMS
declare CONTAINER_AS_SERVICE
declare EVA_CONFIG__EXTERNAL_PORT_HTTPS

[[ ! -e "${CONFIG_PATH:-}" ]] && CONFIG_PATH="/opt/eva_admin/CONFIG"
source "$CONFIG_PATH"


if [[ ! ${NAME:-} ]]; then
	NAME="$_NAME"
elif [[ $NAME != $_NAME ]]; then
	echo "Параметр NAME=$NAME в файле $CONFIG_PATH не соответствует аргументу --name=$_NAME" >&2
	exit 1
fi


check_already_exists() {
	if "$CONTAINER_ENGINE" volume inspect "$CONTAINER_VOLUME" &>/dev/null; then
		echo "Ошибка! $CONTAINER_ENGINE volume $CONTAINER_VOLUME - уже существует!"
		echo "Возможно, Вы уже запускали установку EvaTeam."
		echo "Для переустановки системы удалите volume $CONTAINER_VOLUME"
		echo " если он не используется."
		echo "Внимание! Данные установленной системы в этом случае тоже удалятся!"
		exit 1
	fi
	if $CONTAINER_ENGINE container inspect "$CONTAINER_NAME" &>/dev/null; then
		echo "Ошибка! $CONTAINER_ENGINE container $CONTAINER_NAME - уже существует!"
		echo "Возможно, Вы уже запускали установку EvaTeam."
		echo " Для переустановки системы удалите контейнер"
		echo " если он не используется."
		exit 1
	fi
	return 0
}


download_image() {
	if [[ ! $DOCKER_IMAGE ]]; then
		if [[ ! ${VERSION:-} ]]; then
			VERSION="$(\
				/opt/eva_admin/eva_versions.py get-version-for-install -b "${BRANCH}")"
		fi
		DOCKER_IMAGE="$(\
			/opt/eva_admin/eva_versions.py get-docker-image-name -v "${VERSION}" -b "${BRANCH}")"
	fi
	echo "Будет установлена версия $VERSION ($DOCKER_IMAGE)"
	"$CONTAINER_ENGINE" pull "$DOCKER_IMAGE"
	return 0
}


disable_webservices() {
	if [ "$ROOTLESS" != "TRUE" ]; then
		# Мб спрашивать, или делать только если контейнер биндится на стандартные порты...
		systemctl stop apache2 2>/dev/null || true
		systemctl stop nginx 2>/dev/null || true
		systemctl stop httpd 2>/dev/null || true
		systemctl disable apache2 2>/dev/null || true
		systemctl disable nginx 2>/dev/null || true
		systemctl disable httpd 2>/dev/null || true
	fi
	return 0
}


configure_volume() {
	echo "Сохраняем конфигурацию"
	"$CONTAINER_ENGINE" run --rm \
		-e "EVA_CONFIG__DOMAIN=$CONF_DOMAIN" \
		-e "EVA_CONFIG__WZ_FULL_HOSTNAME=$CONF_DOMAIN" \
		-e "EVA_CONFIG__ADMIN_EMAIL=$CONF_ADMIN_EMAIL" \
		-e "EVA_CONFIG__NGINX_USE_CERTBOT=$CONF_CERTBOT" \
		-e "EVA_CONFIG__MEMORY_LIMIT_GB=$CONF_MEMORY_LIMIT_GB" \
		"--mount=type=volume,source=$CONTAINER_VOLUME,target=/mnt/shared" --volume=/mnt/tmp \
		${CONTAINER_CUSTOM_PARAMS:-} \
		"$DOCKER_IMAGE" /opt/bin/eva_init.sh
	return 0
}


register_admin() {
	echo "Регистрируем лицензию"
	if [[ $SELECTED_PRODUCT ]]; then
		local pyexec="models.CmfLicense.landing_page2license(code=\"$SELECTED_PRODUCT\")"
		"$CONTAINER_ENGINE" run --rm \
			"--mount=type=volume,source=$CONTAINER_VOLUME,target=/mnt/shared" --volume=/mnt/tmp \
			${CONTAINER_CUSTOM_PARAMS:-} \
			--workdir=/opt/eva-app \
			"$DOCKER_IMAGE" bash -c \
			"set -e; /opt/bin/eva_init.sh; python3 manage.py shell '$pyexec'"
	fi
	echo "Регистрируем администратора в системе"
	"$CONTAINER_ENGINE" run --rm \
		"--mount=type=volume,source=$CONTAINER_VOLUME,target=/mnt/shared" --volume=/mnt/tmp \
		"$DOCKER_IMAGE" bash -c "set -e; /opt/bin/eva_init.sh; /opt/bin/register.sh"
	return 0
}


prepare_params(){
	local container_port=''
	CONTAINER_PARAMS=""
	if [[ $CONTAINER_ENGINE = podman ]]; then
		PODMAN_SECURITY_OPTS=" --security-opt label=type:${CONTAINER_NAME}.process"
		CONTAINER_PARAMS+=" --http-proxy=false"
		CONTAINER_PARAMS+=" $PODMAN_SECURITY_OPTS"
	else
		CONTAINER_PARAMS+=" --restart=always"
	fi
	CONTAINER_PARAMS+=" --shm-size=8g --stop-timeout=60"
	CONTAINER_PARAMS+=" --mount=type=volume,source=$CONTAINER_VOLUME,target=/mnt/shared"
	[[ $CONTAINER_ENGINE = podman ]] && CONTAINER_PARAMS+=",relabel=private"
	CONTAINER_PARAMS+=" --volume=/mnt/tmp"
	CONTAINER_PARAMS+=" -h $CONF_DOMAIN -e TZ=$CONF_TZ"
	if [[ $HTTP_PORT ]]; then
		container_port=80
		if [[ ${VERSION:-} && $VERSION > v02.23.00.000 ]] \
			|| [[ $DOCKER_IMAGE =~ .*(astra).* ]]; then
			container_port=1080
		fi
		CONTAINER_PARAMS+=" -p $HTTP_PORT:$container_port/tcp"
	fi
	if [[ $HTTPS_PORT ]]; then
		container_port=443
		if [[ ${VERSION:-} && $VERSION > v02.24.01.1695 ]] \
			|| [[ $DOCKER_IMAGE =~ .*(astra).* ]]; then
			container_port=1443
		fi
		CONTAINER_PARAMS+=" -p $HTTPS_PORT:$container_port/tcp"
	fi
	CONTAINER_PARAMS+=" ${CONTAINER_CUSTOM_PARAMS:-}"

	local container_var
	for container_var in "${!EVA_CONFIG__@}"; do
		CONTAINER_PARAMS+=" -e $container_var=${!container_var}"
	done

	if grep -qE ^CONTAINER_PARAMS= "$CONFIG_PATH"; then
		sed -i -Ee "s~^CONTAINER_PARAMS=.*~CONTAINER_PARAMS='$CONTAINER_PARAMS'~" \
			"$CONFIG_PATH"
	else
		echo "CONTAINER_PARAMS='$CONTAINER_PARAMS'" >>"$CONFIG_PATH"
	fi

	sed -i -Ee "/^# Run Command:.*/ d" "$CONFIG_PATH"
	echo "# Run Command:" \
		"$CONTAINER_ENGINE run -d --name $CONTAINER_NAME $CONTAINER_PARAMS $DOCKER_IMAGE" \
		>>"$CONFIG_PATH"
	return 0
}


run_docker() {
	# echo "Создаем $CONTAINER_ENGINE volume $CONTAINER_VOLUME для хранения данных"
	# "$CONTAINER_ENGINE" volume create "$CONTAINER_VOLUME"
	prepare_params

	if [[ $CONTAINER_ENGINE = podman ]] \
		&& (! semodule -l | grep "${CONTAINER_NAME}"); then
		# На этом этапе политики ещё не существует, её надо создать на основе
		# запущенного контейнера
		"$CONTAINER_ENGINE" run -d --name $CONTAINER_NAME \
			${CONTAINER_PARAMS/$PODMAN_SECURITY_OPTS} \
			--entrypoint sleep "$DOCKER_IMAGE" 1000
		mkdir -p /opt/eva_admin/udica
		(
			cd /opt/eva_admin/udica
			set -o pipefail
			podman inspect "$CONTAINER_NAME" \
				| udica "$CONTAINER_NAME" --full-network-access --load-modules
			set +o pipefail
			semodule -i "${CONTAINER_NAME}.cil" \
				/usr/share/udica/templates/{base_container.cil,net_container.cil}
		)
		"$CONTAINER_ENGINE" stop "$CONTAINER_NAME" -t 0
		"$CONTAINER_ENGINE" rm "$CONTAINER_NAME"
	fi
	echo "Запускаем контейнер EvaTeam"
	"$CONTAINER_ENGINE" run -d --name "$CONTAINER_NAME" $CONTAINER_PARAMS "$DOCKER_IMAGE"
	return 0
}



make_podman_autorun() {
	if [[ $CONTAINER_AS_SERVICE != TRUE ]]; then
		echo "Для автоматического запуска контейнера нужно создать systemd-сервис:"
		echo " podman generate systemd --new --name $CONTAINER_NAME " \
			"--restart-policy=always > /etc/systemd/system/$NAME.service"
		echo " systemctl enable $NAME.service"
		echo " systemctl restart $NAME.service"
		echo
		return 0
	fi
	echo "Create and restart service /etc/systemd/system/$NAME.service"
	podman generate systemd --new --name "$CONTAINER_NAME" --restart-policy=always \
		>"/etc/systemd/system/$NAME.service"
	# MCS метки могут плавать (см. BCRM TEM-1625035082)
	# Поменять shared на private, если нужна будет безопасность
	# ? systemctl daemon-reload
	systemctl enable "$NAME.service"
	systemctl restart "$NAME.service"
	return 0
}


echo_info() {
	local port_spec="${EVA_CONFIG__EXTERNAL_PORT_HTTPS:+:$EVA_CONFIG__EXTERNAL_PORT_HTTPS}"
	echo
	echo
	echo "Установка завершена!"
	echo
	echo "Реквизиты для доступа:"
	echo
	echo "======================="
	echo "Доступ в EvaTeam: https://$CONF_DOMAIN$port_spec/"
	echo "Сервер авторизации: https://$CONF_DOMAIN$port_spec/auth"
	echo
	echo "Логин: $CONF_ADMIN_EMAIL"
	echo "Пароль: servicemode"
	echo "======================="
	echo
	echo "Команда для запуска обновления: /opt/bin/update.sh"
	echo "Для редактирования конфига:"
	echo "  vim /opt/CONFIG"
	echo "Конфигурация применяется при перезапуске контейнера:"
	echo "  $CONTAINER_ENGINE restart $CONTAINER_NAME"
	echo "Для входа в контейнер: $CONTAINER_ENGINE exec -ti $CONTAINER_NAME /bin/bash"
	echo
	echo "Изменяемые данные контейнер хранит в $CONTAINER_ENGINE volume $CONTAINER_VOLUME"
	echo
	echo
	return 0
}


do_install() {
	check_already_exists

	if [[ $OFFLINE = TRUE ]]; then
		# INSTALL_VERSION:
		# docker-registry.evateam.ru/evateam:public-v02.21.01.1109-release-official
		declare INSTALL_VERSION
		. /opt/eva_admin/eva_docker_dist/update_config
		if [ ! -f /opt/eva_admin/eva_docker_dist/download_done ]; then
			echo "Файлы для установки не загружены до конца!"
			exit 1
		fi
		"$CONTAINER_ENGINE" load \
			-i "/opt/eva_admin/eva_docker_dist/${INSTALL_VERSION##*:}.tar.gz"
		if ! [[ $INSTALL_VERSION =~ v[0-9.]{13} ]]; then
			echo "Неправильный формат версии $INSTALL_VERSION, используйте v01.02.03.0004" >&2
			return 1
		fi
		VERSION=${BASH_REMATCH}
		DOCKER_IMAGE="$INSTALL_VERSION"
	else
		download_image
	fi
	# Save VERSION DOCKER_IMAGE to CONFIG
	if grep -qE ^VERSION= "$CONFIG_PATH"; then
		sed -i -Ee "s/^VERSION=.*/VERSION='$VERSION'/" "$CONFIG_PATH"
	else
		echo "VERSION=$VERSION" >>"$CONFIG_PATH"
	fi
	if grep -qE ^DOCKER_IMAGE= "$CONFIG_PATH"; then
		sed -i -Ee "s~^DOCKER_IMAGE=.*~DOCKER_IMAGE='$DOCKER_IMAGE'~" "$CONFIG_PATH"
	else
		echo "DOCKER_IMAGE=$DOCKER_IMAGE" >>"$CONFIG_PATH"
	fi
	disable_webservices
	configure_volume
	register_admin
	run_docker
	if [[ $CONTAINER_ENGINE = podman ]]; then
		make_podman_autorun
	fi
	echo_info
	return 0
}


do_apply() {
	# fix config defaults
	if "$CONTAINER_ENGINE" container inspect "$CONTAINER_NAME" &>/dev/null; then
		"$CONTAINER_ENGINE" rm --force "$CONTAINER_NAME"
	fi
	configure_volume
	run_docker
	return 0
}


do_run() {
	run_docker
	return 0
}


do_rm() {
	if [[ ${ARG_VOLUME:-} && ! ${ARG_FORCE:-} ]]; then
		echo "Удаление тома $CONTAINER_VOLUME приведёт к безвозвратной потере данных Eva."
		echo -n "Вы действительно хотите удалить том $CONTAINER_VOLUME?(yes/no):"
		local reply
		read -r reply
		if [[ ${reply:0:1} != [yYдД] ]]; then
			echo "Удаление тома отменено."
			exit 1
		fi
	fi
	"$CONTAINER_ENGINE" rm --force --volumes "$CONTAINER_NAME"
	if [[ ${ARG_VOLUME:-} ]] && \
		"$CONTAINER_ENGINE" volume inspect "$CONTAINER_VOLUME" &>/dev/null; then
		"$CONTAINER_ENGINE" volume rm "$CONTAINER_VOLUME"
	fi
	return 0
}


do_exec() {
	"$CONTAINER_ENGINE" exec -ti "$CONTAINER_NAME" bash
	return 0
}


main() {
	if [[ $COMMAND = install ]]; then
		do_install
	elif [[ $COMMAND = apply ]]; then
		do_apply
	elif [[ $COMMAND = run ]]; then
		do_run
	elif [[ $COMMAND = rm ]]; then
		do_rm
	elif [[ $COMMAND = exec ]]; then
		# TODO: shift eva options
		do_exec "$@"
	elif [[ $COMMAND =~ ^(start|stop|restart)$ ]]; then
		"$CONTAINER_ENGINE" "$COMMAND" "$CONTAINER_NAME"
	else
		echo "Неверная команда: $COMMAND"
		sys::usage "$@"
	fi
	return 0
}


main "$@"


exit 0
