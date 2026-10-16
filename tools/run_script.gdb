# Usage: gdb -x tools/run_script.gdb --args ./build/llmfun agent
# (then "run" at the prompt; on a crash gdb stays at the prompt for bt).
# The actor Scheduler (druntime thread machinery) uses real-time signals
# SIG34/SIG35 internally; without these gdb stops the program on the first one.
handle SIG34 nostop noprint pass
handle SIG35 nostop noprint pass
# Kept from the original script; nothing in llmfun currently raises them.
handle SIGUSR1 nostop noprint pass
handle SIGUSR2 nostop noprint pass

# Quit on normal completion, but not on signals: on a signal stop the
# $_exitcode comparison errors harmlessly and gdb stays at the prompt.
define hookpost-run
  if $_exitcode != -1
    quit
  end
end
