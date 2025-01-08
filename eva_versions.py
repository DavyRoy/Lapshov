#!/usr/bin/env python3
import sys
import json
import urllib.request
import argparse


REGISTRY_URL = 'docker-registry.evateam.ru'

SCOPE=""
BRANCH=""
def parse_branch(branch, version):
    '''
    Определяем scope, branch
    Branch могут задать явно, а могут передать его в версии
    '''
    global SCOPE, BRANCH
    BRANCH = branch
    if version and '-' in version:
        # Передали версию, причем полную
        BRANCH = version.split('-')[2]
    if not BRANCH:
        print('Укажите branch или полную версию (в формате SCOPE-v00.00.00.0000-BRANCH)', file=sys.stderr)
        exit(1)
    SCOPE = _get_scope(BRANCH)


# ./update_docker.sh --list # показать офф.версии integra_kolko8 выше текущей. Если идет смена бранча - показывать только последнюю. Только текущий бранч
# ./update_docker.sh --list --all # показать все версии, кроме patch. Только текущий бранч
# ./update_docker.sh --list --branch=integra_kolko8 # показать офф.версии integra_kolko8. Если идет смена бранча - показывать только последнюю
# ./update_docker.sh --list --branch=all


def _parse_version(full_version):
    if '-' in full_version:
        return full_version.split('-')[1]
    else:
        return full_version

def _ver2int(ver):
    ver = _parse_version(ver)
    return int(''.join([c for c in ver if c.isdigit()]).lstrip('0'))

def _get_scope(branch):
    if branch in ['master', 'release', 'devel', 'integra']:
        return 'public'
    return branch

def _print_tag_as_version(tag, pretty=False, output_format=None):
    tag_patrs = tag.split('-')
    if not output_format:
        output_format = 'system'
    if pretty:
        output_format = 'pretty'
    if output_format == 'system':
        print(tag_patrs[1])
    elif output_format == 'pretty':
        print("{}  -  SCOPE={} BRANCH={} FLAGS={}".format(
            tag_patrs[1], tag_patrs[0], tag_patrs[2], ' '.join(tag_patrs[3:]))
        )
    elif output_format == 'registry':
        print('{}/evateam:{}'.format(REGISTRY_URL, tag))
    else:
        raise Exception("_print_tag_as_version: unknown output_format={}".format(output_format))


def _fetch_tags():
    res = urllib.request.urlopen('https://' + REGISTRY_URL + '/v2/evateam/tags/list')
    res_body = res.read()
    res_json = json.loads(res_body.decode("utf-8"))
    return res_json['tags']


def update_to_version_list(args):
    '''
    Возвращаем список версий, на которые нужно постепенно обновиться.
    Выводим все промежуточные версии -patch и -official, включая версию на которую нужно обновиться.
    Проверяем, что мы нашли current_version, чтобы избежать ошибок запуска
    '''
    global SCOPE, BRANCH
    parse_branch(args.branch, args.current_version)

    current_version = _parse_version(args.current_version)
    to_version = _parse_version(args.to_version)

    change_branch = False
    change_scope = False
    if args.change_branch and args.change_branch != BRANCH:
        BRANCH = args.change_branch
        change_branch = True
        if SCOPE != _get_scope(BRANCH):
            SCOPE = _get_scope(BRANCH)
            change_scope = True

    if current_version == to_version:
        print('Ошибка! current_version == to_version', file=sys.stderr)
        exit(1)
    if current_version > to_version and not change_scope:
        print('Ошибка! current_version > to_version', file=sys.stderr)
        exit(1)

    cur_version_found = False
    to_version_found = False

    versions = []
    for tag in sorted(_fetch_tags()):
        if not tag.startswith("{}-".format(SCOPE)):
            continue
        if not '-{}'.format(BRANCH) in tag:
            continue

        if _parse_version(tag) == _parse_version(current_version):
            cur_version_found = True
        if _parse_version(tag) == _parse_version(to_version):
            to_version_found = True

        if _parse_version(tag) <= _parse_version(current_version) and not change_scope:
            continue
        if _parse_version(tag) > _parse_version(to_version):
            continue

        # Сохраняем только промежуточные patch и official и to_version
        if '-official' in tag or '-patch' in tag or _parse_version(tag) == _parse_version(to_version):
            versions.append(tag)

    if not cur_version_found and not change_branch:
        print('Исходная версия не найдена, невозможно рассчитать список промежуточных версий!', file=sys.stderr)
        exit(1)
    if not to_version_found:
        print('Версия для обновления не найдена, невозможно рассчитать список промежуточных версий!', file=sys.stderr)
        exit(1)
    if not versions:
        print('Не найдено версий для обновления!', file=sys.stderr)
        exit(1)

    if change_scope:
        _print_tag_as_version(versions[-1], output_format=args.output_format)
    else:
        for v in versions:
            _print_tag_as_version(v, output_format=args.output_format)


