## Blocking sleep. API vendored from roc-lang/basic-cli
## (branch migrate-zig-compiler), unchanged.
##
## Note: a sleeping handler occupies one worker thread for the duration;
## if every worker is asleep, further connections queue — use sparingly.
Sleep := [].{
    ## Sleep for the specified number of milliseconds.
    millis! : U64 => {}
}
