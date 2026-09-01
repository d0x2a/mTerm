#!/bin/sh
# Prints one screen exercising the parts of the renderer that are easy to
# break and impossible to unit-test: text attributes, glyph colour, the emoji
# atlas, cell alignment, and the overlays drawn on top of cells.
#
#   sh scripts/rendercheck.sh
#
# Everything here is a visual check — read the notes under each block and
# compare against what you expect. Sections 6-8 need the mouse and keyboard.

b() { printf '\033[1m%s\033[0m\n' "$1"; }

echo
b "1. TEXT ATTRIBUTES (SGR) — each must differ visibly from the 'normal' beside it"
printf '   normal  \033[2mfaint\033[0m      dim grey, evenly blended, no colour cast\n'
printf '   normal  \033[1mbold\033[0m       heavier stems, same advance so columns stay aligned\n'
printf '   normal  \033[3mitalic\033[0m     sloped, and still inside its own cell\n'
printf '   normal  \033[4munderline\033[0m  a line clear of the descenders in g, p, y\n'
printf '   normal  \033[7minverse\033[0m    foreground and background swapped\n'
printf '   combined:  \033[1;4mbold+underline\033[0m  \033[3;4mitalic+underline\033[0m  \033[1;3mbold+italic\033[0m  \033[1;3;4mall three\033[0m\n'
printf '   coloured:  \033[1;31mbold red\033[0m  \033[3;32mitalic green\033[0m  \033[4;34munderline blue\033[0m  \033[1;4;31mbold-underline-red\033[0m\n'
printf '   turned off again: \033[1mbold\033[22m normal  \033[3mitalic\033[23m normal  \033[4munder\033[24m normal  \033[7minv\033[27m normal\n'
printf '   faint keeps its colour: \033[31mred \033[2mred-faint\033[0m  \033[32mgrn \033[2mgrn-faint\033[0m  \033[34mblu \033[2mblu-faint\033[0m\n'
printf '   ghost text: \033[2mthe quick brown fox jumps over the lazy dog\033[0m\n'
echo
b "2. EMOJI + symbols — full colour, sitting inside their own cells"
echo "   😀 🎨 🚀 ✅ ❌ 🔥 🙂 🐛   ➜ → ✓ ★ █▓▒░"
echo
b "3. DOUBLE-WIDTH — each glyph spans two cells; the columns must stay square"
echo "   |日本語テキストです|"
echo "   |ab cd ef gh ij kl|"
echo "   combining marks stay on one cell: é à ô ñ (should read é à ô ñ)"
echo
b "4. TRUECOLOR ramp — a smooth gradient, no banding or stepping"
i=0; printf '   '
while [ $i -lt 72 ]; do
  r=$((255 - i * 3)); g=$((i * 3)); printf '\033[48;2;%d;%d;100m ' "$r" "$g"; i=$((i + 1))
done
printf '\033[0m\n'
echo
b "5. 256-COLOUR palette — 108 distinct steps, no repeats or gaps"
i=16; printf '   '
while [ $i -lt 124 ]; do printf '\033[48;5;%dm ' "$i"; i=$((i + 1)); done
printf '\033[0m\n'
echo
b "6. TRIGGERS — hold Cmd: underline appears and the pointer becomes a hand"
echo "   https://github.com/d0x2a/mTerm"
echo
b "7. SELECTION — drag across these; the tint must cover exactly what you drag"
echo "   aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
echo "   bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
echo
b "8. CURSOR — the block inverts the glyph under it; blinks when idle"
printf '   type here: '
