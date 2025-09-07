#!/bin/sh

ffmpeg -framerate 1 -i image%d.png \
  -filter_complex "split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" \
  -loop 0 output.gif
