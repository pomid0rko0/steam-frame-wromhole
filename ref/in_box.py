"""Imported first by ref/'s checks and by the tools started on their own that need numpy and the
rest (tools/compare/ runs inside tools/test_stereo.sh, already in the container): on a machine without
apt (the Steam Frame's SteamOS, whose Python has none of them) the script runs
again, with its arguments, in tools/box.sh's container; elsewhere (a cloud session, the container)
this does nothing. EGL there is software; on the Frame it would be the headset's GPU."""
import os, sys, shutil

if not shutil.which('apt-get'):
    BOX = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools', 'box.sh')
    os.execv(BOX, [BOX, 'python3', os.path.abspath(sys.argv[0])] + sys.argv[1:])
