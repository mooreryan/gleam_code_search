-module(tar_ffi).
-export([extract/3]).


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
