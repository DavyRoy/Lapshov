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


logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

load_profile_filename = sys.argv[1]
with open(load_profile_filename) as config_file:
    config = yaml.load(config_file, yaml.Loader)

ammo_config = config['ammo']

with open(ammo_config['db_data']) as db_data_file:
    db_data = yaml.load(db_data_file, yaml.Loader)

hl_data = db_data['hl_data']

ammo_file_path = pathlib.Path(f'{config["name"]}-ammo.tsv')
with ammo_file_path.open('w') as ammo_file:
    weights = [case['weight'] for case in ammo_config['cases']]
    for case in random.choices(ammo_config['cases'], weights, k=ammo_config['quantity']):
        project = random.choice(hl_data['projects'])
        user = random.choice(project['users'])
        project_task = random.choice(project['tasks'])
        sprint = random.choice(project['sprints'])
        sprint_task = random.choice(sprint['tasks'])
        case_params = {
            'project_id': project['id'],
            'user_id': user['id'],
            'token': user['token'],
            'sprint_id': sprint['id'],
            'sprint_code': sprint['code'],
            'project_task_id': project_task['id'],
            'sprint_task_id': sprint_task['id'],
        }
        if case.get('params'):
            case_params.update(case.get('params'))
        print(f'{case["name"]}\t{json.dumps(case_params)}', file=ammo_file)
