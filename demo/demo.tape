# The README demo. Record from the repository root:  vhs demo/demo.tape
# Uses demo/run.sh: a throwaway LazyVim on the synthetic shop repo from demo/setup.sh,
# under a temporary HOME (demo/vhs-env.sh). Needs vhs, gopls and JetBrainsMono Nerd Font
# (brew install --cask font-jetbrains-mono-nerd-font).
Output demo/demo.gif
Set Shell bash
Set FontFamily "JetBrainsMono Nerd Font Mono"
Set FontSize 13
Set Width 1100
Set Height 620
Set Padding 8
Set Framerate 6
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

# Rest on a function: a small card in the corner shows callers and callees.
Sleep 2.5s
Type "jfv" Sleep 2.5s

# gag: the full bow-tie. Moving through it previews each function in the code above.
Type "25Gw" Sleep 1.5s
Type "gag" Sleep 2.5s
Type "l" Sleep 1.5s
Type "jj" Sleep 1.5s
Type "jjj" Sleep 1.5s
Escape Sleep 1.2s

# <C-v> keeps it open beside the code; <CR> goes there.
Type "gag" Sleep 1.5s
Ctrl+V Sleep 2s
Type "ljj" Sleep 1.5s
Enter Sleep 1.8s
Type ":only | edit internal/order/order.go" Enter Sleep 800ms
Type "25Gw" Sleep 1.5s

# gat: walk one hop at a time, pick the implementation, leave a note.
Type "gat" Sleep 2.5s
Type "5" Sleep 2.5s
Enter Sleep 2s
Type "n" Sleep 700ms
Type "rounding happens before Save?" Sleep 400ms
Enter Sleep 2.5s
Type "q" Sleep 500ms

# <leader>cG: what did the agent change? The new helper nothing calls is flagged.
Type " cG" Sleep 3s
Ctrl+N Sleep 2.5s
Escape Sleep 300ms
Escape Sleep 500ms

Hide
Type ":qa!" Enter
