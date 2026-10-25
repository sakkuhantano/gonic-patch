#!/bin/bash

echo "[Container] Membuat symlink scripts..."

ln -sf /hostconfig/media_watcher.sh /usr/local/bin/media_watcher.sh
ln -sf /hostconfig/start-dsm.sh /usr/local/bin/start-dsm.sh
ln -sf /hostconfig/main_script.py /usr/local/bin/main_script.py
ln -sf /hostconfig/asterisk-monitor.py /usr/local/bin/asterisk-monitor.py
ln -sf /hostconfig/start-gonic.sh /usr/local/bin/start-gonic.sh

echo "[Container] Symlink scripts selesai."

if [ -f /root/.aria2/aria2.session ]; then
    chown slskd:users /root/.aria2/aria2.session
fi

echo "[Container] Permission aria2 selesai."

# PHP-FPM runtime directory
#mkdir -p /run/php
#chown slskd:users /run/php

#echo "[Container] PHP-FPM runtime directory siap."

exec /hostconfig/startup.sh