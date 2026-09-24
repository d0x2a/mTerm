#!/bin/sh
# Prints one screen exercising command-block copying.
#
#   sh scripts/blockcheck.sh
#
# Nothing on this screen is drawn differently until you hold ⌘. With ⌘ down,
# the block under the pointer — and only that one — tints, covering every row
# it occupies, including rows it wrapped onto. That tint is the promise: it is
# exactly what ⌘-click puts on the clipboard, after asking. ⎋ cancels.
#
# A block is a run of non-blank lines between blank ones whose first line reads
# like a command. That is all the terminal has to go on: a TUI rendering
# markdown prints code blocks with no styling of their own, so nothing in the
# bytes says which paragraph is code and which is prose.

b() { printf '\033[1m%s\033[0m\n' "$1"; }
n() { printf '\033[2m   %s\033[0m\n' "$1"; }

echo
b "0. ⌘ ALONE CHANGES NOTHING — hold ⌘ without moving the pointer"
n "no tint anywhere. Blocks light up one at a time, under the pointer only."
echo
b "1. A COMMAND BLOCK — ⌘-hover tints all four rows, ⌘-click asks"
echo
echo "  kubectl -n ahead patch deploy app --type=json -p '[{\"op\":\"add\","
echo "    \"path\":\"/spec/template/spec/containers/0/env/0\","
echo "    \"value\":{\"name\":\"REDIS_PASSWORD\",\"valueFrom\":{\"secretKeyRef\":"
echo "      {\"name\":\"cache-secret\",\"key\":\"REDIS_PASSWORD\"}}}}]'"
echo
n "the copy drops the two-space indent but keeps the inner indentation, so it"
n "pastes into a shell as written."
echo
b "2. THE PROSE ABOVE IT — stays inert under ⌘"
echo
echo "  Two edits to the live Deployment. Order matters: Kubernetes only"
echo "  expands \$(VAR) if the referenced variable is defined earlier."
echo
n "first word is not a command and there are no flags, so it is not a target."
n "That is the gate doing its job — it is what keeps ⌘ quiet on ordinary text."
echo
b "3. A TOOL YOU MAY NOT HAVE — the flag carries it"
echo
echo "  terraform apply -auto-approve -var-file=prod.tfvars"
echo
echo "  pulumi up"
echo
n "the first still tints without terraform installed, because of the flags."
n "the second cannot: nothing about \"pulumi up\" says command rather than"
n "prose, so it is left alone. Select it by hand — that is the cost of the gate."
echo
b "4. A WRAPPED COMMAND — the tint covers both rows, the copy rejoins them"
echo
echo "  git log --graph --abbrev-commit --decorate --date=relative --all --pretty=format:'%h %s %d'"
echo
n "narrow the window until it wraps. The clipboard must hold one line, with"
n "no newline where the wrap was."
echo
b "5. A LINK INSIDE A BLOCK — the link wins where it matches"
echo
echo "  curl -fsSL https://example.com/install.sh | sh"
echo
n "⌘-click the URL opens it; ⌘-click anywhere else in the line offers to copy"
n "the command. The narrower target keeps the meaning ⌘-click already had."
echo
b "6. A TRANSCRIPT — the command tints, its output does not"
echo
echo "$ kubectl rollout restart deployment/payments-api -n payments"
echo "deployment.apps/payments-api restarted"
echo
n "⌘-hover the first line: only that row tints, and the copy has neither the"
n "\$ nor the output. ⌘-hover the second: nothing, because pointing at output"
n "is not pointing at the command."
echo
b "7. A COMMAND THAT CONTINUES — the backslashes hold it together"
echo
echo "$ kubectl create secret generic payments-db-credentials -n payments \\"
echo "    --from-literal=DB_USER=payments_svc \\"
echo "    --dry-run=client -o yaml | kubectl apply -f -"
echo "secret/payments-db-credentials created"
echo
n "all three command rows tint as one; the created line does not join them."
echo
b "8. A NUMBERED LIST — the heading is not part of the command"
echo
echo " 1. Recreate the whole secret with new values (idempotent)"
echo "  kubectl create secret generic moonbase-db-creds \\"
echo "    --namespace lunar-prod \\"
echo "    --dry-run=client -o yaml | kubectl apply -f -"
echo
echo "  2. Restart the pods so they pick up the new values"
echo "  kubectl rollout restart deployment/moonbase-api -n lunar-prod"
echo "  kubectl rollout status deployment/moonbase-api -n lunar-prod"
echo
n "this is how a TUI really prints a list: no blank line between the heading"
n "and its command. ⌘-hover the command rows — the heading stays untinted and"
n "out of the copy. In 2, both commands tint as one: they were written to run"
n "together."
echo
b "9. A HEREDOC — the body and the terminator come with the command"
echo
echo " 5. Update from a heredoc"
echo "  cat <<'EOF' | kubectl apply -f -"
echo "  apiVersion: v1"
echo "  kind: Secret"
echo "  metadata:"
echo "    name: stripe-api"
echo "  EOF"
echo "  secret/stripe-api configured"
echo
n "⌘-hover any row from cat to EOF: the whole thing tints as one command."
n "the configured line below it does not join in, and the heading above stays"
n "out. In the copy, EOF sits at column 0, which is where a shell needs it."
echo
b "10. A COMMAND A TUI RAN FOR YOU — the bang is not part of it"
echo
echo "! ssh ovhprod-001 'kubectl -n snuggery get pvc backup-pvc -o jsonpath=\"{.metadata.finalizers}\"'"
echo "[kubernetes.io/pvc-protection]"
echo
n "⌘-hover the command: it tints even though it wrapped, and the copy starts"
n "at ssh. The bang is how Claude Code showed the command it ran; pasted into"
n "an interactive shell it would be history expansion instead. The line it"
n "printed below stays out."
echo
