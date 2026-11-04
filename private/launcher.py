#!/usr/bin/env python3
"""Starts valkey-server for rules_valkey. Two modes:

  launcher.py check --server BIN --marker OUT --config FILE [--acl FILE]
      valkey_config's validation action. Starts valkey-server on the
      config with TCP off (--port 0) and a unix socket in a short scratch
      dir, overriding everything that points at the host (dir, logfile,
      pidfile, daemonize, cluster-config-file, and aclfile when an ACL
      file is given). A config valkey-server refuses (unknown directive,
      bad value, bad ACL rule, missing file) fails with its own message.
      Writes OUT once the server is ready. No network access.

  launcher.py serve --server BIN --cli BIN --env-file PATH --state-dir DIR
                    --ready-timeout S [--config FILE] [--acl FILE]
                    [--password PW] [--rdb FILE] [--seed FILE]...
                    [--shards N --replicas R] [-- EXTRA_SERVER_ARGS...]
      valkey_server. Standalone (default): one server on a free port.
      With --shards N (>= 3): N primaries (+ R replicas each) with
      cluster-enabled, joined by `valkey-cli --cluster create`, ready once
      every node reports cluster_state:ok. Then runs each seed file
      through valkey-cli (following cluster redirects); any `(error)`
      reply fails the start. Writes the env file atomically:
        VALKEY_HOST=127.0.0.1
        VALKEY_PORT=<port>            (the first primary in a cluster)
        VALKEY_URL=redis://[:<password>@]127.0.0.1:<port>
        VALKEY_SOCKET=<unix socket>   (standalone only)
        VALKEY_CLUSTER_NODES=127.0.0.1:<p1>,...   (cluster only)
        VALKEY_PASSWORD / VALKEYCLI_AUTH          (with --password)
        VALKEY_CLI / VALKEY_SERVER=<absolute paths>
      SIGTERM / SIGINT stop every server, remove the env file and exit 0;
      if a server dies, exits with its status.

  launcher.py stage-for-chart SRC OUT
      valkey_install's config overlay: SRC with the host directives and
      the chart-owned ones (port, bind, protected-mode) commented out.

In both server modes a server that refuses its config, exits, or isn't ready in
time is an error that names the cause and prints the server's log.
"""

import argparse
import os
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

_READY = "Ready to accept connections"


class Failed(Exception):
    """A server refused its config, or a start / seed step failed."""


def _log(msg):
    print(f"[valkey] {msg}", file=sys.stderr, flush=True)


def _read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return "(no log)"


def _short_dir():
    """A scratch dir for unix sockets: their paths must be under 108
    bytes, and Bazel's TEST_TMPDIR is usually longer."""
    return tempfile.mkdtemp(prefix="rv-", dir="/tmp" if os.path.isdir("/tmp") else None)


def _free_ports(n):
    socks = []
    try:
        for _ in range(n):
            s = socket.socket()
            s.bind(("127.0.0.1", 0))
            socks.append(s)
        return [s.getsockname()[1] for s in socks]
    finally:
        for s in socks:
            s.close()


def _env():
    """valkey-server/-cli environment: no VALKEYCLI_AUTH / REDISCLI_AUTH
    from the caller (an env file sourced by a test sets one)."""
    return {k: v for k, v in os.environ.items()
            if k not in ("VALKEYCLI_AUTH", "REDISCLI_AUTH")}


# Directives that point at the host. valkey-server applies some of them
# while parsing (`dir` chdirs, `logfile` is opened), before command-line
# options can override them, so the staged copy comments them out; the
# launcher sets its own values on the command line.
_HOST_DIRECTIVES = {"dir", "logfile", "pidfile", "aclfile", "unixsocket",
                    "unixsocketperm", "daemonize", "supervised", "cluster-config-file"}


# In the cluster install, the chart's base config also owns networking
# (port 6379, bind *, protected-mode no), which the Service relies on.
_CHART_DIRECTIVES = _HOST_DIRECTIVES | {"port", "bind", "protected-mode"}


def neutralize(text, directives):
    """Comment out `directives` in place (line numbers still match)."""
    out = []
    for line in text.split("\n"):
        words = line.split()
        if words and words[0].lower() in directives:
            line = "# rules_valkey overrides: " + line
        out.append(line)
    return "\n".join(out)


