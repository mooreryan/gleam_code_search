-module(codesearch_ffi).
-export([extract/3, stop/1]).

stop(Status) ->
    case init:stop(Status) of
        ok -> {ok, nil};
        % This will happen if the status is a negative number
        Error -> {error, unicode:characters_to_binary(Error)}
    end.

extract(Open, Cwd, Compressed) ->
    Opts = case Compressed of
        true -> [{cwd, Cwd}, compressed];
        false -> [{cwd, Cwd}]
    end,
    case erl_tar:extract(Open, Opts) of
        ok -> {ok, nil};
        {error, Reason} -> {error, {tar_error, term_to_string(Reason)}}
    end.

term_to_string(Term) ->
    CharList = io_lib:format("~p", [Term]),
    unicode:characters_to_binary(CharList).
