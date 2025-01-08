from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime
import hashlib
import json
import pathlib
import re
import sys
import yaml


@dataclass
class LineData:
    datetime: datetime = None
    login: str = None
    method: str = None
    args: list = None
    kwargs: dict = None
    fields: list = None
    data: dict = None


@dataclass
class MethodAgg:
    method: str = None
    kwargs: list = None
    fields: list = None
    slice: int = None
    # filter?
    agg_hash: str = None
    agg_count: int = 0
    agg_kwargs_list: list = field(default_factory=list, repr=False)


@dataclass
class LoadStats:
    begin: datetime = None
    end: datetime = None
    duration: int = None  # secs
    call_count: int = 0
    rps: float = None
    users_active: int = 0
    users_calls: dict = field(default_factory=lambda: defaultdict(int), repr=False)
    methods_calls: dict = field(default_factory=lambda: defaultdict(int), repr=False)
    get_count: int = 0
    ui_get_count: int = 0
    list_count: int = 0
    count_count: int = 0
    create_count: int = 0
    update_count: int = 0
    delete_count: int = 0
    other_count: int = 0

    def update_stats(self, line_data: LineData):
        if not self.begin:
            self.begin = line_data.datetime
        self.end = line_data.datetime
        self.duration = int((self.end - self.begin).total_seconds())
        self.call_count += 1
        if self.call_count and self.duration:
            self.rps = self.call_count/self.duration
        self.users_calls[line_data.login] += 1
        self.users_active = len(self.users_calls)
        hash_method = line_data.method
        # !!! todo: (create,delete,save)_dummy_task
        if line_data.method.endswith('.get') or line_data.method.endswith('.sget'):
            # hash_method += f':fields-{line_data.fields and len(line_data.fields)}'
            self.get_count += 1
        elif line_data.method.endswith('.ui_get'):
            # hash_method += f':fields-{line_data.fields and len(line_data.fields)}'
            self.ui_get_count += 1
        elif line_data.method.endswith('.list') or line_data.method.endswith('.slist'):
            # hash_method += f':fields-{line_data.fields and len(line_data.fields)}'
            self.list_count += 1
        elif line_data.method.endswith('.count'):
            self.count_count += 1
        elif line_data.method.endswith('.create') or line_data.method == 'CmfTask.create_dummy_task':
            self.create_count += 1
        elif line_data.method.endswith('.update') or line_data.method == 'CmfTask.save_dummy_task':
            self.update_count += 1
        elif line_data.method.endswith('.delete'):
            self.delete_count += 1
        else:
            self.other_count += 1

        self.methods_calls[hash_method] += 1


def parse_line():
    if match := line_re.match(line):
        try:
            line_raw_data = json.loads(match['json'])
        except ValueError:
            # Похоже из-за микса stdout/stderr битые данные, но менее 0.5%
            # print(match['json'][:100])
            return
        return LineData(
            datetime=datetime.strptime(match['datetime'], '%b %d %H:%M:%S'),
            login=line_raw_data['login'],
            method=line_raw_data['method'],
            args=line_raw_data['args'],
            kwargs=line_raw_data['kwargs'],
            fields=line_raw_data.get('fields'),
            data=line_raw_data,
        )


def ensure_current_stat(line_data: LineData):
    global current_stat, current_hour
    hour = line_data.datetime.strftime('%Y-%m-%d--%H')
    if hour != current_hour:
        if current_hour:
            print(
                f'hour {current_hour}:'
                f' users={current_stat.users_active},'
                f' calls={current_stat.call_count},'
                f' duration={current_stat.duration / 3600:.1f}h'
                f' rps={current_stat.call_count and current_stat.duration and current_stat.call_count//current_stat.duration}')
        current_hour = hour
        current_stat = LoadStats()


