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

sys.path.append(os.getcwd())  # fixme
from eva_bfg_base import EvaBfgBase


log = logging.getLogger(__name__)


class LoadTest(EvaBfgBase):
    def get_current_user(self, missile=None, params=None):
        if not params:
            params = json.loads(missile)
        token = params['token']
        return self._api_call(method='CmfPerson.get_current_user', token=token)

    def all_models_meta(self, missile=None, params=None):
        if not params:
            params = json.loads(missile)
        token = params['token']
        return self._api_call(method='BaseModel.all_models_meta', token=token)

    def get_settings(self, missile=None, params=None):
        if not params:
            params = json.loads(missile)
        token = params['token']
        return self._api_call(method='CmfGlobalSettings.get_settings', token=token)

    def person_var_get(self, missile=None, params=None):
        if not params:
            params = json.loads(missile)
        token = params['token']
        return self._api_call(
            method='CmfPersonVar.get',
            kwargs={
                "person_id": params['user_id'],
                'fields': [
                    "favorites",
                    "favorites.executors",
                    "favorites.list_type",
                    "favorites.project_type",
                    "favorites.is_default",
                    "recents_obj",
                    "recents_opt_list",
                    "online_status",
                    "favorites.ui_view_form",
                    "show_in_main_menu_projects",
                    "show_in_main_menu_projects.is_default",
                    "show_in_main_menu_projects.project_type"
                ],
            },
            token=token)

    def project_get(self, missile=None, params=None):
        if not params:
            params = json.loads(missile)
        token = params['token']
        return self._api_call(
            method='CmfProject.get',
            kwargs={
                "person_id": params['user_id'],
                'filter': ["id", "==", params['project_id']],
                'fields': [
                    "id",
                    "name",
                    "code",
                    "cmf_owner_id",
                    "cmf_owner_assistants",
                    "activity_id",
                    "logic_prefix",
                    "logic_type",
                    "workflow.name",
                    "cmf_owner",
                    "cmf_created_at",
                    "project_type",
                    "task_code_prefix",
                    "description",
                    "category",
                    "is_public",
                    "sharelink_hash",
                    "perm_policy_anonymous",
                    "perm_policy_guest",
                    "perm_policy_sharelink",
                    "perm_policy",
                    "activity_id",
                    "tree_text_overflow"
                ],
            },
            token=token)

    def tab_init(self, missile=None, params=None):
        if not params:
            params = json.loads(missile)
        token = params['token']
        self.get_current_user(params=params)
        self.all_models_meta(params=params)
        # Cache.full_cache_validation ???
        self.get_settings(params=params)
        self.project_get(params=params)
        # ИМХО шаблоны надо загружать лениво...
        # + в тестовых данных нет шаблонов
        self._api_call(
            method='CmfTask.list',
            kwargs={
                'fields': [
                    "id",
                    "code",
                    "name",
                    "menu_items",
                    "menu_items.group_name",
                    "menu_items.obj_id",
                    "menu_items.menu_type"],
                "is_template": True,
            },
            token=token)
        self._api_call(
            method='CmfDocument.list',
            kwargs={
                'fields': [
                    "id",
                    "code",
                    "name",
                    "menu_items",
                    "menu_items.group_name",
                    "menu_items.obj_id",
                    "menu_items.menu_type"],
                "is_template": True,
            },
            token=token)

        self._api_call(
            method='CmfMenuTree.get_tree',
            kwargs={
                "tree_parent_id": params['project_id'],
                "level": 2,
                "expand_nodes": []},
            token=token)
        self._api_call(
            method='CmfTask.count',
            # На самом деле условие сильно сложней, надеюсь суть верно ухватил
            # user_id - чтобы кеш раздельный был
            kwargs={
                'filter': [
                    ["logic_prefix", "LIKE", "task%"],
                    ['OR',
                        ["approve_for_id", "=", params['user_id']],
                        ["approve_for_id", "!=", params['user_id']],
                    ]]},
            token=token)
        self._api_call(
            method='CmfTask.count',
            # На самом деле условие сильно сложней, надеюсь суть верно ухватил
            # user_id - чтобы кеш раздельный был
            kwargs={
                'filter': [
                    ["logic_prefix", "LIKE", "task%"],
                    ["approvers_for", "IN", [params['user_id']]],
                ]},
            token=token)
        self._api_call(
            method='CmfTask.count',
            # На самом деле условие сильно сложней, надеюсь суть верно ухватил
            # user_id - чтобы кеш раздельный был
            kwargs={
                'filter': [
                    ["logic_prefix", "LIKE", "task%"],
                    ["spectators", "IN", [params['user_id']]],
                ]},
            token=token)
        self._api_call(
            method='CmfNotify.count',
            # На самом деле условие сильно сложней, надеюсь суть верно ухватил
            # user_id - чтобы кеш раздельный был
            kwargs={
                'filter': [
                    ["person_id", "=", params['user_id']],
                    ["status", "!=", "closed"]]},
            token=token)
        # [
        #   "logic_prefix",
        #   "LIKE",
        #   "task%"
        # ]

    def load_sprint(self, missile=None, params=None):
        if not params:
            params = json.loads(missile)
        token = params['token']
        self.tab_init(params=params)
        self._api_call(
            method='BaseModel.get_ui_full_path',
            kwargs={
                "ui_name": "List",
                "code": params['sprint_code'],
                "ui_module": "project",
            },
            token=token)
        self._api_call(
            method='CmfList.get',
            kwargs={
                'fields': ['id'],
                'filter': ['code', '=', params['sprint_code']]
            },
            token=token)
        self._api_call(
            method='CmfList.get',
            kwargs={
                'fields': [
                    "ui_view_form",
                    "parent_id",
                    "id",
                    "ui_model",
                    "main_gantt_project_id",
                    "parent",
                    "parent.main_gantt_project_id"
                ],
                'filter': ['code', '=', params['sprint_code']]
            },
            token=token)
        self._api_call(
            method='CmfList.get',
            kwargs={
                'fields': ["id", "code", "name", "parent.id", "parent.code", "parent.name", "parent.logic_type.name"],
                'filter': ['id', '=', params['sprint_id']]},
            token=token)
        self._api_call(
            method='CmfList.get',
            kwargs={
                'fields': ["project_type", "ui_view_form"],
                'filter': ['code', '=', params['sprint_code']]
            },
            token=token)
        self._api_call(
            method='CmfList.get',
            kwargs={
                'fields': [
                    "system", "text", "parent", "status", "status.status_code", "sharelink_hash", "cmf_owner",
                    "cmf_archived", "list_type", "tree_parent", "tree_parent_id", "auto_favorite",
                    "main_gantt_project_id", "default_task_workflow_id", "plan_start_date", "plan_end_date",
                    "card_task_fields", "logic_prefix", "cache_status_type"],
                'filter': ['id', '=', params['sprint_id']]},
            token=token)
        self._api_call(
            method='CmfTask.list',
            kwargs={
                "filter": ["fix_versions", "IN", [params['sprint_id']]],
                "fields": [
                    "--", "status", "status.status_type", "status.status_code", "status.status_code.code",
                    "deadline", "status_modified_at", "cmf_created_at", "cmf_modified_at", "child_tasks",
                    "child_tasks.cache_status_type", "priority", "orderno", "executors", "responsible",
                    "responsible.login", "responsible.name", "parent", "parent_logic_prefix", "lists",
                    "agile_story_points", "logic_type", "logic_type.ui_color", "parent_task", "parent_task.name",
                    "parent_task.priority", "parent_task.orderno", "parent_task.code", "parent_task.logic_prefix",
                    "parent_task.logic_type", "parent_task.parent_task_id", "parent_task.responsible_id",
                    "parent_task.parent_id", "op_gantt_task", "tags", "tags.name", "is_flagged", "responsible",
                    "lists", "executors", "responsible.name", "lists.name", "executors.name"],
                "include_archived": False},
            token=token)

    def get_task(self, missile=None, params=None):
        if not params:
            params = json.loads(missile)
        token = params['token']
        if params.get('in_sprint'):
            task_id = params['sprint_task_id']
        else:
            task_id = params['project_task_id']
        task = self._api_call(
            method='CmfTask.get',
            kwargs={
                "filter": ["id", "==", task_id],
                "fields": [
                    "activity", "alarm_date", "approved", "attachments.url", "attachments.url_preview",
                    "attachments.url_preview_img", "attachments.cmf_created_at", "main_list", "attachments",
                    "cmf_author", "cmf_created_at", "parent_task", "cmf_owner_id", "scheme_wf", "status_closed_at",
                    "cmf_modified_at", "cmf_modified_by", "cmf_owner.avatar_filename", "company.is_internal",
                    "company", "deadline", "executors", "is_template", "lists.logic_prefix", "lists.status_closed_at",
                    "fix_versions", "closed_lists", "mark", "no_control", "orderno", "parent.logic_prefix",
                    "parent_task", "parent_task.logic_type", "child_tasks", "child_tasks.lists", "has_child_tasks",
                    "outline_number", "is_milestone", "child_tasks.activity", "child_tasks.parent_task",
                    "child_tasks.status", "child_tasks.responsible", "child_tasks.is_checked",
                    "child_tasks.logic_prefix", "child_tasks.agile_story_points", "child_tasks.cmf_deleted",
                    "child_tasks.logic_type.ui_color", "child_tasks.priority", "cloned_from", "period_interval",
                    "period_next_date", "plan_end_date", "plan_start_date", "priority", "responsible", "spectators",
                    "status", "tags.tag_category.ui_separated_widget", "tags.color", "text", "result_text",
                    "time_spent", "time_estimate", "remaining_estimate", "waiting_for", "agile_story_points",
                    "logic_prefix", "status_closed_at", "status_review_at", "is_checked", "lists.parent.logic_prefix",
                    "lists.sys_type", "logic_type.ui_color", "timetracker_is_running",
                    "parent_task.cache_branch_gantt_path", "op_gantt_task.actual_complete", "parent.main_gantt_project",
                    "parent.logic_type", "git_commits", "git_commits.url", "git_branches", "git_branches.repo",
                    "git_branches.url", "git_merge_requests", "git_merge_requests.url", "git_merge_requests.status",
                    "git_merge_requests.repo", "git_merge_requests.repo.git_plugin",
                    "git_merge_requests.repo.git_plugin.type", "in_tasks", "out_tasks", "cmf_deleted", "local_links",
                    "status.need_approve", "parent_logic_prefix", "is_dummy", "components.text"],
                "create_form": False},
            token=token)
        return task

    def ui_get_task(self, missile=None, params=None):
        if not params:
            params = json.loads(missile)
        token = params['token']
        if params.get('in_sprint'):
            task_id = params['sprint_task_id']
        else:
            task_id = params['project_task_id']
        task = self._api_call(
            method='CmfTask.ui_get',
            kwargs={
                "filter": ["id", "==", task_id],
                "fields": [
                    "activity", "alarm_date", "approved", "attachments.url", "attachments.url_preview",
                    "attachments.url_preview_img", "attachments.cmf_created_at", "main_list", "attachments",
                    "cmf_author", "cmf_created_at", "parent_task", "cmf_owner_id", "scheme_wf", "status_closed_at",
                    "cmf_modified_at", "cmf_modified_by", "cmf_owner.avatar_filename", "company.is_internal",
                    "company", "deadline", "executors", "is_template", "lists.logic_prefix", "lists.status_closed_at",
                    "fix_versions", "closed_lists", "mark", "no_control", "orderno", "parent.logic_prefix",
                    "parent_task", "parent_task.logic_type", "child_tasks", "child_tasks.lists", "has_child_tasks",
                    "outline_number", "is_milestone", "child_tasks.activity", "child_tasks.parent_task",
                    "child_tasks.status", "child_tasks.responsible", "child_tasks.is_checked",
                    "child_tasks.logic_prefix", "child_tasks.agile_story_points", "child_tasks.cmf_deleted",
                    "child_tasks.logic_type.ui_color", "child_tasks.priority", "cloned_from", "period_interval",
                    "period_next_date", "plan_end_date", "plan_start_date", "priority", "responsible", "spectators",
                    "status", "tags.tag_category.ui_separated_widget", "tags.color", "text", "result_text",
                    "time_spent", "time_estimate", "remaining_estimate", "waiting_for", "agile_story_points",
                    "logic_prefix", "status_closed_at", "status_review_at", "is_checked", "lists.parent.logic_prefix",
                    "lists.sys_type", "logic_type.ui_color", "timetracker_is_running",
                    "parent_task.cache_branch_gantt_path", "op_gantt_task.actual_complete", "parent.main_gantt_project",
                    "parent.logic_type", "git_commits", "git_commits.url", "git_branches", "git_branches.repo",
                    "git_branches.url", "git_merge_requests", "git_merge_requests.url", "git_merge_requests.status",
                    "git_merge_requests.repo", "git_merge_requests.repo.git_plugin",
                    "git_merge_requests.repo.git_plugin.type", "in_tasks", "out_tasks", "cmf_deleted", "local_links",
                    "status.need_approve", "parent_logic_prefix", "is_dummy", "components.text"],
                "create_form": False},
            token=token)
        return task

    def open_task(self, missile=None, params=None):
        if not params:
            params = json.loads(missile)
        token = params['token']
        if params.get('in_sprint'):
            self.load_sprint(params=params)
            task_id = params['sprint_task_id']
        else:
            self.tab_init(params=params)
            task_id = params['project_task_id']
        _task = self.ui_get_task(params=params)
        self._api_call(method='CmfTask.get_ui_full_path', kwargs={'id': task_id}, token=token)
        self._api_call(
            method='CmfDocument.list',
            kwargs={
                "filter": ["mention_tasks", "IN", [task_id]],
                "fields": ["name", "cmf_modified_at", "cmf_modified_by", "mention_tasks"]},
            token=token)
        self._api_call(
            method='CmfTask.list',
            kwargs={
                "filter": ["parent_task", "=", task_id],
                "fields": [
                    "lists", "activity", "parent_task", "status", "responsible", "is_checked", "logic_prefix",
                    "agile_story_points", "cmf_deleted", "logic_type.ui_color", "priority", "cmf_created_at"],
                "order_by": ["-priority", "cmf_created_at"]},
            token=token)
        self._api_call(
            method='CmfTask.get',
            kwargs={
                'id': task_id,
                'fields': [
                    "activity", "lists", "parent_task", "status", "responsible", "is_checked", "logic_prefix",
                    "timetracker_is_running", "agile_story_points", "logic_type.ui_color", "priority",
                    "in_tasks.in_link.logic_type.ui_color", "in_tasks.in_link.priority", "parent", "parent_id",
                    "in_tasks", "in_tasks.in_link",
                    "in_tasks.in_link.logic_prefix",
                    "in_tasks.in_link.lists",
                    "in_tasks.in_link.activity",
                    "in_tasks.in_link.parent_task",
                    "in_tasks.in_link.status",
                    "in_tasks.in_link.responsible",
                    "in_tasks.in_link.is_checked",
                    "in_tasks.in_link.workflow_type",
                    "in_tasks.in_link.agile_story_points",
                    "in_tasks.relation_type",
                    "in_tasks.relation_type.out_type_name",
                    "in_tasks.in_link.cmf_deleted",
                    "in_tasks.out_link.cmf_deleted",
                    "out_tasks",
                    "out_tasks.out_link.out_link",
                    "out_tasks.out_link.logic_prefix",
                    "out_tasks.out_link.lists",
                    "out_tasks.out_link.activity",
                    "out_tasks.out_link.parent_task",
                    "out_tasks.out_link.status",
                    "out_tasks.out_link.responsible",
                    "out_tasks.out_link.is_checked",
                    "out_tasks.out_link.workflow_type",
                    "out_tasks.out_link.agile_story_points",
                    "out_tasks.relation_type",
                    "out_tasks.relation_type.in_type_name",
                    "out_tasks.out_link.logic_type.ui_color",
                    "out_tasks.out_link.priority",
                    "out_tasks.in_link.cmf_deleted",
                    "out_tasks.out_link.cmf_deleted",
                    "cmf_deleted"
                ]},
            token=token)
        self._api_call(
            method='CmfLink.list',
            kwargs={
                "filter": ["parent", "==", task_id],
                "fields": ["name", "url", "parent"]},
            token=token)
        self._api_call(
            method='CmfTask.get',
            kwargs={
                'id': task_id,
                'fields': [
                    "remaining_estimate",
                    "time_spent",
                    "timetracker_is_running",
                    "timetracker_history",
                    "time_estimate",
                    "waiting_for",
                    "status,",
                    "status.status_type",
                    "is_checked",
                    "estimate_work",
                    "op_gantt_task.actual_complete",
                    "op_gantt_task.actual_work",
                    "op_gantt_task.sched_work",
                    "op_gantt_task.const_work"]},
            token=token)

    def add_comment(self, missile=None, params=None):
        if not params:
            params = json.loads(missile)
        token = params['token']
        target = params.get('target')
        # todo document
        if target == 'sprint_task':
            obj_id = params['sprint_task_id']
        elif target == 'project_task':
            obj_id = params['project_task_id']
        else:
            obj_id = params['sprint_task_id']
        return self._api_call(
            method='CmfComment.create',
            kwargs={
                "parent_id": obj_id,
                "text": f"<p data-id=\"FRFMvEitOjG5dX\">Some comment text from {params['user_id']} to {obj_id}</p>",
                "tree_parent": None},
            token=token)

    def update_task(self, missile=None, params=None):
        if not params:
            params = json.loads(missile)
        token = params['token']
        field = params.get('field', 'status')
        if params.get('in_sprint'):
            task_id = params['sprint_task_id']
        else:
            task_id = params['project_task_id']
        task = self._api_call(
            method='CmfTask.get',
            kwargs={
                "id": task_id,
                "fields": [field, 'parent_id', 'workflow_id', 'lists']},
            token=token)
        # Всегда передаём object_id, всё равно js_cache не используется.
        field_options = self._api_call(
            method='CmfTask.field_options_list',
            args=[field],
            kwargs={
                'object_id': task_id,
                'filter_by_project': True,
                'object_fields': task,
                'slice': [0, 25]},
            token=token)

        self._api_call(
            method='CmfTask.update',
            args=[task_id],
            kwargs={
                field: field_options and random.choice(field_options) or None,
            },
            token=token)

    def new_task(self, missile=None, params=None):
        if not params:
            params = json.loads(missile)
        token = params['token']
        is_subtask = params.get('is_subtask')
        if params.get('in_sprint'):
            sprint_id = params['sprint_id']
        else:
            sprint_id = None

        task = self._api_call(
            method='CmfTask.create_dummy_task',
            kwargs={
                "parent_id": params['project_id'],
                "tree_parent": None},
            token=token)
        if not task:
            log.warning('Task not created')
            return
        changed_fields = {
            'name': f'HL Dynamic task {datetime.now():%Y-%m-%d %H:%M:%S}',
            'text': f"<p data-id=\"FRFMvEitOjG5dX\">Some tast text from {params['user_id']} to ...</p>",
        }
        if sprint_id:
            if is_subtask:
                changed_fields['parent_task'] = params['sprint_task_id']
            else:
                changed_fields['lists'] = [sprint_id]
        else:
            if is_subtask:
                changed_fields['parent_task'] = params['project_task_id']
        self._api_call(
            method='CmfTask.save_dummy_task',
            args=[task['id']],
            kwargs={'changed_fields': changed_fields},
            token=token)

    def sprint_task_list(self, missile=None, params=None):
        if not params:
            params = json.loads(missile)
        token = params['token']
        self._api_call(
            method='CmfTask.list',
            kwargs={
                "filter": ["fix_versions", "IN", [params['sprint_id']]],
                "fields": [
                    "--", "status", "status.status_type", "status.status_code", "status.status_code.code",
                    "deadline", "status_modified_at", "cmf_created_at", "cmf_modified_at", "child_tasks",
                    "child_tasks.cache_status_type", "priority", "orderno", "executors", "responsible",
                    "responsible.login", "responsible.name", "parent", "parent_logic_prefix", "lists",
                    "agile_story_points", "logic_type", "logic_type.ui_color", "parent_task", "parent_task.name",
                    "parent_task.priority", "parent_task.orderno", "parent_task.code", "parent_task.logic_prefix",
                    "parent_task.logic_type", "parent_task.parent_task_id", "parent_task.responsible_id",
                    "parent_task.parent_id", "op_gantt_task", "tags", "tags.name", "is_flagged", "responsible",
                    "lists", "executors", "responsible.name", "lists.name", "executors.name"],
                "include_archived": False,
                'slice': [0, 100],
            },
            token=token)

    # raw api_call?
    # def default(self, missile):
    #     log.info("Shoot %s(%s) default: %s", os.getpid(), gevent.getcurrent().name, missile)
