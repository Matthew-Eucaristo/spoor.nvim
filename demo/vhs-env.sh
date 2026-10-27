# Sourced (hidden) by demo/demo.tape: a throwaway HOME and a bare prompt, so no frame shows
# anything about the machine that records it. Language servers stay on PATH.
for bin in gopls vtsls; do
  dir=$(dirname "$(command -v "$bin" 2>/dev/null || echo /nonexistent/x)")
  [ -d "$dir" ] && PATH="$dir:$PATH"
done
export PATH
HOME=$(mktemp -d)
export HOME
export PS1='$ '
unset PROMPT_COMMAND
clear
