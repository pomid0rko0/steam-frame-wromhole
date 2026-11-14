"""Imported first by ref/'s checks and by the tools started on their own that need numpy and the
rest (tools/compare/ runs inside tools/test_stereo.sh, already where the tests run): on a machine
without apt outside flake.nix's shell (the Steam Frame's SteamOS, whose Python has none of them; a
NixOS Python) the script runs again, with its arguments, through tools/box.sh: in its container on
the Frame, in the flake's shell on NixOS. Elsewhere (a cloud session, the container, the flake's
shell) this does nothing. EGL there is software; on the Frame it would be the headset's GPU."""
import os, sys, shutil

if not shutil.which('apt-get') and not os.environ.get('WORMHOLE_SHELL'):
    BOX = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools', 'box.sh')
    os.execv(BOX, [BOX, 'python3', os.path.abspath(sys.argv[0])] + sys.argv[1:])
