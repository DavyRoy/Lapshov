#!/bin/bash
set -eu
### --help Info: Скрипт установки EvaTeam
### --help Usage: --offline - установка без доступа к интернету
### --help Usage: --rootless - установка без привилегий root
### --help Usage:    в этом режиме Docker уже должен быть установлен и настроен
### --help Usage: --container-engine=podman - для использования определённого движка
### --help Usage: --version=v02.00.00.0000 - для установки определённой версии
### --help Usage: --branch=devel - для установки из определённой из определённой ветки
### --help Usage: --name=test1 - создать новый экземпляр с конфигом /opt/eva_admin/CONFIG-test1
### --help Usage:     контейнером test1, томом test1-shared
### --help Example: /opt/eva_admin/install_docker.sh

. /opt/eva_admin/crab_sys.sh


if [[ ${1:-} = --help || ${1:-} ]]; then
	sys::usage "$@"
fi


declare ARG_OFFLINE
declare ARG_ROOTLESS
declare ARG_CONTAINER_ENGINE
declare ARG_VERSION
declare ARG_BRANCH
declare ARG_NAME
sys::arg_parse "$@"


declare OFFLINE="${ARG_OFFLINE:-}"
declare ROOTLESS="${ARG_ROOTLESS:-}"
declare BRANCH="${ARG_BRANCH:-release}"
declare VERSION="${ARG_VERSION:-}"

declare SELECTED_PRODUCT=
declare CONF_DOMAIN=
declare CONF_CERTBOT=
declare CONF_ADMIN_EMAIL=
declare CONF_TZ=
declare CONF_MEMORY_LIMIT_GB=
declare HTTP_PORT=
declare HTTPS_PORT=0.0.0.0:443
declare EVA_CONFIG__EXTERNAL_PORT_HTTPS

declare NAME="${ARG_NAME:-evateam}"
declare CONFIG_PATH="/opt/eva_admin/CONFIG${ARG_NAME:+-$ARG_NAME}"
declare CONTAINER_NAME="$NAME"
declare CONTAINER_VOLUME="$NAME-shared"
declare CONTAINER_ENGINE
declare CONTAINER_AS_SERVICE=


check_is_root() {
	if [ "$ROOTLESS" = "TRUE" ]; then
		return 0
	fi
	if [ "$(id -u)" != "0" ]; then
		echo "Скрипт установки нужно запускать от суперпользователя root!"
		exit 0
	fi
	return 0
}


greetings() {
	echo "Добро пожаловать в скрипт установки EvaTeam!"
	echo
	echo "Скрипт проведет:"
	echo " - Установку компонентов Docker"
	echo " - Установку docker-контейнера EvaTeam"
	echo " - Настройку EvaTeam"
	echo
	echo "Системные требования:"
	echo " - ОС Ubuntu 20.04"
	echo " - минимум 8GB оперативной памяти"
	echo " - 8 ядер от 3 ГГц"
	echo
	return 0
}


ask_configuration_product() {
	echo
	echo "Выберите продукт для установки"
	echo "1) EvaProject"
	echo "2) EvaWiki"
	echo "3) Eva Full Install (EvaProject, EvaWiki, EvaServiceDesk, EvaHelpdesk)"
	echo -n "Введите номер продукта: "
	local selected_product_id
	read -r selected_product_id
	while true; do
		if [ "$selected_product_id" = "1" ]; then
			SELECTED_PRODUCT="evaproject"
		elif [ "$selected_product_id" = "2" ]; then
			SELECTED_PRODUCT="evawiki"
		elif [ "$selected_product_id" = "3" ]; then
			# SELECTED_PRODUCT="EvaFullInstall"
			# Оставляем лицензию пустой
			:
		else
			echo "Нет такого продукта"
			echo -n "Введите номер продукта: "
			read -r selected_product_id
			continue
		fi
		break
	done
	return 0
}


