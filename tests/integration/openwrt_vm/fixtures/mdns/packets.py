#!/usr/bin/env python3
"""Exercise real repeater packets and TCP forwarding through isolated VM clients."""
import json
import select
import socket
import struct
import subprocess
import sys
import time

GROUP = ('224.0.0.251', 5353)

def dns_name(value):
    return b''.join(bytes([len(part)]) + part.encode() for part in value.split('.')) + b'\0'

def message(label, service, endpoint, query=False):
    service += '.local'
    header = struct.pack('!6H', 0, 0 if query else 0x8400, 1 if query else 0, 0 if query else 4, 0, 0)
    if query:
        return header + dns_name(service) + struct.pack('!HH', 12, 1)
    instance, host = label + '.' + service, label + '.local'
    def rr(name, kind, data):
        return dns_name(name) + struct.pack('!HHIH', kind, 1, 120, len(data)) + data
    return header + rr(service, 12, dns_name(instance)) + rr(instance, 33,
        struct.pack('!HHH', 0, 0, 631 if service.startswith('_ipp.') else 22) + dns_name(host)) \
        + rr(instance, 16, b'\x09txtvers=1') + rr(host, 1, socket.inet_aton(endpoint))

def endpoint(addresses):
    addresses = addresses.split(',')
    listeners = []
    for address in addresses:
        for port in (631, 22):
            tcp = socket.socket()
            tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            tcp.bind((address, port))
            tcp.listen(5)
            listeners.append(tcp)
    print('ready', flush=True)
    while True:
        for tcp in select.select(listeners, [], [], 10)[0]:
            connection, _ = tcp.accept()
            connection.sendall(b'fixture')
            connection.close()

def multicast(address):
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    udp.bind(('', 5353))
    udp.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                   socket.inet_aton(GROUP[0]) + socket.inet_aton(address))
    udp.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(address))
    udp.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
    return udp

def receive(address, label, expected):
    udp = multicast(address)
    print('ready', flush=True)
    deadline, found = time.monotonic() + 2, False
    while time.monotonic() < deadline:
        udp.settimeout(max(0.01, deadline - time.monotonic()))
        try:
            packet, _ = udp.recvfrom(65535)
            if label.encode() in packet:
                found = True
                break
        except socket.timeout:
            break
    assert found == expected, (label, 'received' if found else 'missing', expected)

def child(namespace, *args):
    return subprocess.Popen(['ip', 'netns', 'exec', namespace, sys.executable, __file__, *args],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

def ready(process):
    assert process.stdout.readline().strip() == 'ready', process.stderr.read()

def finished(process):
    out, err = process.communicate(timeout=8)
    assert process.returncode == 0, out + err

def main():
    devices = json.load(open('/tmp/devicecode-mdns-test/devices.json'))
    addresses = {'adm': ['172.28.8.' + str(n) for n in (250, 251, 254, 249, 73)],
                 'jan': ['172.28.32.10'], 'isolated': ['172.28.100.10']}
    processes = []
    def ip(*args):
        subprocess.run(['ip', *args], check=True)
    try:
        for segment, bridge in devices.items():
            ns, host = 'dcmdns-' + segment, 'dcmd-' + segment
            ip('netns', 'add', ns)
            ip('link', 'add', host, 'type', 'veth', 'peer', 'name', 'peer-' + segment)
            ip('link', 'set', 'peer-' + segment, 'netns', ns)
            ip('link', 'set', host, 'master', bridge)
            ip('link', 'set', host, 'up')
            ip('-n', ns, 'link', 'set', 'lo', 'up')
            ip('-n', ns, 'link', 'set', 'peer-' + segment, 'name', 'eth0')
            ip('-n', ns, 'link', 'set', 'eth0', 'up')
            for address in addresses[segment]:
                ip('-n', ns, 'addr', 'add', address + '/24', 'dev', 'eth0')
            ip('-n', ns, 'route', 'add', 'default', 'via', addresses[segment][0].rsplit('.', 1)[0] + '.1')
            if segment != 'jan':
                process = child(ns, 'endpoint', ','.join(addresses[segment]))
                processes.append(process)
                ready(process)
        time.sleep(0.3)
        for address, port, allowed in [
            ('172.28.8.250', 631, True), ('172.28.8.251', 631, True), ('172.28.8.254', 631, True),
            ('172.28.8.249', 631, False), ('172.28.8.73', 631, False), ('172.28.8.250', 22, False),
            ('172.28.100.10', 631, False),
        ]:
            finished(child('dcmdns-jan', 'connect', address, str(port), str(int(allowed))))
            print('TCP', address, port, 'allowed' if allowed else 'blocked', flush=True)
        for sender, source, receiver, dest, label, service, expected, query in [
            ('adm', '172.28.8.250', 'jan', '172.28.32.10', 'shared-first', '_ipp._tcp', True, False),
            ('adm', '172.28.8.251', 'jan', '172.28.32.10', 'shared-second', '_ipp._tcp', True, False),
            ('adm', '172.28.8.73', 'jan', '172.28.32.10', 'private-printer', '_ipp._tcp', False, False),
            ('adm', '172.28.8.249', 'jan', '172.28.32.10', 'outside-range', '_ipp._tcp', False, False),
            ('adm', '172.28.8.250', 'jan', '172.28.32.10', 'extra-service', '_ssh._tcp', True, False),
            ('jan', '172.28.32.10', 'adm', '172.28.8.250', '_ipp', '_ipp._tcp', True, True),
            ('jan', '172.28.32.10', 'adm', '172.28.8.250', 'guest-advertisement', '_ssh._tcp', True, False),
            ('isolated', '172.28.100.10', 'jan', '172.28.32.10', 'internal-printer', '_ipp._tcp', False, False),
        ]:
            process = child('dcmdns-' + receiver, 'receive', dest, label, str(int(expected)))
            processes.append(process)
            ready(process)
            finished(child('dcmdns-' + sender, 'send', source, label, service, str(int(query))))
            finished(process)
            print('mDNS', label, 'repeated' if expected else 'blocked', flush=True)
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        for segment in devices:
            subprocess.run(['ip', 'netns', 'del', 'dcmdns-' + segment], check=False)
            subprocess.run(['ip', 'link', 'del', 'dcmd-' + segment], check=False, stderr=subprocess.DEVNULL)

if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'main'
    if mode == 'endpoint':
        endpoint(sys.argv[2])
    elif mode == 'receive':
        receive(sys.argv[2], sys.argv[3], sys.argv[4] == '1')
    elif mode == 'send':
        udp = multicast(sys.argv[2])
        # Bind the sending socket to the chosen source even when the fixture
        # has multiple addresses on one interface.
        udp.close()
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        udp.bind((sys.argv[2], 5353))
        udp.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(sys.argv[2]))
        udp.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
        udp.sendto(message(sys.argv[3], sys.argv[4], sys.argv[2], sys.argv[5] == '1'), GROUP)
    elif mode == 'connect':
        connected = False
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as connection:
                connection.settimeout(1)
                connection.connect((sys.argv[2], int(sys.argv[3])))
                connected = connection.recv(7) == b'fixture'
        except OSError:
            pass
        assert connected == (sys.argv[4] == '1'), (sys.argv[2:4], connected)
    else:
        main()
