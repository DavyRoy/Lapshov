#!/bin/bash

# echo "$0 $@ [$$] START" >&2
# set -euE

### version 2018-03-06
# --help Info: библиотека вспомогательных функций для работы в стиле opencarbon7
# --help Usage:
# --help . /opt/crab/crab_utils/bin/crab_sys.sh
# --help source /opt/crab/crab_utils/bin/crab_sys.sh
# --help Example:
# --help #!/bin/bash
# --help set -ue
# --help . /opt/crab/crab_utils/bin/crab_sys.sh
# --help sys::usage "$@"
# --help ### --help Info: Usage: Example:
# --help sys::arg_parse "$@"
# --help Example: bash_completion
# --help cat /etc/bash_completion.d/cloudfox
# --help have cloudfox &&
# --help _cloudfox()
# --help {
# --help     local cur prev
# --help     _get_comp_words_by_ref cur prev
# --help
# --help     shift_cloudfox(){
# --help 	    cmd="${1}"
# --help 	    shift
# --help 	    "$cmd" --completion "$@"
# --help     }
# --help     COMPREPLY=( $( compgen -W "`shift_cloudfox "${COMP_WORDS[@]}"`" -- "$cur" ) )
# --help } &&
# --help complete -F _cloudfox cloudfox cloudfox_vm cloudfox_admin cloudfox_node
# --help __SILENT=TRUE __SETX='-x'
[[ "$-" == *x* ]] && __SETX="-x"
set +x
if [ "${__DEBUG:-}" = TRUE ] || [[ "$@" == *"--debug"* && "${__DEBUG:-}" != FALSE ]]; then
	export __SETX="-x"
	export __DEBUG=TRUE
	export __SILENT=FALSE
fi

if [[ "$@" == *"--quiet"* ]]; then
	export __SILENT=TRUE
fi

if [ "${1:-}" = "--quiet" ]; then
	shift
	export __SILENT=TRUE
	ARG_QUIET=TRUE
fi

if [[ "$@" == *"--force"* ]]; then
	export __FORCE=TRUE
fi

if [ "${1:-}" = "--force" ]; then
	shift
	export __FORCE=TRUE
	ARG_FORCE=TRUE
fi

if [ "${1:-}" = "--completion" ]; then
	shift
	cmd=$( readlink -f ${BASH_SOURCE[1]} )
	[ -x "${cmd}_completion" ] && exec "${cmd}_completion" "$@" || exit 0
fi
if [ "${0##*/}" = "crab_sys.sh" -a "${1:-}" = "--help" ]; then
	grep "# [-]-help" "$0"
	exit 0
fi
set -euE
declare __ARGV=
declare __TMPLINENO=
# revers argv
for __ARG in "${BASH_ARGV[@]:1}"; do
	[[ "$__ARG" == *' '* ]] && __ARG="'$__ARG'"
	__ARGV=( "$__ARG" "${__ARGV[@]}" )
done

ECHO_INDENT=""
__CMDSTACK="${__CMDSTACK:-}"
if [ -n "${__START_PID:-}" ]; then
	__pid=$$
	while [ "$__pid" != 1 -a -f /proc/$__pid/stat ]; do
		read -r t t t __pid t < /proc/$__pid/stat
		ECHO_INDENT="$ECHO_INDENT "
		[ "$__pid" = "$__START_PID" ] && break
	done
else
	export __START_PID="$$"
	__pid=$$
	__CMDSTACK=''
	while [ "$__pid" != 1 -a -f /proc/$__pid/stat ]; do
		read -r t t t __pid t < /proc/$__pid/stat
		[ "$__pid" -le 1 -o ! -f "/proc/$__pid/comm" ] && break
		[ "${__cmd:-}" = "$(</proc/$__pid/comm)" ] && continue
		__cmd="$(</proc/$__pid/comm)"
		export __CMDSTACK="${__cmd}:${__CMDSTACK}"
	done
fi
__BASH_SOURCE=${BASH_SOURCE[1]}

[ "${__SILENT:-}" != TRUE ] && echo " #${ECHO_INDENT}START ${__BASH_SOURCE} ${__ARGV[@]} [$$]" >&2
if [ -n "${LOG_FILE:-}" ]; then
	__LOG_FROM="${SSH_CLIENT:-}"
	[ -n "$__LOG_FROM" ] && __LOG_FROM="${__LOG_FROM%% *}"
	echo "$(date +'%Y-%m-%d %H:%M:%S') ${__LOG_FROM}:${__CMDSTACK}${__START_PID} "\
		"${ECHO_INDENT}START ${__BASH_SOURCE} ${__ARGV[@]} [$$]" >>"${LOG_FILE}"
fi

