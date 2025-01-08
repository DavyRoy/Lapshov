from datetime import datetime
import json
import typing
import logging
import threading
import gevent
import os
import random
import requests
import sys
import uuid
import random
import yaml


log = logging.getLogger(__name__)


class Handled(Exception):
    pass


class EvaBfgBase:
    def __init__(self, gun):
        # you'll be able to call gun's methods using this field:
        self.gun = gun
        self.sessions = None

        self.params = None
        self.target_name = None
        self.target_config = None
        self.url = None
        self.admin_token = None
        self.person_ids = None

        # for example, you can get something from the 'ultimate' section of a config file:
        # my_var = self.gun.get_option("my_var", "hello")
        log.info("Init LoadTest: %s", os.getpid())

    def _get_session(self, token=None):
        token = None  # экономим сокеты, если много воркеров.
        if token not in self.sessions:
            session = requests.Session()
            session.verify = False
            self.sessions[token] = session
        session = self.sessions[token]
        session.cookies.clear()  # clear auth
        return session

    def setup(self, param):
        """this will be executed in each worker before the test starts"""
        log.info("Setting up LoadTest: %s %s", os.getpid(), param)
        self.params = json.loads(param)
        self.target_name = self.params['target']

        with open(f'{self.target_name}-target.yaml') as target_config_file:
            self.target_config = yaml.load(target_config_file, yaml.Loader)

        self.url = self.target_config['api']["url"]
        self.admin_token = self.target_config['api'].get("admin_token")
        self.sessions = {}

    def teardown(self):
        """this will be executed in each worker after the end of the test"""
        for session in self.sessions.values():
            session.close()
        log.info("Tearing down LoadTest: %s(%s)", os.getpid(), gevent.getcurrent())
        return 0

    def _api_call(self, method, args=None, kwargs=None, flags=None, token=None, measure=True, marker=None):
        data = {
            "jsonrpc": "2.2",
            "callid": str(uuid.uuid1()),
            "jsver": None,
            "method": method,
            "args": args or [],
            "kwargs": kwargs or {},
            "no_meta": True,
            "flags": flags or {},
            # "fields": [],
            # "no_cache": false,
            # jsurl: == referer
            # "flags": {"admin_mode": true},
            # "session_tab_id": "RyaC",
            # "cache_id": "bbe4e3",
            # "jshash": "jshash:CmfPerson.get:irina@carbonsoft.ru:b1979c9c01e55de057de:bbe4e3"
        }
        if not token:
            token = self.admin_token
        result = None
        ctx = None
        ctx_mng = None
        # send_ts:	A timestamp when context was entered.
        # tag:	A marker passed to the context.
        # interval_real:
        #   The time interval from enter to exit. If the user defines his own value, it will be preserved. Microseconds.
        # connect_time:	Microseconds. Default: 0
        # send_time:	Microseconds. Default: 0
        # latency:	Microseconds. Default: 0
        # receive_time:	Microseconds. Default: 0
        # interval_event:	Microseconds. Default: 0
        # size_out:	Bytes out. Integer. Default: 0
        # size_in:	Bytes in. Integer. Default: 0
        # net_code:	Network code. Integer. Default: 0
        # proto_code:	Protocol code (http, for example). Integer. Default: 200
        if measure:
            # log.info(f'enter-{marker}')
            ctx_mng = self.gun.measure(marker or method)
            ctx = ctx_mng.__enter__()
        if not token:
            token = self.admin_token
        try:
            response = self._get_session(token).post(
                f'{self.url}/api/?m={method}',
                json=data, headers={"Authorization": f"Bearer {token}"})
            # TODO: +headers size
            if measure:
                ctx['size_in'] = len(response.request.body)
                ctx['size_out'] = len(response.content)
                # TODO
                # microseconds:
                # connect_time, send_time, latency, receive_time, interval_event(?)
                ctx["proto_code"] = response.status_code
            if not response.ok:
                raise Handled
            try:
                json_result = response.json()
            except ValueError:
                # requests.JSONDecodeError absent in old versions
                if measure:
                    ctx["proto_code"] = 10400
                raise Handled
            if json_result.get('error'):
                log.warning('call %s: error: %s', method, json_result['error'])
                if measure:
                    ctx["proto_code"] = 10500
                raise Handled
            if json_result['abort']:
                log.warning('call %s: abort: %s', method, json_result['abort'])
                if measure:
                    ctx["proto_code"] = 10501
                raise Handled
            result = json_result['result']
        except Handled:
            pass
        except requests.ConnectTimeout as e:
            # log.warning('call %s: Timeout %s', method, e)
            if measure:
                ctx['net_code'] = 2
                ctx["proto_code"] = 20002
        except requests.ConnectionError as e:
            log.warning('call %s: ConnectError %s', method, e)
            if measure:
                ctx['net_code'] = 3
                ctx["proto_code"] = 20003
        except requests.ReadTimeout as e:
            # log.warning('call %s: ReadTimeout %s', method, e)
            if measure:
                ctx['net_code'] = 4
                ctx["proto_code"] = 20000 + ctx["proto_code"]
        # except requests.JSONDecodeError:
        #    ctx["proto_code"] = 10400
        except requests.RequestException as e:
            # log.warning('call %s: requestError %s', method, e)
            if measure:
                ctx['net_code'] = 5
                ctx["proto_code"] = 30000 + ctx["proto_code"]
        except Exception as e:
            # log.warning('call %s: Other Error %s', method, e)
            ctx['net_code'] = 6
            ctx["proto_code"] = 60000 + ctx["proto_code"]
        if measure:
            # log.info(f'exit-{marker}-{ctx}-{sys.exc_info()}')
            ctx_mng.__exit__(None, None, None)
        return result
