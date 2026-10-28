"""Imported first by the Python checks and tools, before numpy and the rest: on a machine without
apt that has podman (the Steam Frame's SteamOS, whose Python has none of them) the script runs
again, with its arguments, in tools/box.sh's container; elsewhere (a cloud session, the container)
this does nothing. EGL there is software; on the Frame it would be the headset's GPU."""
import os, sys, shutil

if not shutil.which('apt-get') and shutil.which('podman'):
    BOX = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools', 'box.sh')
    os.execv(BOX, [BOX, 'python3', os.path.abspath(sys.argv[0])] + sys.argv[1:])
