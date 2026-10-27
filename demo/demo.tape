# The README demo. Record from the repository root:  vhs demo/demo.tape
# Uses demo/run.sh: a throwaway LazyVim on the synthetic shop repo from demo/setup.sh,
# under a temporary HOME (demo/vhs-env.sh). Needs vhs, gopls and JetBrainsMono Nerd Font
# (brew install --cask font-jetbrains-mono-nerd-font).
Output demo/demo.gif
Set Shell bash
Set FontFamily "JetBrainsMono Nerd Font Mono"
Set FontSize 14
Set Width 1200
Set Height 680
Set Padding 8
Set Framerate 10
Set TypingSpeed 70ms
Set Theme "TokyoNight"

Hide
Type "source demo/vhs-env.sh" Enter
Type "demo/run.sh" Enter
Sleep 14s
Escape
Type "25Gw"
Sleep 4s
Show

# The live bow-tie follows the cursor: callers on the left, callees on the right.
Sleep 2.5s
Type "jfv" Sleep 2.5s
Type "5jfS" Sleep 3s

# gag: two levels deep in a float.
Type "25Gw" Sleep 1s
Type "gag" Sleep 4s
Type "q" Sleep 500ms

# gat: walk one hop at a time, pick the implementation, leave a note.
Type "gat" Sleep 2.5s
Type "5" Sleep 2.5s
Enter Sleep 2s
Type "n" Sleep 700ms
Type "rounding happens before Save?" Sleep 400ms
Enter Sleep 3s
Type "q" Sleep 500ms

# <leader>cG: what did the agent change? The new helper nothing calls is flagged.
Type " cG" Sleep 3.5s
Ctrl+N Sleep 3s
Escape Sleep 300ms
Escape Sleep 500ms

Hide
Type ":qa!" Enter