def stage_config(src, dest_dir):
    """Copy `src` to dest_dir/valkey.conf with host directives commented
    out (line numbers in valkey-server's errors still match)."""
    with open(src) as f:
        text = neutralize(f.read(), _HOST_DIRECTIVES)
    dest = os.path.join(dest_dir, "valkey.conf")
    with open(dest, "w") as f:
        f.write(text)
    return dest


def _host_overrides(workdir):
    # Command-line options override the config file.
    return ["--dir", workdir, "--daemonize", "no", "--logfile", "", "--pidfile", "",
            "--supervised", "no", "--cluster-config-file", "nodes.conf"]


def _ping(port, password):
    """True once the server answers PING (not -LOADING)."""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1) as s:
            cmd = b""
            if password:
                pw = password.encode()
                cmd += b"*2\r\n$4\r\nAUTH\r\n$%d\r\n%s\r\n" % (len(pw), pw)
            cmd += b"*1\r\n$4\r\nPING\r\n"
            s.sendall(cmd)
            data = b""
            want = 2 if password else 1
            while data.count(b"\r\n") < want:
                chunk = s.recv(4096)
                if not chunk:
                    return False
                data += chunk
            last = data.split(b"\r\n")[want - 1]
            # NOAUTH / WRONGPASS: up, but our password can't log in (an
            # ACL file without a default user); good enough for "ready".
            return last == b"+PONG" or last.startswith((b"-NOAUTH", b"-WRONGPASS"))
    except OSError:
        return False


def _start_one(server, args, log_path, port, password, deadline, procs):
    with open(log_path, "w") as log:
        proc = subprocess.Popen([server] + args, stdout=log, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, env=_env())
    procs.append(proc)
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return proc, False
        if _READY in _read(log_path) and (port is None or _ping(port, password)):
            return proc, True
        time.sleep(0.05)
    return proc, False