def get_available_versions(args):
    '''
    Возвращаем список версий, доступных для обновления
    Обязательно указывать текущую версию (защита от неверных обновлений без промежуточных версий)
    Если указан флаг --all - показываем неофициальные версии (test-версии) тоже
    Если передали --change-branch, тогда выводим только последнюю официальную версию
        т.к. обновление только с последней на последнюю версию
    Если передали --change-branch=ALL, тогда выводим версии всех scope и всех бранчей
    '''
    parse_branch(args.branch, args.current_version)
    global BRANCH, SCOPE

    only_official = True
    if args.all:
        only_official = False

    current_version = _parse_version(args.current_version)

    only_last_official = False
    if args.change_branch and args.change_branch.upper() == 'ALL':
        BRANCH = 'ALL'
        SCOPE = 'ALL'
    elif args.change_branch and args.change_branch != BRANCH:
        BRANCH = args.change_branch
        SCOPE = _get_scope(BRANCH)
        only_last_official = True

    last_official_version = None
    for tag in sorted(_fetch_tags()):
        if SCOPE != 'ALL' and not tag.startswith("{}-".format(SCOPE)):
            continue
        if only_official and not tag.endswith("-official"):
            continue
        if BRANCH != 'ALL' and '-{}'.format(BRANCH) not in tag:
            continue
        # Патч-версии не выводим
        if tag.endswith("-patch"):
            continue

        if not only_last_official:
            if _ver2int(current_version) < _ver2int(tag):
                _print_tag_as_version(tag, pretty=True)
            continue

        if not last_official_version:
            last_official_version = tag
        elif _ver2int(last_official_version) <= _ver2int(tag):
            last_official_version = tag
    if only_last_official:
        if last_official_version:
            _print_tag_as_version(last_official_version, pretty=True)


def get_version_for_install(args):
    '''
    Всегда возвращаем последнюю официальную версию
    '''
    parse_branch(args.branch, None)

    last_official_version = None
    for tag in _fetch_tags():
        if not tag.startswith("{}-".format(SCOPE)):
            continue
        if not tag.endswith("-{}-official".format(BRANCH)):
            continue
        if not last_official_version:
            last_official_version = tag
        elif _ver2int(last_official_version) <= _ver2int(tag):
            last_official_version = tag
    if not last_official_version:
        print('Версия не найдена! SCOPE={} BRANCH={}'.format(SCOPE, BRANCH), file=sys.stderr)
        exit(1)
    _print_tag_as_version(last_official_version, output_format=args.output_format)


def get_docker_image_name(args):
    parse_branch(args.branch, args.version)
    found_tag = None
    for tag in _fetch_tags():
        if not '{}-{}-'.format(SCOPE, _parse_version(args.version)) in tag:
            continue
        # Предпочитаем версию official и не patch
        if not found_tag or '-official' in tag or '-patch' in found_tag:
            found_tag = tag
    if not found_tag:
        print(SCOPE, BRANCH)
        print('Версия не найдена!', file=sys.stderr)
        exit(1)
    print('{}/evateam:{}'.format(REGISTRY_URL, found_tag))


def main():
    parser = argparse.ArgumentParser()
    parser.description = "Утилита получения списка версий EvaTeam"

    subparser = parser.add_subparsers()

    update_to_verios_parser = subparser.add_parser(
        'update-to-version-list',
        help='Получить список промежуточных версий для запуска обновления',
    )
    update_to_verios_parser.add_argument('-b', '--branch', type=str, required=False, help='Текущий branch версии')
    update_to_verios_parser.add_argument('--current-version', type=str, required=True, help='Текущая версия EvaTeam')
    update_to_verios_parser.add_argument('--to-version', type=str, required=True, help='Версия для обновления')
    update_to_verios_parser.add_argument('--change-branch', type=str, required=False, help='Новый branch версии')
    update_to_verios_parser.add_argument('--output-format', type=str, required=False, default='system',
                                         choices=['system', 'pretty', 'registry'], help='Формат вывода версий')
    update_to_verios_parser.set_defaults(func=update_to_version_list)

    get_available_versions_parser = subparser.add_parser(
        'get-available-versions',
        help='Получить список версий, на которые можно обновиться',
    )
    get_available_versions_parser.add_argument('-b', '--branch', type=str, required=False, help='Текущий branch версии')
    get_available_versions_parser.add_argument('--current-version', type=str, required=True, help='Текущая версия EvaTeam')
    get_available_versions_parser.add_argument('--all', help='Показывать неофициальные версии', action="store_true")
    get_available_versions_parser.add_argument('--change-branch', type=str, required=False, help='Новый branch версии')
    get_available_versions_parser.set_defaults(func=get_available_versions)

    get_version_for_install_parser = subparser.add_parser(
        'get-version-for-install',
        help='Получить версию для установки',
    )
    get_version_for_install_parser.add_argument('-b', '--branch', type=str, default='release', required=False, help='Branch версии')
    get_version_for_install_parser.add_argument('--output-format', type=str, required=False, default='system',
                                         choices=['system', 'pretty', 'registry'], help='Формат вывода версий')
    get_version_for_install_parser.set_defaults(func=get_version_for_install)

    get_docker_image_name_parser = subparser.add_parser(
        'get-docker-image-name',
        help='Получить имя docker-образа',
    )
    get_docker_image_name_parser.add_argument('-b', '--branch', type=str, required=False, help='Branch версии')
    get_docker_image_name_parser.add_argument('-v', '--version', type=str, required=True, help='Версия')
    get_docker_image_name_parser.set_defaults(func=get_docker_image_name)

    args = parser.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()