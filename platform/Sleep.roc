## Blocking sleep. API vendored from roc-lang/basic-cli
## (branch migrate-zig-compiler), unchanged.
##
## Note: in this webserver platform, all calls into Roc are serialized, so a
## sleeping handler delays every other request's handler too — use sparingly.
Sleep := [].{
    ## Sleep for the specified number of milliseconds.
    millis! : U64 => {}
}
