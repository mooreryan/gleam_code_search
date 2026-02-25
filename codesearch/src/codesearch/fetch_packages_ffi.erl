-module(fetch_packages_ffi).
-export([stop/1]).

stop(Status) ->
    case init:stop(Status) of
        ok -> {ok, nil};
        % This will happen if the status is a negative number
        Error -> {error, unicode:characters_to_binary(Error)}
    end.
