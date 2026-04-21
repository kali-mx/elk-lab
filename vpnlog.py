import datetime
import random
import os

LOG_FILE = "/var/log/vpnlog"

def generate_logs():
    random.seed(42)

    now = datetime.datetime.now(datetime.timezone.utc)
    current_time = now - datetime.timedelta(hours=16)

    user_names = [
        "j.jones", "d.wade", "s.stillhour", "c.lin", "s.summer",
        "t.binlao", "c.yamashi", "l.stone", "o.devarius", "p.mallow",
        "m.chen", "a.patel", "r.garcia", "k.mueller", "e.dubois",
        "h.tanaka", "s.novak", "f.ahmed", "v.rossi", "j.smith"
    ]

    user_weights = [1] * len(user_names)
    user_weights[user_names.index("s.summer")] = 5

    locations = ["us-east-1", "us-west-1", "uk-london"]
    loc_weights = [1, 1, 3]

    user_configs = {}
    for i, name in enumerate(user_names):
        user_configs[name] = {
            "source_ip": f"72.14.{20+i}.1",
            "vpn_ip": f"10.10.10.{100+i}",
            "home_loc": random.choices(locations, weights=loc_weights, k=1)[0]
        }

    user_state = {name: False for name in user_names}

    logs = []
    total_events = 500

    auth_fail_indices = random.sample(range(total_events), 40)
    mallow_fails = auth_fail_indices[:25]

    while len(logs) < total_events:
        idx = len(logs)

        jitter = random.randint(60, 150)
        current_time += datetime.timedelta(seconds=jitter)

        if current_time > now:
            current_time = now

        ts = current_time.strftime("%Y-%m-%dT%H:%M:%SZ")

        if idx in mallow_fails:
            selected_user = "p.mallow"
        else:
            selected_user = random.choices(user_names, weights=user_weights, k=1)[0]

        config = user_configs[selected_user]
        src_ip = config['source_ip']
        vpn_ip = config['vpn_ip']
        loc = config['home_loc']

        if idx in auth_fail_indices:
            action = "auth_fail"
            logs.append(f"{ts} {action} {selected_user} {src_ip} 0.0.0.0 {loc}\n")
        else:
            if not user_state[selected_user]:
                action = "connection_start"
                user_state[selected_user] = True
            else:
                action = "connection_stop"
                user_state[selected_user] = False
            logs.append(f"{ts} {action} {selected_user} {src_ip} {vpn_ip} {loc}\n")

    with open(LOG_FILE, "w") as f:
        f.writelines(logs)

    print(f"Successfully generated logs in {LOG_FILE}")

if __name__ == "__main__":
    generate_logs()