def _stop(procs):
    for p in procs:
        if p.poll() is None:
            p.terminate()
    for p in procs:
        try:
            p.wait(10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()


# ---- check ---------------------------------------------------------------------

def check(args):
    work = _short_dir()
    procs = []
    try:
        config = stage_config(args.config, work)
        cmd = [config, "--port", "0",
               "--unixsocket", os.path.join(work, "s.sock")] + _host_overrides(work)
        if args.acl:
            cmd += ["--aclfile", os.path.abspath(args.acl)]
        log_path = os.path.join(work, "log")
        proc, ready = _start_one(args.server, cmd, log_path, None, None,
                                 time.monotonic() + args.ready_timeout, procs)
        if not ready:
            out = _read(log_path)
            why = ("valkey-server refused it" if proc.poll() is not None
                   else f"valkey-server was not ready within {args.ready_timeout:g}s")
            print(f"valkey_config: {args.config}: {why}:\n{_explain(out)}", file=sys.stderr)
            return 1
    finally:
        _stop(procs)
        shutil.rmtree(work, ignore_errors=True)
    open(args.marker, "w").close()
    return 0


def _explain(log):
    """The useful part of a failed start: the FATAL CONFIG block, or the
    last warning lines."""
    lines = [l for l in log.splitlines() if l.strip()]
    for i, l in enumerate(lines):
        if "FATAL CONFIG FILE ERROR" in l:
            return "\n".join("  " + x for x in lines[i:])
    errs = [l.split(" # ", 1)[1] if " # " in l else l for l in lines if " # " in l]
    return "\n".join("  " + x for x in (errs or lines[-10:]))


# ---- serve ---------------------------------------------------------------------

def _cli(args, port, extra, stdin=None, cluster=False):
    cmd = [args.cli, "-h", "127.0.0.1", "-p", str(port), "--no-raw"]
    if cluster:
        cmd.append("-c")
    env = _env()
    if args.password:
        env["VALKEYCLI_AUTH"] = args.password
    return subprocess.run(cmd + extra, input=stdin, capture_output=True, text=True, env=env)


def _server_args(args, workdir, port, sock=None):
    a = []
    if args.config:
        a.append(stage_config(args.config, workdir))
    a += ["--port", str(port), "--bind", "127.0.0.1"] + _host_overrides(workdir)
    if sock:
        a += ["--unixsocket", sock, "--unixsocketperm", "700"]
    if args.acl:
        a += ["--aclfile", os.path.abspath(args.acl)]
    if args.password:
        a += ["--requirepass", args.password]
        if args.shards:
            a += ["--masterauth", args.password]
    return a


def start(args, procs, sock_dir):
    """Start the server(s). Returns (ports, socket or None, log paths)."""
    deadline = time.monotonic() + args.ready_timeout
    nodes = args.shards * (1 + args.replicas) if args.shards else 1
    for attempt in range(1, 6):
        ports = _free_ports(nodes * 2)
        client, bus = ports[:nodes], ports[nodes:]
        sock = os.path.join(sock_dir, "valkey.sock") if not args.shards else None
        logs = []
        started = []
        clash = False
        for i in range(nodes):
            workdir = os.path.join(args.state_dir, f"node{i}" if args.shards else "data")
            shutil.rmtree(workdir, ignore_errors=True)
            os.makedirs(workdir)
            if args.rdb:
                shutil.copyfile(args.rdb, os.path.join(workdir, "dump.rdb"))
            a = _server_args(args, workdir, client[i], sock)
            if args.rdb:
                a += ["--dbfilename", "dump.rdb"]
            if args.shards:
                a += ["--cluster-enabled", "yes", "--cluster-port", str(bus[i])]
            a += args.extra
            log_path = os.path.join(args.state_dir, f"node{i}.log" if args.shards else "valkey.log")
            logs.append(log_path)
            proc, ready = _start_one(args.server, a, log_path, client[i], args.password,
                                     deadline, procs)
            started.append(proc)
            if not ready:
                out = _read(log_path)
                if proc.poll() is None:
                    _stop(started)
                    raise Failed(f"valkey-server was not ready within {args.ready_timeout:g}s "
                                 f"on port {client[i]}. Log:\n{out}")
                _stop(started)
                if "Address already in use" in out and attempt < 5:
                    _log(f"a port was taken (attempt {attempt}); retrying")
                    clash = True
                    break
                raise Failed(f"valkey-server exited with status {proc.returncode} before it "
                             f"was ready:\n{_explain(out)}")
        if clash:
            del procs[:]
            continue
        if args.shards:
            _create_cluster(args, client, deadline)
        return client, sock, logs
    raise Failed("valkey-server could not get free ports after 5 attempts")


def _create_cluster(args, ports, deadline):
    nodes = [f"127.0.0.1:{p}" for p in ports]
    r = _cli(args, ports[0], ["--cluster", "create"] + nodes +
             ["--cluster-replicas", str(args.replicas), "--cluster-yes"])
    if r.returncode != 0:
        raise Failed(f"`valkey-cli --cluster create` failed:\n{r.stdout}{r.stderr}")
    while True:
        states = []
        for p in ports:
            info = _cli(args, p, ["cluster", "info"]).stdout
            states.append("cluster_state:ok" in info and
                          f"cluster_known_nodes:{len(ports)}" in info)
        if all(states):
            return
        if time.monotonic() >= deadline:
            raise Failed(f"the cluster was not ready (cluster_state:ok on all {len(ports)} "
                         f"nodes) within {args.ready_timeout:g}s")
        time.sleep(0.05)


def seed(args, port):
    for path in args.seed:
        with open(path) as f:
            commands = f.read()
        r = _cli(args, port, [], stdin=commands, cluster=bool(args.shards))
        errors = [l for l in r.stdout.splitlines() if l.startswith("(error)")]
        if r.returncode != 0 or errors:
            raise Failed(f"seed {path} failed:\n" +
                         "\n".join("  " + l for l in (errors or (r.stdout + r.stderr).splitlines())))
        _log(f"seeded {os.path.basename(path)}")


def write_env(env_file, values):
    tmp = env_file + ".tmp"
    with open(tmp, "w") as f:
        for k, v in values.items():
            f.write(f"{k}={shlex.quote(str(v))}\n")
    os.replace(tmp, env_file)


def serve(args):
    if args.shards and args.shards < 3:
        _log(f"--shards {args.shards}: a Valkey cluster needs at least 3 primaries")
        return 1
    if args.shards and args.rdb:
        _log("--rdb is for a standalone server; seed a cluster with --seed")
        return 1
    os.makedirs(args.state_dir, exist_ok=True)
    try:
        os.remove(args.env_file)
    except FileNotFoundError:
        pass

    # Installed before the servers start, so a signal during start-up
    # still stops them. Once ready, the handler only asks them to stop: the
    # main thread is blocked in proc.wait(), which holds Popen's wait lock.
    procs, stopping, ready = [], [], []

    def _on_signal(signum, _frame):
        if stopping:
            return
        _log(f"signal {signum}; stopping")
        stopping.append(signum)
        for p in procs:
            if p.poll() is None:
                p.terminate()
                killer = threading.Timer(10, p.kill)
                killer.daemon = True
                killer.start()
        if not ready:
            raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    sock_dir = _short_dir()
    try:
        try:
            ports, sock, logs = start(args, procs, sock_dir)
            seed(args, ports[0])
        except Failed as e:
            _log(str(e))
            _stop(procs)
            return 1
        except SystemExit:
            _stop(procs)
            raise

        auth = f":{args.password}@" if args.password else ""
        values = {
            "VALKEY_HOST": "127.0.0.1",
            "VALKEY_PORT": ports[0],
            "VALKEY_URL": f"redis://{auth}127.0.0.1:{ports[0]}",
        }
        if sock:
            values["VALKEY_SOCKET"] = sock
        if args.shards:
            values["VALKEY_CLUSTER_NODES"] = ",".join(f"127.0.0.1:{p}" for p in ports)
        if args.password:
            values["VALKEY_PASSWORD"] = args.password
            values["VALKEYCLI_AUTH"] = args.password
        values["VALKEY_CLI"] = os.path.abspath(args.cli)
        values["VALKEY_SERVER"] = os.path.abspath(args.server)
        write_env(args.env_file, values)
        ready.append(True)
        _log(f"ready on 127.0.0.1:{ports[0]}"
             + (f" ({len(ports)}-node cluster)" if args.shards else "")
             + f"; env file {args.env_file}")

        # Wait for the first server to exit; then stop the rest.
        done = None
        while done is None:
            for p in procs:
                if p.poll() is not None:
                    done = p
                    break
            else:
                try:
                    procs[0].wait(0.2)
                except subprocess.TimeoutExpired:
                    pass
        _stop(procs)
        try:
            os.remove(args.env_file)
        except FileNotFoundError:
            pass
        if stopping:
            return 0
        i = procs.index(done)
        _log(f"valkey-server exited with status {done.returncode}. Log:\n{_read(logs[i])}")
        return done.returncode or 1
    finally:
        shutil.rmtree(sock_dir, ignore_errors=True)


def main(argv):
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="mode", required=True)

    c = sub.add_parser("check")
    c.add_argument("--server", required=True)
    c.add_argument("--marker", required=True)
    c.add_argument("--config", required=True)
    c.add_argument("--acl")
    c.add_argument("--ready-timeout", type=float, default=30.0)

    s = sub.add_parser("serve")
    s.add_argument("--server", required=True)
    s.add_argument("--cli", required=True)
    s.add_argument("--env-file", required=True)
    s.add_argument("--state-dir", required=True)
    s.add_argument("--ready-timeout", type=float, default=30.0)
    s.add_argument("--config")
    s.add_argument("--acl")
    s.add_argument("--password", default="")
    s.add_argument("--rdb")
    s.add_argument("--seed", action="append", default=[])
    s.add_argument("--shards", type=int, default=0)
    s.add_argument("--replicas", type=int, default=0)
    s.add_argument("extra", nargs="*")

    st = sub.add_parser("stage-for-chart")
    st.add_argument("src")
    st.add_argument("out")

    args = p.parse_args(argv)
    if args.mode == "stage-for-chart":
        with open(args.src) as f:
            text = neutralize(f.read(), _CHART_DIRECTIVES)
        with open(args.out, "w") as f:
            f.write(text)
        return 0
    if not 0 < args.ready_timeout < float("inf"):
        _log(f"--ready-timeout must be a positive number of seconds, got {args.ready_timeout}")
        return 1
    args.server = os.path.abspath(args.server)
    if args.mode == "check":
        return check(args)
    args.cli = os.path.abspath(args.cli)
    return serve(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