# Jan 29 13:34:24 bcrm.carbonsoft.ru uwsgi[839356]: API_TRACE <json>
line_re = re.compile(r'^(?P<datetime>[A-Za-z]{3} \d{1,2} \d{2}:\d{2}:\d{2}) .*: API_TRACE (?P<json>.*)')

trace_path = pathlib.Path(sys.argv[1])

skip_count = 0
total_stat = LoadStats()
current_stat = None
current_hour = None

by_method = defaultdict(list)

with trace_path.open() as trace_file:
    for line in trace_file:
        data = parse_line()
        if not data:
            skip_count += 1
            continue
        ensure_current_stat(data)
        total_stat.update_stats(data)
        current_stat.update_stats(data)
        by_method[data.method].append(data)

print()
print(
    f'result(skipped={skip_count}):'
    f' users={total_stat.users_active},'
    f' calls={total_stat.call_count},'
    f' duration={total_stat.duration/3600:.1f}h'
    f' rps={total_stat.call_count and total_stat.duration and total_stat.call_count//total_stat.duration}')
print(total_stat)
print()
top_methods = []
for method, method_calls in total_stat.methods_calls.items():
    if method.endswith('.create') or method.endswith('.update') or method.endswith('.delete')\
            or method in ('CmfTask.create_dummy_task', 'CmfTask.save_dummy_task') \
            or method_calls*100/total_stat.call_count > 0.3:
        top_methods.append([method, method_calls])
top_methods.sort(key=lambda val: val[1])
for method, method_calls in top_methods:
    print(f'{method_calls*100/total_stat.call_count:5.2f}% {method_calls:7d} {method}')
print()
print('Method Types:')
for method_type in ('get', 'ui_get', 'list', 'count', 'create', 'update', 'delete', 'other'):
    type_count = getattr(total_stat, f'{method_type}_count')
    print(f'{type_count*100/total_stat.call_count:5.2f}% {type_count:7d} {method_type}')


# Код ниже увеличивает время выполнения в 30 раз.
# Возможно надо делать опционально.
def write_method_detail(method):
    methods_agg = {}  # call_hash -> MethodAgg

    #     method: str = None
    #     kwargs: dict = None
    #     fields: list = None
    #     # filter?
    #     agg_hash: str = None
    #     agg_count: int = 0
    #     agg_kwargs_list: list = field(default_factory=list, repr=False)
    def do_agg():
        method_hash = ''
        kwargs = sorted(call_data.kwargs)
        method_hash += f'__{"-".join(kwargs)}'
        slice_ = call_data.kwargs.get('slice')
        if slice_:
            slice_ = slice_[1]-slice_[0]
            method_hash += f'__slice:{slice_}'
        fields = call_data.fields and sorted(call_data.fields)
        if fields:
            method_hash += f'__fields:{len(fields):02d}:{hashlib.sha1(str(fields).encode()).hexdigest()[:3]}'
        order_by = call_data.kwargs.get('order_by')
        if order_by:
            method_hash += f'__order:{"-".join(order_by)}'

        method_agg = methods_agg.get(method_hash)
        if not method_agg:
            method_agg = MethodAgg(method=method, kwargs=kwargs, fields=fields, slice=slice_, agg_hash=method_hash)
            methods_agg[method_hash] = method_agg
        method_agg.agg_count += 1
        method_agg.agg_kwargs_list.append(call_data.kwargs)

    for call_data in by_method[method]:
        do_agg()

    for method_agg in methods_agg.values():
        output_path = report_dir/f'{method}:{method_agg.agg_count:06d}_{method_agg.agg_count*100/method_calls:04.01f}_{method_agg.agg_hash}.yaml'
        with output_path.open('w') as output_file:
            yaml.dump(method_agg, output_file, yaml.Dumper)


report_dir = pathlib.Path(f'api_trace__{trace_path.stem}_{datetime.now():%Y%m%d_%H%M%S}')
if top_methods:
    report_dir.mkdir()
    for method, method_calls in top_methods:
        write_method_detail(method)
