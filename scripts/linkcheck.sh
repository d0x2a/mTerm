#!/bin/sh
# Prints one screen exercising link detection.
#
#   sh scripts/linkcheck.sh
#
# Links are not drawn any differently from ordinary text until you point at
# one. With ⌘ down, the link under the pointer — and only that one — turns the
# theme's accent colour and gains an underline in the same colour, and the
# cursor becomes a pointing hand. Everything else on screen stays exactly as it
# was. That is what each section below is checking.
#
# Section 3 depends on the shell reporting its cwd (OSC 7). If those stay
# inert while section 2 works, shell integration isn't active.

b() { printf '\033[1m%s\033[0m\n' "$1"; }
n() { printf '\033[2m   %s\033[0m\n' "$1"; }

# Real entries in the current directory, so section 3 works from anywhere.
rel_dir=$(ls -p 2>/dev/null | grep '/$' | head -1)
rel_file=$(ls -p 2>/dev/null | grep -v '/$' | head -1)
[ -n "$rel_dir" ] || rel_dir="(no subdirectory here)"
[ -n "$rel_file" ] || rel_file="(no file here)"

echo
b "0. ⌘ ALONE CHANGES NOTHING — hold ⌘ without moving the pointer"
n "no underline, no tint, no colour shift anywhere. Links light up one at a"
n "time, under the pointer only — if the whole screen reacts to ⌘, that's"
n "the bug. Text and underline must be the same colour."
echo
b "1. URLS WITH A SCHEME — ⌘-hover recolours + underlines it"
echo "   https://github.com/d0x2a/mTerm"
echo "   http://example.org/a/b?x=1&y=2#frag"
echo "   file:///etc/hosts"
echo
b "2. SCHEMELESS URLS — ⌘-hover recolours + underlines it"
echo "   code.d0x2a.com"
echo "   code.d0x2a.com/docs"
echo "   www.example.co.uk"
echo "   mterm-web.docker.localhost/api"
echo "   localhost:3000/health"
echo "   127.0.0.1:8080/status"
n "⌘-click localhost:3000 opens http://, the .docker.localhost one https://"
echo
b "3. FILE PATHS — ⌘-hover recolours, ⌘-click reveals in Finder"
echo "   /usr/local/bin"
echo "   ~/Library"
echo "   $rel_dir"
echo "   ./$rel_file"
echo "   ./$rel_file:42:10"
n "the :42:10 is part of the link; ⌘-click still reveals the file"
n "a bare \"$rel_file\" with no slash is NOT a link, by design — otherwise"
n "every word in ls output that happened to name a file would be one"
echo
b "4. WRAPPED — one URL long enough to span several rows"
printf '   https://example.com/'
i=1
while [ $i -le 24 ]; do printf 'some-long-path-segment-%d/' "$i"; i=$((i + 1)); done
printf 'end\n'
n "⌘-hover any single row of it: text and underline must both run across"
n "ALL of its rows at once — that is the extent of what opens. ⌘-click any row"
n "and the browser must receive the whole address, not the visible fragment."
echo
b "5. WRAPPED, NEGATIVE — two separate lines that must not fuse"
echo "   code.d0x2a"
echo ".com/should-not-join"
n "these are two unwrapped lines. Joining them would invent a link that"
n "isn't there — neither line should underline or offer a hand."
echo
b "6. MUST STAY PLAIN — ⌘-hover these: no recolour, no underline, no hand"
echo "   main.py   README.md   libfoo.so   serde.rs   deploy.sh   mTerm.app"
echo "   archive.zip   clip.mov   version v1.2.3   sha 3f2a.b1c9"
echo "   mail bob@code.d0x2a.com     (the domain half must not be clickable)"
echo "   the word localhost on its own"
echo
b "7. MUST STAY PLAIN — path-shaped text that isn't a path"
echo "   either and/or both, w/e"
echo "   /no/such/path/anywhere"
echo "   cc -I/usr/include foo.c"
n "these match the regex on purpose — the on-disk check is what drops them"
echo
b "8. DUPLICATES — two copies of one address, on their own lines"
echo "   https://example.com/same"
echo "   https://example.com/same"
n "⌘-hover the first: only the FIRST lights up. Identical text is not the"
n "same link, and hovering one must not light up the other."
echo
b "9. COLOURED OUTPUT — hovering replaces the text colour"
printf '   \033[32mM  Sources/mTerm/Renderer/Renderer.swift\033[0m\n'
printf '   \033[31merror:\033[0m see \033[36mhttps://example.com/docs\033[0m for details\n'
n "hovering one of these swaps its green/cyan for the accent, and it comes"
n "back on the way out. Only the hovered link, never the rest of the line."
echo
b "10. SELECTION still works"
echo "   drag across https://example.com/select-me without holding ⌘"
n "plain drag selects text as usual; ⌘ is what switches to opening"
echo
