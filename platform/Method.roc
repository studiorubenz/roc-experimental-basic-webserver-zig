# Vendored from roc-lang/http @ cc845a2 (UPL-1.0).
# Local addition: the from_str constructor (upstream has method_str on
# Request but no inverse, which a server platform needs — worth upstreaming).
# https://developer.mozilla.org/en-US/docs/Web/HTTP/Methods
Method := [OPTIONS, GET, POST, PUT, DELETE, HEAD, TRACE, CONNECT, PATCH, Unknown(Str)].{
    ## Parse an HTTP method from its request-line string.
    from_str : Str -> Method
    from_str = |str|
        match str {
            "OPTIONS" => OPTIONS
            "GET" => GET
            "POST" => POST
            "PUT" => PUT
            "DELETE" => DELETE
            "HEAD" => HEAD
            "TRACE" => TRACE
            "CONNECT" => CONNECT
            "PATCH" => PATCH
            other => Unknown(other)
        }
}
