import json
import logging
import os
import pathlib
import random
import requests
import sys
import threading
import typing
import uuid
import urllib3
import yaml


class ApiError(Exception):
    pass


class Api:
    def __init__(self, config):
        # you'll be able to call gun's methods using this field:
        self.config = config
        self.url = config['url']
        self.admin_token = config['admin_token']
        self.client_session = None

    def __enter__(self):
        self.client_session = requests.Session()
        self.client_session.verify = False
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """this will be executed in each worker after the end of the test"""
        self.client_session.close()

    def call(self, method, args=None, kwargs=None, flags=None, token=None):
        if flags is None:
            flags = {"admin_mode": True}
        data = {
            "jsonrpc": "2.2",
            "callid": str(uuid.uuid1()),
            "jsver": None,
            "method": method,
            "args": args or [],
            "kwargs": kwargs or {},
            "no_meta": True,
            "flags": flags or {},
            # "flags": {"admin_mode": true},
        }
        if not token:
            token = self.admin_token

        response = self.client_session.post(
            f'{self.url}/api/?m={method}',
            json=data, headers={"Authorization": f"Bearer {token or self.admin_token}"})

        response.raise_for_status()

        json_result = response.json()
        # if json_result.get('error'):
        #     log.debug('call %s: error: %s', method, json_result['error'])
        #     raise Handled
        # if json_result['abort']:
        #     log.debug('call %s: abort: %s', method, json_result['abort'])
        #     raise Handled
        try:
            return json_result['result']
        except KeyError:
            log.error('API result %s', json_result)
            raise


def ensure_token(user_id):
    token = tokens.get(user_id)
    if not token:
        log.info('Generate Token %s', user_id)
        token = api.call('CmfPerson.generate_api_token', args=[user_id], kwargs={'alert': False})
        tokens[user_id] = token
    return token


def ensure_user(user_login):
    api_result = api.call('CmfPerson.get', kwargs={'login': user_login})
    if not api_result:
        log.info('  Create Person %s', user_login)
        api_result = api.call(
            'CmfPerson.create',
            kwargs={
                'name': user_login,
                'login': user_login,
                'user_local': True,
            })
        api_result = api.call('CmfPerson.get', kwargs={'login': user_login})
    return api_result


def ensure_sprint(name=None, project=None, sprint_number=None, project_number=None, projects_config=None):
    prefix = projects_config["prefix"]
    sprint = api.call('CmfList.get', kwargs={'name': name, 'parent_id': project['id']})
    if not sprint:
        log.info('  Create sprint %s', name)
        _sprint_id = api.call(
            'CmfList.create',
            #   parent_id: CmfProject:8e534b42-9a65-11ee-a6b3-00161e146564
            kwargs={
                'name': name,
                'ui_view_form': 'kanban',
                'logic_type': 'list.agile_sprint:default',
                'parent_id': project['id'],
                #   "activity": {
                #     "id": "CmfActivity:d1d6bb8c-7437-11ee-bd85-0242ac110002"
                #   },
            })
        # print(_sprint_id)
        # sprint = api.call('CmfList.get', kwargs={'id': _sprint_id})
        sprint = api.call('CmfList.get', kwargs={'name': name, 'parent_id': project['id']})
        # print(sprint)
        # print(name)
        # print(sprint['name'])
    assert sprint
    sprint_tasks = []
    for task_number in range(projects_config['tasks_per_sprint']):
        task_name = f'{prefix} hl test sprint task {project_number:04d}-{sprint_number:04d}-{task_number:04d}'
        task = ensure_task(name=task_name, project=project, sprint=sprint, task_number=task_number)
        sprint_tasks.append(task)

    return {
        'id': sprint['id'],
        'code': sprint['code'],
        'name': sprint['name'],
        'tasks': sprint_tasks,
    }