# skip strongbash021_5
trap '__exit $? CMD=${BASH_COMMAND// /%%%%%} "$@"' ERR
__exit(){
	set +eux
	local status=$1
	local cmd=
	local argv=
	shift
	if [[ "${1}" == "CMD="* ]]; then
		cmd=${1//CMD=/}
		cmd=${cmd//%%%%%/ }
		shift
		argv="$@"
	else
		echo ""
		echo "__exit $status $@"
		cmd="__exit"
		argv=
	fi
	if [ $status = 255 ]; then
		echo "    # ^^^ ERROR_STATUS=$status ${cmd}"
		exit $status
	fi
#	echo "^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^"
	echo " #    ERROR_PROG=$__BASH_SOURCE  ${__ARGV[@]}"
	echo " #    ERROR_STACK=${BASH_SOURCE[@]:1}"
	echo " #    ERROR_SOURCE=${BASH_SOURCE[@]:1:1} $argv"
	echo " #    ERROR_CMD=\"${cmd}\""
	echo " #    LINENO=${BASH_LINENO[@]:0:${#BASH_LINENO[@]}-1} ERROR_STATUS=$status\
 FUNC: ${FUNCNAME[@]:1}"
	__TMPLINENO="${BASH_LINENO[@]:0:${#BASH_LINENO[@]}-1}"
	# echo ""
	# echo grep -n "${cmd}" ${BASH_SOURCE[@]:1:1} -B 5 -A 5 grep "^${BASH_LINENO[@]:0:1}:" -B 5 -A 5
	# grep -n "${cmd}" ${BASH_SOURCE[@]:1:1} -B 5 -A 5 | grep "^${BASH_LINENO[@]:0:1}:" -B 5 -A 5
	grep -n . "${BASH_SOURCE[@]:1:1}" -B 5 -A 5 \
		| sed 's/^\(.*\)/ #    \1/' \
		| grep "^ #    ${__TMPLINENO}:.*" -B 5 -A 5 --color
	exit ${status:-0}
}

trap '__trapexit $?' EXIT
__trapexit(){
	local cmd="${BASH_COMMAND}"
	set +eux
	local ret=$1
	# fix bash bug trap ERR тк при кривых инклудах падает, но ERR не ловит и выходит exit 0
	# разрешаем выходить только через exit
	[[ "$cmd" != *"exit"* && $ret == 0 ]] && ret=1
	if [ $ret = 0 ]; then
		[ "${__SILENT:-}" != TRUE ] \
			&& echo " #${ECHO_INDENT}SUCCESS ${__BASH_SOURCE} ${__ARGV[@]} [$$]" >&2
		if [ -n "${LOG_FILE:-}" ]; then
			echo "$(date +'%Y-%m-%d %H:%M:%S') ${__LOG_FROM}:${__CMDSTACK}${__START_PID} "\
				"${ECHO_INDENT}SUCCESS ${__BASH_SOURCE} ${__ARGV[@]} [$$]" >>"${LOG_FILE}"
		fi
	else
		# if [ "${__SILENT:-}" != TRUE ]; then
		echo " ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^" >&2
		echo
		echo " #${ECHO_INDENT}FAILED ${__BASH_SOURCE} ${__ARGV[@]} [$$]" >&2
		# fi
		if [ -n "${LOG_FILE:-}" ]; then
			echo "$(date +'%Y-%m-%d %H:%M:%S') ${__LOG_FROM}:${__CMDSTACK}${__START_PID} "\
				"${ECHO_INDENT}FAILED=$ret ${__BASH_SOURCE} ${__ARGV[@]} [$$]" >>"${LOG_FILE}"
		fi
	fi
	exit $ret
}

sys::usage(){
	[[ "${@:---help}" != *"--help"* ]] && return 0
	(
		set +e
		echo "### ${__BASH_SOURCE##*/}:"
		grep '# [-][-]help' ${__BASH_SOURCE} | sed 's/### --help //'
		exit 0
	)
	[[ "$@" == *"--help"* ]] && exit 0 || exit 255
}

### --help Example: sys::arg_parse "$@"
### --help Example: sys::arg_parse "vm create name1 --ram=4gb --disksize=10gb --force -t 1 -y
### --help Example: return ARG_0=vm ARG_1=create ARG_2=name1
### --help Example: or return ARGV[0]=vm ARGV[1]=create ARGV[2]=name1 ARGC=3
### --help Example: for var in ${!ARG_@}; do echo $var ${!var}; done
### --help Example: ARG_RAM=4gb ARG_DISKSIZE=10gb ARG_FORCE=TRUE ARG_T=1 ARG_Y=TRUE
__ARG_PARSE_REVERT_DEBUG=
sys::arg_parse() {
	[[ "$-" == *x* ]] && { set +x; __ARG_PARSE_REVERT_DEBUG=TRUE; }
	ARGC=0
	ARGV[$ARGC]="$0"
	ARG_0="$0"

	local i=
	local _i=
	local _arg_name= _arg_value=
	local params=( "$@" )
	local n=
	for ((n=0; n<${#params[@]}; n++)); do
		i="${params[$n]}"
		case $i in
		--*)
			_i=${i#--}
			if [[ "$_i" == *"="* ]]; then
				_arg_name="${_i%%=*}"
				_arg_name=${_arg_name//-/_}
				_arg_value="${_i#*=}"
				eval export -n '"ARG_${_arg_name^^}"="${_arg_value}"'

			else
				_arg_name="${_i}"
				_arg_name=${_arg_name//-/_}
				eval export -n '"ARG_${_arg_name^^}"=TRUE'
			fi
			;;
		-[^-]*)
			_arg_name="${i:1:1}"
			_arg_value="${i:2}"
			if [[ -n "${_arg_value}" ]]; then
				eval export -n '"ARG_${_arg_name^^}"="${_arg_value}"'
			else
				eval export -n '"ARG_${_arg_name^^}"=TRUE'
			fi
			;;
		*)
			ARGC=$((ARGC+1))
			ARGV[$ARGC]="$i"
			eval export -n '"ARG_$ARGC"="$i"'
			;;
		esac
	done
	[ "${__ARG_PARSE_REVERT_DEBUG:-}" = TRUE ] && { __ARG_PARSE_REVERT_DEBUG="" ; set -x; set -x; }
	return 0
}
[ -n "${__SETX:-}" ] && { __SETX=""; set -x; }
____EXIT=0
# echo "$0 $@ [$$] SUCCESS"
# exit 0