ask_configuration_domain() {
	# TODO: возможность регистрации без домена
	echo
	echo "Укажите полное имя сервера, на котором будет запущена EvaTeam"
	echo "Например: evateam.my-company.ru"
	# echo "Либо оставьте пустым, тогда доступ будет по IP-адресу сервера"
	# echo -n "Домен [${IP}]: "
	echo -n "Домен: "
	read -r CONF_DOMAIN
	while true; do
		# if [ -n "$CONF_DOMAIN" ]; then
		if ! echo "$CONF_DOMAIN" | grep -q -P '[-a-z0-9\.]+'; then
			echo "Неверно указан домен: $CONF_DOMAIN"
			echo "Укажите домен, без лишних символов"
			# echo -n "Домен [${IP}]: "
			echo -n "Домен: "
			read -r CONF_DOMAIN
			continue
		fi
		if [[ "$CONF_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			echo "Неверно указан домен: $CONF_DOMAIN"
			echo "Вы указали IP-адрес, нужно указать доменное имя"
			echo "Например: evateam.my-company.ru"
			echo -n "Домен: "
			read -r CONF_DOMAIN
			continue
		fi

		# fi
		break
	done
	return 0
}


ask_configuration_ssl() {
	CONF_CERTBOT=0
	if [ -n "$CONF_DOMAIN" ]; then
		echo
		echo "Укажите тип SSL-сертификата"
		echo " 1 - получить бесплатный сертификат Lets Encrypt*"
		echo " 2 - Вы подключите свой сертификат"
		echo "* для получения сертификата домен должен быть доступен из интернета"
		echo -n "Тип SSL: "
		local ssl
		read -r ssl
		while true; do
			if [ "$ssl" = 1 ]; then
				CONF_CERTBOT=1
			elif [ "$ssl" = 2 ]; then
				CONF_CERTBOT=0
			else
				echo -n "Укажите 1 или 2: "
				read -r ssl
				continue
			fi
			break
		done
	fi

	echo
	echo -n "Введите email администратора: "
	read -r CONF_ADMIN_EMAIL
	echo
	return 0
}


ask_configuration_tz() {
	local default_tz="$(timedatectl show --value -p Timezone || true)"
	if [ -z "$default_tz" ]; then
		default_tz="Europe/Moscow"
	fi

	echo
	echo "Укажите часовой пояс в формате linux TZ"
	echo "Например: Europe/Moscow"
	echo "Или оставьте значение пустым, чтобы выбрать часовой пояс $default_tz"
	echo "Полный список часовых поясов можно посмотреть командой timedatectl list-timezones"
	echo -n "TZ: "
	read -r CONF_TZ
	while true; do
		if [ -z "$CONF_TZ" ]; then
			# default
			CONF_TZ="$default_tz"
			break
		fi
		if ! timedatectl list-timezones | grep -q "$CONF_TZ" ; then
			echo "Неверно указан часовой пояс: $CONF_TZ"
			echo "Укажите часовой пояс, без лишних символов и с учетом регистра"
			echo "Полный список часовых поясов можно посмотреть командой timedatectl list-timezones"
			echo -n "TZ: "
			read -r CONF_TZ
			continue
		fi
		break
	done
	return 0
}


ask_configuration_mem() {
	echo
	echo "Укажите количество выделяемой оперативной памяти в гигабайтах"
	echo "Минимум 8Гб"
	echo -n "Mem (Гб): "
	read -r CONF_MEMORY_LIMIT_GB
	while true; do
		if ! [[ "$CONF_MEMORY_LIMIT_GB" =~ ^[0-9]+$ ]]; then
			echo "Недопустимое значение. Укажите количество выделяемой оперативной памяти в гигабайтах целым числом"
			echo -n "Mem (Гб): "
			read -r CONF_MEMORY_LIMIT_GB
			continue
		fi
		if [ "$CONF_MEMORY_LIMIT_GB" -lt "8" ]; then
			echo "Минимальное значение оперативной памяти - 8Гб"
			echo -n "Mem (Гб): "
			read -r CONF_MEMORY_LIMIT_GB
			continue
		fi
		if [ "$CONF_MEMORY_LIMIT_GB" -gt "256" ]; then
			echo "Вы указали слишком большое значение оперативной памяти: ${CONF_MEM}Гб, вероятно это опечатка"
			echo "Если это не опечатка, укажите значение ниже, а после установки отредактируйте значние в конфигурации"
			echo -n "Mem (Гб): "
			read -r CONF_MEMORY_LIMIT_GB
			continue
		fi
		break
	done
	return 0
}


ask_ports() {
	local user_input https_port=

	echo
	echo "Укажите HTTPS порт для контейнера: [host_ip:]port"
	echo "  примеры: 443, 10443, 1.2.3.4:443, 0.0.0.0:10443, 127.0.0.1:443"
	echo "  или '-', если не требуется."
	while true; do
		echo -n "HTTPS port [${HTTPS_PORT}]: "
		read -r user_input
		if [[ ! $user_input ]]; then
			:
		elif [[ $user_input = - ]]; then
			HTTPS_PORT=
		elif [[ $user_input =~ ^([0-9.]+:)?([0-9]+)$ ]]; then
			HTTPS_PORT="$user_input"
			https_port="${BASH_REMATCH[2]}"
		else
			echo " !!! Неверное значение для порта($user_input)" >&2
			continue
		fi
		break
	done


	# Для нестандартного порта вероятно нужен фикс URL сервиса.
	# А может сразу спрашивать номер внешнего https порта для других сценариев.
	# EVA_CONFIG__EXTERNAL_PORT_HTTPS
	if [[ $https_port && $https_port != 443 ]]; then
		echo
		echo "Вы указали нестандартный HTTPS порт $https_port."
		echo "Для правильной работы cookie и служебных переадресаций" \
			" может потребоваться добавить его в URL."
		echo "Если вы планируете для сервиса Eva использовать" \
			" URL https://$CONF_DOMAIN:$https_port/ введите yes"
		echo "Если планируете использовать URL https://$CONF_DOMAIN/" \
			"на proxy сервере, а порт $https_port будет использован" \
			" только для терминации proxy трафика, введите no"
		local reply
		while true; do
			echo -n "Использовать номер порта($https_port) в URL (ДА/нет) ?"
			read reply
			if [[ ! $reply || $reply = [yYдД]* ]]; then
				EVA_CONFIG__EXTERNAL_PORT_HTTPS="$https_port"
				break
			elif [[ $reply = [nNнН]* ]]; then
				break
			else
				echo "Ответьте да или нет"
			fi
		done
	fi


	echo
	echo "Укажите HTTP порт для контейнера, применимо, если используется прокси сервер для терминации https: [host_ip:]port"
	echo "  примеры: 80, 8080, 1.2.3.4:80, 0.0.0.0:10080"
	echo "  или '-', если не требуется."
	while true; do
		echo -n "HTTP port [${HTTP_PORT:--}]: "
		read -r user_input
		if [[ ! $user_input ]]; then
			:
		elif [[ $user_input = - ]]; then
			HTTP_PORT=
		elif [[ $user_input =~ ^([0-9.]+:)?[0-9]+$ ]]; then
			HTTP_PORT="$user_input"
		else
			echo " !!! Неверное значение для порта($user_input)" >&2
			continue
		fi
		break
	done

	return 0
}


check_container_engine() {
	echo "Определяем систему запуска контейнера..."
	# TODO: read from config if exists
	# if set on startup
	if [[ ${CONTAINER_ENGINE:-} =~ ^(docker|podman)$ ]]; then
		:
	elif which docker &>/dev/null; then
		CONTAINER_ENGINE=docker
	elif which podman &>/dev/null; then
		CONTAINER_ENGINE=podman
	fi
	if [ ! -z "${CONTAINER_ENGINE:-}" ]; then
		echo "Обнаружен: $CONTAINER_ENGINE"
		return 0
	fi

	echo
	echo "Для ОС Ubuntu/Debian скритп установки может самостоятельно установить Docker."
	echo "Для установки на других ОС, установки Rootless Docker или для развертывания в Podman
   - нужно настроить их самостоятельно и перезапустить скрипт установки"
	echo "Если Вы хотите самостоятельно установить систему запуска контейнеров - напишите нет"
	echo

	local ans=-1
	local reply
	while [ "$ans" -eq "-1" ]; do
		echo -n "Установить Docker в автоматическом режиме (да/нет) ?" ; read reply
		if [ "${reply:0:1}" = 'y' -o  "${reply:0:1}" = 'Y' -o  "${reply:0:1}" = 'д' -o  "${reply:0:1}" = 'Д' ]; then
			ans=1
		elif [ "${reply:0:1}" = 'n' -o  "${reply:0:1}" = 'N' -o  "${reply:0:1}" = 'н' -o  "${reply:0:1}" = 'Н' ]; then
			ans=0
		else
			echo "Ответьте да или нет"
		fi
	done

	if [ "$ans" = "0" ]; then
		echo "Для установки Docker или Podman можете восспользоваться документацией Вашего дистрибутива ОС."
		echo "Также ознакомьтесь с документацией по установке, раздел ручной устновки зависимостей:"
		echo "https://docs.evateam.ru/docs/docs/DOC-000380#ustanovka-i-obnovlenie"
		echo
		echo "После этого запустите заново скрипт установки"
		exit 0
	fi
	install_docker
	CONTAINER_ENGINE='docker'
	return 0
}


check_requirements() {
	local packages os_like
	packages=( curl jq python3 udica )
	os_like="$(set -e; source /etc/os-release; echo ${ID_LIKE:-$ID})"
	if [[ ${os_like,,} == debian ]]; then
		os_like="debian"
	elif [[ ${os_like,,} =~ (rhel|centos|fedora) ]]; then
		os_like="rhel"
	fi

	echo "Проверка зависимостей..."
	echo "Тип ОС: $os_like"
	local ok=1
	for package in ${packages[@]}; do
		if ! which $package &>/dev/null; then
			[[ $package == "udica" && ! $os_like == "rhel" ]] && continue
			echo "$package - не найден"
			ok=0
		else
			echo "$package - ок"
		fi
	done
	if [ "$ok" = "1" ]; then
		return 0
	fi

	echo "Требуется установить в систему пакеты: curl jq python3 и udica (для RHEL и подобных)"
	echo "Примеры установки в разных дистрибутивах:"
	echo "Ubuntu: sudo apt install -y curl jq python3"
	echo "AlmaLinux: sudo dnf install -y curl jq python39 udica"
	echo
	if [ "$ROOTLESS" = "TRUE" ] || [ "$OFFLINE" = 'TRUE' ]; then
		echo
		echo "Для Rootless или offline установки Вам необходимо самостоятельно установить пакеты"
		echo
		echo "Подробности в документации по установке, раздел ручной устновки зависимостей:"
		echo "https://docs.evateam.ru/docs/docs/DOC-000380#ustanovka-i-obnovlenie"
		echo
		echo "После установки пакетов запустите заново скрипт установки"
		echo
		exit 0
	fi

	echo "Для ОС Ubuntu скритп установки может самостоятельно установить требуемые пакеты."
	echo "Если Вы хотите самостоятельно установить пакеты - напишите нет"
	echo

	local ans=-1
	local reply
	while [ "$ans" -eq "-1" ]; do
		echo -n "Установить пакеты в автоматическом режиме (да/нет) ?" ; read reply
		if [ "${reply:0:1}" = 'y' -o  "${reply:0:1}" = 'Y' -o  "${reply:0:1}" = 'д' -o  "${reply:0:1}" = 'Д' ]; then
			ans=1
		elif [ "${reply:0:1}" = 'n' -o  "${reply:0:1}" = 'N' -o  "${reply:0:1}" = 'н' -o  "${reply:0:1}" = 'Н' ]; then
			ans=0
		else
			echo "Ответьте да или нет"
		fi
	done

	if [ "$ans" = "0" ]; then
		echo
		echo "Подробности в документации по установке, раздел ручной устновки зависимостей:"
		echo "https://docs.evateam.ru/docs/docs/DOC-000380#ustanovka-i-obnovlenie"
		echo
		echo "После установки пакетов запустите заново скрипт установки"
		echo
		exit 0
	fi

	cat /etc/os-release

	if [[ $os_like == "debian" ]]; then
		apt update
		apt install -y curl jq python3
	elif [[ $os_like == "rhel" ]]; then
		dnf install -y curl jq python3 udica
	fi
	return 0
}


install_docker() {
	if [ "$ROOTLESS" = "TRUE" ]; then
		return 0
	fi
	# dnf install -y podman
	if which docker &>/dev/null; then
		# Docker может стоять, но сервер не запущен.
		systemctl start docker
		systemctl enable docker
		echo "Docker уже установлен"
		return 0
	fi
	echo "Устанавливаем компоненты Docker"
	apt update
	apt install -y docker.io  # docker-compose
	return 0
}


check_already_exists() {
	# TODO: false-negative check if docker inspect other reasons fail
	if "$CONTAINER_ENGINE" volume inspect "$CONTAINER_VOLUME" &>/dev/null; then
		echo "Ошибка! $CONTAINER_ENGINE volume $CONTAINER_VOLUME - уже существует!"
		echo "Возможно, Вы уже запускали установку EvaTeam. Для переустановки системы удалите volume evateam-shared"
		echo " если он не используется."
		echo "Внимание! Данные установленной системы в этом случае тоже удалятся!"
		exit 1
	fi
	if $CONTAINER_ENGINE container inspect "$CONTAINER_NAME" &>/dev/null; then
		echo "Ошибка! $CONTAINER_ENGINE container $CONTAINER_NAME - уже существует!"
		echo "Возможно, Вы уже запускали установку EvaTeam. Для переустановки системы удалите контейнер"
		echo " если он не используется."
		exit 1
	fi
	# TODO: ask read default values from existent config
	if [[ -f $CONFIG_PATH ]]; then
		echo "Переименуем существующий конфиг $CONFIG_PATH"
		mv "$CONFIG_PATH" "$CONFIG_PATH.install.$(date "+%Y-%m-%d_%H-%M-%S")"
	fi
	return 0
}


save_config() {
	cat >"$CONFIG_PATH" <<EOF
# Файл конфигурации Eva
# Развёртывание нового экземпляра Eva командой:
#   /opt/eva_admin/eva-docker.sh install ${ARG_NAME:+--name=$NAME}
# Для применения изменений в уже развёрнутой системе(с перезагрузкой):
#   /opt/eva_admin/eva-docker.sh apply ${ARG_NAME:+--name=$NAME}

# NAME должен соответствовать имени файла
NAME='$NAME'

# Параметры версии
BRANCH='$BRANCH'
# Можно указать для установки определённой версии v02...
VERSION='$VERSION'
# Можно указать для установки из определённого образа
DOCKER_IMAGE=

# Режим деплоя (TRUE - для работы без доступа в интернет)
OFFLINE='$OFFLINE'


# Параметры первоначальной настройки, после установки изменить нельзя.
# SELECTED_PRODUCT=|evaproject|evawiki
SELECTED_PRODUCT='$SELECTED_PRODUCT'
CONF_ADMIN_EMAIL='$CONF_ADMIN_EMAIL'

# Параметры функциональные параметры контейнера
CONF_DOMAIN='$CONF_DOMAIN'
# 1 - use certbot, 0 - do not
CONF_CERTBOT='$CONF_CERTBOT'
# timedatectl list-timezones
CONF_TZ='$CONF_TZ'


# Параметры контейнера
CONTAINER_ENGINE='$CONTAINER_ENGINE'

# ROOTLESS=TRUE - если требуется rootless режим
ROOTLESS=

# CONTAINER_AS_SERVICE=TRUE - создать systemd-сервис для запуска podman контейнера.
CONTAINER_AS_SERVICE=$CONTAINER_AS_SERVICE

CONTAINER_NAME='$CONTAINER_NAME'
CONTAINER_VOLUME='$CONTAINER_VOLUME'

# Маппинг портов [host_ip:]port
# Номера портов не должны конфликтовать с другими сервисами или контейнерами на этоим хосте.
# Для использования номеров портов <= 1024, требуются root приыелегии.
# HTTPS порт необходим для работы с сервисом напрямую
HTTPS_PORT='$HTTPS_PORT'
# HTTP порт может использоваться, если https терминируется на прокси-сервере, а прокси с сервисом работает по http
HTTP_PORT='$HTTP_PORT'

# Дополнительные пользовательские опции для docker run
# Например для работы в non-root режиме(после инициализации тома автоматически uid сменить нельзя):
#   CONTAINER_CUSTOM_PARAMS="-u 3000"
CONTAINER_CUSTOM_PARAMS=

# Параметр для скейлинга контейнера, в Гб ОЗУ
#   Количество workers примерно CONF_MEMORY_LIMIT_GB // 2
# минимум 8Гб
CONF_MEMORY_LIMIT_GB='$CONF_MEMORY_LIMIT_GB'

# Для проброса параметров в конфиг контейнера(/opt/CONFIG):
#   EVA_CONFIG__REDIS_SERVER_ENABLED=FALSE
# Параметры запишуться в /opt/CONFIG при запуске контейнера.
# Удалить параметр из /opt/CONFIG можно только вручную.
${EVA_CONFIG__EXTERNAL_PORT_HTTPS:+EVA_CONFIG__EXTERNAL_PORT_HTTPS='$EVA_CONFIG__EXTERNAL_PORT_HTTPS'}
EOF
	return 0
}


ask_apply_config() {
	echo
	echo "Конфигурация сохранена в $CONFIG_PATH:"
	echo "----------------------"
	echo
	cat "$CONFIG_PATH"
	echo
	echo
	echo "----------------------"
	echo
	echo "Проверьте конфигурацию и подтвердите запуск установки,"
	echo "Конфигурацию можно изменить в файле $CONFIG_PATH, затем применить её командой:"
	echo "  /opt/eva_admin/eva-docker.sh install ${ARG_NAME:+--name=$NAME}"

	local reply
	while true; do
		echo -n "Применить конфигурацию сейчас (ДА/нет) ?:"
		read -r reply
		if [[ ! $reply || $reply = [yYдД]* ]]; then
			/opt/eva_admin/eva-docker.sh install ${ARG_NAME:+--name=$NAME}
			break
		elif [[ $reply = [nNнН]* ]]; then
			break
		else
			echo "Ответьте да или нет"
		fi
	done
	return 0
}


ask_podman_service() {
	CONTAINER_AS_SERVICE=
	if [[ $CONTAINER_ENGINE != podman ]]; then
		return 0
	fi
	echo "Для автоматического запуска контейнера podman нужно создать systemd-сервис."
	local reply
	while true; do
		echo -n "Запустить команды настройки сервиса systemd (ДА/нет) ?"
		read reply
		if [[ ! $reply || $reply = [yYдД]* ]]; then
			CONTAINER_AS_SERVICE=TRUE
			break
		elif [[ $reply = [nNнН]* ]]; then
			CONTAINER_AS_SERVICE=
			break
		else
			echo "Ответьте да или нет"
		fi
	done
	return 0
}


ask_create_link() {
	if [[ $(id -u) != 0 ]]; then
		return 0
	fi
	if [[ -f /opt/eva_admin/.no-eva-docker-link || -f /usr/sbin/eva-docker.sh ]]; then
		return 0
	fi
	echo
	local reply
	while true; do
		echo -n "Создать ссылку /usr/sbin/eva-docker.sh для утилиты управления контейнером (ДА/нет) ?"
		read reply
		if [[ ! $reply || $reply = [yYдД]* ]]; then
			ln -s /opt/eva_admin/eva-docker.sh /usr/sbin/eva-docker.sh
			break
		elif [[ $reply = [nNнН]* ]]; then
			touch /opt/eva_admin/.no-eva-docker-link
			break
		else
			echo "Ответьте да или нет"
		fi
	done
	return 0
}


main() {
	# Проверки, скачивание и установку зависимостей делаем до вопросов мастера.
	# TODO: предупреждать с подтверждением, что будет установлен докер и скачан дистрибутив.
	check_is_root
	check_requirements
	check_container_engine
	check_already_exists

	greetings
	ask_configuration_product
	ask_configuration_domain
	ask_configuration_ssl
	ask_configuration_tz
	ask_configuration_mem
	ask_ports
	ask_podman_service
	ask_create_link

	save_config

	ask_apply_config
	return 0
}


main "$@"


exit 0
