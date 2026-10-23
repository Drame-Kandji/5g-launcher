#!/usr/bin/env python3
"""Outil AT minimal pour le modem Quectel (aucune dépendance).

  at.py info          affiche AT_PORT, IMSI, IMEI, ICCID au format shell (pour eval)
  at.py cmd 'AT+...'  envoie une commande AT et affiche la réponse

Variable d'environnement AT_PORT : force le port série.
"""
import glob
import os
import re
import select
import sys
import termios
import time


def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = 0
    a[1] = 0
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[3] = 0
    a[4] = a[5] = termios.B115200
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    return fd


def at(fd, cmd, timeout=3.0):
    try:
        termios.tcflush(fd, termios.TCIOFLUSH)
    except termios.error:
        pass
    os.write(fd, (cmd + '\r').encode())
    buf = b''
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            continue
        try:
            chunk = os.read(fd, 4096)
        except (BlockingIOError, OSError):
            continue
        buf += chunk
        if b'\r\nOK\r\n' in buf or b'ERROR' in buf:
            break
    return buf.decode(errors='replace')


def find_port():
    forced = os.environ.get('AT_PORT')
    ports = [forced] if forced else sorted(glob.glob('/dev/ttyUSB*'), reverse=True)
    for p in ports:
        try:
            fd = open_port(p)
        except OSError:
            continue
        try:
            if 'OK' in at(fd, 'AT', 1.5):
                os.close(fd)
                return p
        finally:
            try:
                os.close(fd)
            except OSError:
                pass
    return None


def digits(text, n_min, n_max):
    m = re.search(r'(?<!\d)(\d{%d,%d})(?!\d)' % (n_min, n_max), text)
    return m.group(1) if m else ''


def read_imsi(fd):
    return digits(at(fd, 'AT+CIMI'), 14, 15)


def info():
    port = find_port()
    if not port:
        print('Aucun port AT ne répond (modem absent, ModemManager actif ou mauvais port).', file=sys.stderr)
        print('AT_PORT=')
        print('IMSI=')
        return 1
    fd = open_port(port)
    imsi = read_imsi(fd)
    if not imsi:
        print('IMSI illisible, tentative de réveil du modem (AT+CFUN=1)...', file=sys.stderr)
        at(fd, 'AT+CFUN=1', 5)
        time.sleep(8)
        imsi = read_imsi(fd)
    imei = digits(at(fd, 'AT+GSN'), 15, 15)
    m = re.search(r'\+QCCID:\s*(\w+)', at(fd, 'AT+QCCID'))
    iccid = m.group(1) if m else ''
    os.close(fd)
    print('AT_PORT=%s' % port)
    print('IMSI=%s' % imsi)
    print('IMEI=%s' % imei)
    print('ICCID=%s' % iccid)
    return 0 if imsi else 2


def cmd(command):
    port = find_port()
    if not port:
        print('Aucun port AT ne répond.', file=sys.stderr)
        return 1
    fd = open_port(port)
    print(at(fd, command, 5).strip())
    os.close(fd)
    return 0


if __name__ == '__main__':
    if len(sys.argv) >= 2 and sys.argv[1] == 'info':
        sys.exit(info())
    if len(sys.argv) >= 3 and sys.argv[1] == 'cmd':
        sys.exit(cmd(sys.argv[2]))
    print(__doc__)
    sys.exit(1)