def ensure_task(name=None, project=None, sprint=None, task_number=None):
    task = api.call('CmfTask.get', kwargs={'name': name, 'parent_id': project['id']})
    if not task:
        log.info('  Create task %s', name)
        _task_id = api.call(
            'CmfTask.create',
            #   parent_id: CmfProject:8e534b42-9a65-11ee-a6b3-00161e146564
            kwargs={
                'name': name,
                'parent_id': project['id'],
                'lists': [sprint['id']] if sprint else [],
                'text': '<p>Task p1 text</p>',
            })
        task = api.call('CmfTask.get', kwargs={'name': name, 'parent_id': project['id']})
        # task = api.call('CmfTask.get', kwargs={'id': _task_id})
        # print(_task_id, task)
        # print(name)
        # print(task['name'])
        # sys.exit()
    assert task
    return {
        'id': task['id'],
        'code': task['code'],
        'name': task['name'],
    }


def ensure_project(projects_config, project_number):
    prefix = projects_config["prefix"]
    project_code = f'{prefix}{project_number:04d}'
    api_result = api.call('CmfProject.get', kwargs={'code': project_code})
    if not api_result:
        log.info('Create project %s', project_code)
        _project = api.call(
            'CmfProject.create',
            kwargs={
                'code': project_code,
                'name': f'HL Test Project {prefix} - {project_number}',
                'perm_private': False,
                'ui_view_form': 'project',
                'logic_type': 'project.agile:default',
                'task_code_prefix': f'{prefix}{project_number:04d}',
                #   "scheme_wf": "CmfSchemeWf:d561a83e-7437-11ee-bd85-0242ac110002",
                #   "activity": {
                #     "id": "CmfActivity:d1d6bb8c-7437-11ee-bd85-0242ac110002"
                #   },
            })
        api_result = api.call('CmfProject.get', kwargs={'code': project_code})
    project = api_result

    project_users = []
    for user_number in range(projects_config['users_per_project']):
        user_login = f'hl-test-{project_number:04d}-{user_number:04d}@{prefix}.local'
        user = ensure_user(user_login)
        token = ensure_token(user['id'])
        user['token'] = token
        project_users.append(user)
        users[user['id']] = user

    project_tasks = []
    for task_number in range(projects_config['tasks_per_project']):
        task_name = f'{prefix} hl test project task {project_number:04d}-{task_number:04d}'
        task = ensure_task(name=task_name, project=project, task_number=task_number)
        project_tasks.append(task)

    project_sprints = []
    for sprint_number in range(projects_config['sprints_per_project']):
        # !!! Mandatory prefix Sprint
        sprint_name = f'Sprint {prefix} hl test sprint {project_number:04d}-{sprint_number:04d}'
        sprint = ensure_sprint(
            name=sprint_name, project=project, sprint_number=sprint_number, project_number=project_number,
            projects_config=projects_config)
        project_sprints.append(sprint)

    project = {
        'id': project['id'],
        'code': project['code'],
        'users': project_users,
        'tasks': project_tasks,
        'sprints': project_sprints,
    }
    projects.append(project)
    return project


logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

target_filename = sys.argv[1]
with open(target_filename) as config_file:
    config = yaml.load(config_file, yaml.Loader)

result = {
    'api': config['api'].copy(),
    'hl_data': {
        'projects': [],
        'users': {},
    }
}

projects = result['hl_data']['projects']
users = result['hl_data']['users']
projects_config = config['test-data-profile']['projects']
project_start_number = projects_config['start_number']
projects_quantity = projects_config['quantity']

# local tokens cache
tokens_path = pathlib.Path(f'{config["name"]}-tokens.yaml')
if tokens_path.exists():
    with tokens_path.open() as token_file:
        tokens = yaml.load(token_file, yaml.Loader)
else:
    tokens = {}

with Api(config=config['api']) as api:
    for project_number in range(project_start_number, project_start_number+projects_quantity):
        ensure_project(projects_config, project_number)

with open(f'{config["name"]}-load-data.yaml', 'wt') as hl_data_file:
    yaml.dump(result, hl_data_file, yaml.Dumper)

# write and move?
with tokens_path.open('wt') as token_file:
    yaml.dump(tokens, token_file, yaml.Dumper)
