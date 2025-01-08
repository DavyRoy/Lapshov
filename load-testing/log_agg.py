import json
import sys
import datetime
from collections import defaultdict


agg_datetime = None
agg_data = defaultdict(list)


def print_data():
    print(f'{agg_datetime:%Y-%m-%d %H-%M-%S}')
    for method in sorted(agg_data):
        print(f'{method:30} {sum(agg_data[method])/len(agg_data[method]):.1f}')


for line in sys.stdin:
    data = json.loads(line)['data']
    curr_datetime = datetime.datetime.fromtimestamp(data['ts'])
    curr_datetime = curr_datetime.replace(second=0)
    if agg_datetime != curr_datetime:
        if agg_datetime:
            print_data()
        agg_datetime = curr_datetime
        agg_data = defaultdict(list)
    total_cnt = 0
    for method in data['tagged']:
        cnt = data['tagged'][method]['proto_code']['count'].get('200')
        if cnt:
            agg_data[method].append(cnt)
            total_cnt += cnt
    if total_cnt:
        agg_data['Total'].append(total_cnt)

if agg_datetime:
    print_data()
