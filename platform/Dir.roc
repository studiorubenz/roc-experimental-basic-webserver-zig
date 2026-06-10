## Directory operations. API vendored from roc-lang/basic-cli
## (branch migrate-zig-compiler), unchanged.
import IOErr exposing [IOErr]

Dir := [].{
    ## Creates a new, empty directory at the provided path.
    ##
    ## If the parent directories do not exist, they will not be created.
    ## Use [Dir.create_all!] to create parent directories as needed.
    create! : Str => Try({}, [DirErr(IOErr)])

    ## Creates a new, empty directory at the provided path, including any parent directories.
    ##
    ## If the directory already exists, this will succeed without error.
    create_all! : Str => Try({}, [DirErr(IOErr)])

    ## Deletes an empty directory.
    ##
    ## Fails if the directory is not empty. Use [Dir.delete_all!] to delete
    ## a directory and all its contents.
    delete_empty! : Str => Try({}, [DirErr(IOErr)])

    ## Deletes a directory and all of its contents recursively.
    ##
    ## Use with caution!
    delete_all! : Str => Try({}, [DirErr(IOErr)])

    ## Lists the contents of a directory.
    ##
    ## Returns the paths of all files and directories within the specified directory.
    list! : Str => Try(List(Str), [DirErr(IOErr)])
}
