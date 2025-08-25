%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_rule_sqlparser).

-include("rule_engine.hrl").

-export([parse/1, parse/2]).

-export([
    select_fields/1,
    select_is_foreach/1,
    select_doeach/1,
    select_incase/1,
    select_from/1,
    select_where/1
]).

-import(proplists, [
    get_value/2,
    get_value/3
]).

-record(select, {fields, from, where, is_foreach, doeach, incase}).

-opaque select() :: #select{}.

-type const() :: {const, number() | binary()}.

-type variable() :: binary() | list(binary()).

-type alias() :: binary() | list(binary()).

%% TODO: So far the SQL function module names and function names are as binary(),
%% binary_to_atom is called to convert to module and function name.
%% For better performance, the function references
%% can be converted to a fun Module:Function/N When compiling the SQL.
-type ext_module_name() :: atom() | binary().
-type func_name() :: atom() | binary().
-type func_args() :: [field()].
%% Functions defiend in emqx_rule_funcs
-type builtin_func_ref() :: {var, func_name()}.
%% Functions defined in other modules, reference syntax: Module.Function(Arg1, Arg2, ...)
%% NOTE: it's '.' (Elixir style), but not ':' (Erlang style).
%% Parsed as a two element path-list: [{key, Module}, {key, Func}].
-type external_func_ref() :: {path, [{key, ext_module_name() | func_name()}]}.
-type func_ref() :: builtin_func_ref() | external_func_ref().
-type sql_func() :: {'fun', func_ref(), func_args()}.

-type field() :: const() | variable() | {as, field(), alias()} | sql_func().

-type parse_opts() :: #{
    %% Whether `from' clause should be mandatory.
    %% Default: `true'.
    with_from => boolean()
}.

-export_type([select/0]).

%% Parse one select statement.
-spec parse(string() | binary()) -> {ok, select()} | {error, term()}.
parse(Sql) ->
    parse(Sql, _Opts = #{}).

-spec parse(string() | binary(), parse_opts()) -> {ok, select()} | {error, term()}.
parse(Sql, Opts) ->
    WithFrom = maps:get(with_from, Opts, true),
    case do_parse(Sql) of
        {ok, Parsed} when WithFrom ->
            ensure_non_empty_from(Parsed);
        {ok, Parsed} ->
            ensure_empty_from(Parsed);
        Error = {error, _} ->
            Error
    end.

-spec select_fields(select()) -> list(field()).
select_fields(#select{fields = Fields}) ->
    Fields.

-spec select_is_foreach(select()) -> boolean().
select_is_foreach(#select{is_foreach = IsForeach}) ->
    IsForeach.

-spec select_doeach(select()) -> list(field()).
select_doeach(#select{doeach = DoEach}) ->
    DoEach.

-spec select_incase(select()) -> list(field()).
select_incase(#select{incase = InCase}) ->
    InCase.

-spec select_from(select()) -> list(binary()).
select_from(#select{from = From}) ->
    From.

-spec select_where(select()) -> tuple().
select_where(#select{where = Where}) ->
    Where.

-spec do_parse(string() | binary()) -> {ok, select()} | {error, term()}.
do_parse(Sql) ->
    try
        case rulesql:parsetree(Sql) of
            {ok, {select, Clauses}} ->
                Parsed = #select{
                    is_foreach = false,
                    fields = get_value(fields, Clauses),
                    doeach = [],
                    incase = {},
                    from = get_value(from, Clauses),
                    where = get_value(where, Clauses)
                },
                {ok, Parsed};
            {ok, {foreach, Clauses}} ->
                Parsed = #select{
                    is_foreach = true,
                    fields = get_value(fields, Clauses),
                    doeach = get_value(do, Clauses, []),
                    incase = get_value(incase, Clauses, {}),
                    from = get_value(from, Clauses),
                    where = get_value(where, Clauses)
                },
                {ok, Parsed};
            Error ->
                {error, Error}
        end
    catch
        _Error:Reason:StackTrace ->
            {error, {Reason, StackTrace}}
    end.

ensure_non_empty_from(#select{from = []}) ->
    {error, empty_from_clause};
ensure_non_empty_from(Parsed) ->
    {ok, Parsed}.

ensure_empty_from(#select{from = [_ | _]}) ->
    {error, non_empty_from_clause};
ensure_empty_from(Parsed) ->
    {ok, Parsed}.
